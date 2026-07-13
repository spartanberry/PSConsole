<#
  PSConsole - self-hosted PowerShell execution platform (Pode).
  Runs as a Windows service under the zpsconsole identity. PS 5.1 compatible.
  All script execution inherits the service account's (read-only) AD rights.
#>
[CmdletBinding()]
param(
    [int]$Port = 443,
    [string]$CertThumbprint,                 # self-signed cert installed by Install-PSConsole.ps1
    [string]$Address = '*'                   # bind all interfaces; firewall restricts to internal
)
$ErrorActionPreference = 'Stop'
# Strip PS 7/pwsh module paths so PS 5.1 loads its own Microsoft.PowerShell.Utility (not the PS 7 build).
# This matters when launched from a pwsh parent that injects its paths into PSModulePath.
$env:PSModulePath = ($env:PSModulePath -split ';' | Where-Object {
    ($_ -imatch 'WindowsPowerShell') -or ($_ -imatch [regex]::Escape("$env:SystemRoot\system32"))
}) -join ';'
$AppRoot = $PSScriptRoot
$env:PSCONSOLE_DATA = Join-Path $AppRoot '..\data'

Import-Module (Join-Path $AppRoot '..\modules\Pode\Pode.psd1') -Force
Import-Module (Join-Path $AppRoot 'lib\PSConsoleLib.psm1') -Force
Initialize-Store
$ScriptDir = Join-Path $AppRoot 'scripts'
# Cert precedence: config store (runtime-swappable) overrides the -CertThumbprint install arg.
$cfgCert = (Get-Store config).certThumbprint
if ($cfgCert) { $CertThumbprint = $cfgCert }

function Invoke-ManagedScript {
    param([string]$Path, [hashtable]$Parameters, [int]$TimeoutSec = 120)
    $ps = [PowerShell]::Create()
    [void]$ps.AddCommand($Path)
    if ($Parameters) { foreach ($k in $Parameters.Keys) { if ($Parameters[$k] -ne $null -and "$($Parameters[$k])" -ne '') { [void]$ps.AddParameter($k, $Parameters[$k]) } } }
    $async = $ps.BeginInvoke()
    if (-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSec))) {
        $ps.Stop(); $ps.Dispose()
        return @{ ok=$false; error="Timed out after ${TimeoutSec}s"; data=@() }
    }
    try {
        $out = $ps.EndInvoke($async)
        $errs = @($ps.Streams.Error | ForEach-Object { $_.ToString() })
        @{ ok=($errs.Count -eq 0); error=($errs -join "`n"); data=@($out) }
    } catch { @{ ok=$false; error=$_.Exception.Message; data=@() } }
    finally { $ps.Dispose() }
}

# -Threads > 1 is important: Pode defaults to a SINGLE request runspace, so one slow or
# hung request (e.g. a long AD script run) would otherwise freeze the ENTIRE site - login
# included - until it completes or the service is restarted.
Start-PodeServer -RootPath (Join-Path $AppRoot 'web') -Threads 5 {
    Export-PodeModule -Name 'PSConsoleLib'
    New-PodeLoggingMethod -Terminal | Enable-PodeErrorLogging
    if ($CertThumbprint) {
        Add-PodeEndpoint -Address $Address -Port $Port -Protocol Https -CertificateThumbprint $CertThumbprint -CertificateStoreName My -CertificateStoreLocation LocalMachine
    } else {
        Add-PodeEndpoint -Address $Address -Port $Port -Protocol Http   # install always sets a cert; this is a fallback
    }
    # HttpOnly keeps the session cookie out of JavaScript's reach (defence-in-depth vs XSS); Secure keeps
    # it HTTPS-only (the endpoint is HTTPS). Pode signs the cookie with a per-start random secret already.
    Enable-PodeSessionMiddleware -Duration 3600 -Extend -HttpOnly -Secure
    Set-PodeViewEngine -Type Pode

    # Baseline security response headers (applied to every response). No CSP: the UI relies on inline
    # scripts/handlers, so a meaningful CSP would need a refactor - tracked separately.
    Set-PodeSecurityFrameOptions -Type Deny                                   # anti-clickjacking
    Set-PodeSecurityContentTypeOptions                                        # X-Content-Type-Options: nosniff
    Set-PodeSecurityStrictTransportSecurity -Duration 31536000 -IncludeSubDomains

    function Get-User { $WebEvent.Session.Data.user }
    # Authorization is decided solely by the ACTION via Test-Authorized (admin allows all; each role's
    # allowed actions are the single source of truth). No role argument - that was dead/misleading.
    function Require($action, $WebEvent) {
        $u = $WebEvent.Session.Data.user
        if (-not $u) { Move-PodeResponseUrl -Url '/login'; return $false }
        if (-not (Test-Authorized $u.role $action)) { Set-PodeResponseStatus -Code 403; Write-PodeTextResponse -Value 'Forbidden'; return $false }
        $true
    }

    Add-PodeRoute -Method Get -Path '/login' -ScriptBlock {
        Write-PodeViewResponse -Path 'login' -Data @{ error = (ConvertTo-PSCEncoded ([string]$WebEvent.Query['e'])); hasLogo = [bool]((Get-Store config).logoFile); head = (Get-LoginHead) }
    }

    # Unauthenticated: the logo is shown on the login page, so it can't require a session.
    Add-PodeRoute -Method Get -Path '/logo' -ScriptBlock {
        $lf = (Get-Store config).logoFile
        if (-not $lf) { Set-PodeResponseStatus -Code 404; return }
        $path = Join-Path (Get-DataDir) $lf
        if (-not (Test-Path $path)) { Set-PodeResponseStatus -Code 404; return }
        $ct = switch ([System.IO.Path]::GetExtension($lf).ToLower()) {
            '.png'  { 'image/png' }
            '.jpg'  { 'image/jpeg' }
            '.jpeg' { 'image/jpeg' }
            '.gif'  { 'image/gif' }
            '.webp' { 'image/webp' }
            '.svg'  { 'image/svg+xml' }
            default { 'application/octet-stream' }
        }
        Write-PodeTextResponse -Bytes ([System.IO.File]::ReadAllBytes($path)) -ContentType $ct
    }
    Add-PodeRoute -Method Post -Path '/login' -ScriptBlock {
        $b = $WebEvent.Data
        $res = Invoke-Authenticate $b.username $b.password
        if ($res.ok) {
            $WebEvent.Session.Data.user = @{ username=$res.username; role=$res.role; type=$res.type }
            Write-Audit $res.username $res.role 'login' '' @{} 'success' 0 $res.type
            Move-PodeResponseUrl -Url '/dashboard'   # Dashboard is the default landing for both roles
        } else {
            Write-Audit $b.username 'n/a' 'login' '' @{} 'fail' 0 $res.reason
            Move-PodeResponseUrl -Url '/login?e=Invalid+credentials+or+no+assigned+role'
        }
    }
    Add-PodeRoute -Method Post -Path '/logout' -ScriptBlock { Remove-PodeSession; Move-PodeResponseUrl -Url '/login' }

    Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
        if (-not (Require 'run' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        # Scripts grouped by category (Active Directory / Entra ID / Intune), filtered to this role and
        # to the Intune add-on gate. Built as <optgroup> HTML in the route (same pattern as other pages).
        $scriptsHtml = Get-ScriptOptionsHtml -Dir $using:ScriptDir -Role $u.role
        $examplesJson = Get-ScriptExamplesJson -Dir $using:ScriptDir -Role $u.role
        $chrome = Get-AppChrome -Active 'run' -User $u -Title 'Run scripts' -Subtitle 'Execute a curated PowerShell script' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'dashboard' -Data @{ user=$u; scriptsHtml=$scriptsHtml; examplesJson=$examplesJson; head=$chrome.head; open=$chrome.open; close=$chrome.close }
    }

    # Overview dashboard - available to admin AND helpdesk. Admins see recent audit activity; helpdesk
    # see "passwords expiring (7d)" + "recent failed Entra sign-ins" instead (no audit access).
    Add-PodeRoute -Method Get -Path '/dashboard' -ScriptBlock {
        if (-not (Require 'run' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $scriptDir = $using:ScriptDir
        $q = @(Get-Store onboarding)
        $pending = @($q | Where-Object { $_.cloudStatus -ne 'complete' }).Count
        $scriptCount = @(Get-ChildItem $scriptDir -Filter *.ps1).Count

        if ($u.role -eq 'admin') {
            $recentRows = (@(Get-AuditTail 8) | ForEach-Object {
                $ts = try { ([datetime]$_.ts).ToString('MM/dd/yyyy h:mm tt') } catch { [string]$_.ts }
                "<tr><td>$(ConvertTo-PSCEncoded $ts)</td><td>$(ConvertTo-PSCEncoded ([string]$_.user))</td><td>$(ConvertTo-PSCEncoded ([string]$_.action))</td><td>$(ConvertTo-PSCEncoded ([string]$_.script))</td><td>$(ConvertTo-PSCEncoded ([string]$_.status))</td></tr>"
            }) -join ''
            $lower = @"
<div class="card">
  <h3>Recent activity</h3>
  <div style="overflow-x:auto"><table>
    <tr><th>When</th><th>User</th><th>Action</th><th>Target</th><th>Status</th></tr>
    $recentRows
  </table></div>
  <div class="note" style="margin-top:10px"><a href="/?view=audit">Open full audit &rarr;</a></div>
</div>
"@
        }
        else {
            # Helpdesk widgets - run the read-only scripts directly (short timeout; failures degrade
            # gracefully). No Write-Audit here: viewing the dashboard is not a script "run".
            $pwHtml = ''
            try {
                $r = Invoke-ManagedScript -Path (Join-Path $scriptDir '02-Get-PasswordsExpiring.ps1') -Parameters @{ Days = 7 } -TimeoutSec 20
                if ($r.ok) {
                    # Dashboard shows only NOT-yet-expired accounts (positive days left); already-expired
                    # (negative) are excluded here but still appear when the script is run manually.
                    $rows = @(@($r.data) | Where-Object { [double]$_.DaysLeft -gt 0 } | Sort-Object DaysLeft)
                    if ($rows.Count) {
                        $pwHtml = ($rows | ForEach-Object {
                            $exp = try { ([datetime]$_.Expires).ToString('MM/dd/yyyy') } catch { [string]$_.Expires }
                            "<tr><td>$(ConvertTo-PSCEncoded ([string]$_.DisplayName))<br><span class='note'>$(ConvertTo-PSCEncoded ([string]$_.SamAccountName))</span></td><td>$(ConvertTo-PSCEncoded ([string]$_.Email))</td><td>$exp</td><td>$(ConvertTo-PSCEncoded ([string]$_.DaysLeft))</td></tr>"
                        }) -join ''
                    } else { $pwHtml = "<tr><td colspan='4' class='note'>No passwords expiring in the next 7 days.</td></tr>" }
                } else { $pwHtml = "<tr><td colspan='4' class='note'>Unavailable: $(ConvertTo-PSCEncoded ([string]$r.error))</td></tr>" }
            } catch { $pwHtml = "<tr><td colspan='4' class='note'>Unavailable.</td></tr>" }

            # Last 10 failed sign-ins: query Graph directly for just the newest page of FAILURES
            # (server-side filter + top 10, no auto-paging) - ~2s vs 30s+ for scanning all sign-ins.
            $failHtml = ''
            try {
                $tok = Get-GraphToken
                $gh  = @{ Authorization = "Bearer $tok"; ConsistencyLevel = 'eventual' }
                $resp = Invoke-RestMethod -Headers $gh -TimeoutSec 15 -Uri "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$filter=status/errorCode ne 0&`$top=10"
                $rows = @($resp.value)
                if ($rows.Count) {
                    $failHtml = ($rows | ForEach-Object {
                        $t   = try { ([datetime]$_.createdDateTime).ToString('MM/dd/yyyy h:mm tt') } catch { [string]$_.createdDateTime }
                        $loc = (@($_.location.city, $_.location.countryOrRegion) | Where-Object { $_ }) -join ', '
                        "<tr><td>$t</td><td>$(ConvertTo-PSCEncoded ([string]$_.userPrincipalName))</td><td>$(ConvertTo-PSCEncoded ([string]$_.status.failureReason))</td><td>$(ConvertTo-PSCEncoded ([string]$_.ipAddress))</td><td>$(ConvertTo-PSCEncoded ([string]$loc))</td></tr>"
                    }) -join ''
                } else { $failHtml = "<tr><td colspan='5' class='note'>No recent failed sign-ins.</td></tr>" }
            } catch { $failHtml = "<tr><td colspan='5' class='note'>Unavailable: $(ConvertTo-PSCEncoded ([string]$_.Exception.Message))</td></tr>" }

            $lower = @"
<div class="card">
  <h3>Passwords expiring within 7 days</h3>
  <div style="overflow-x:auto"><table>
    <tr><th>User</th><th>Email</th><th>Expires</th><th>Days left</th></tr>
    $pwHtml
  </table></div>
</div>
<div class="card">
  <h3>Recent failed Entra sign-ins (last 10)</h3>
  <div style="overflow-x:auto"><table>
    <tr><th>When</th><th>User</th><th>Reason</th><th>IP</th><th>Location</th></tr>
    $failHtml
  </table></div>
</div>
"@
        }

        $chrome = Get-AppChrome -Active 'dashboard' -User $u -Title 'Dashboard' -Subtitle 'Overview' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'admin-dashboard' -Data @{ user=$u; pending=$pending; scriptCount=$scriptCount; lower=$lower; head=$chrome.head; open=$chrome.open; close=$chrome.close }
    }

    # ---- User provisioning (admin-only for now; Phase 1 = on-prem AD create) ----
    Add-PodeRoute -Method Get -Path '/users/new' -ScriptBlock {
        if (-not (Require 'create-user' $WebEvent)) { return }
        $s = Get-ProvisionSettings
        $deptObjs = @($s.departments | ForEach-Object {
            $jts = @()
            if ($_.jobTitles) { $jts = @(@($_.jobTitles) | Where-Object { $_ } | ForEach-Object { [string]$_.name } | Where-Object { $_ }) }
            @{ name = [string]$_.name; jobTitles = $jts }
        })
        $sups = @(Get-Supervisors)
        $supOptions = ($sups | ForEach-Object {
            $lbl = (ConvertTo-PSCEncoded $_.name) + $(if ($_.title) { ' - ' + (ConvertTo-PSCEncoded $_.title) })
            '<option value="' + (ConvertTo-PSCEncoded $_.upn) + '">' + $lbl + '</option>'
        }) -join ''
        $chrome = Get-AppChrome -Active 'create' -User $WebEvent.Session.Data.user -Title 'Create User' -Subtitle 'On-prem AD (Phase 1)' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'user-new' -Data @{
            user              = $WebEvent.Session.Data.user
            departments       = @($s.departments | ForEach-Object { $_.name })
            deptJobs          = (ConvertTo-PSCEncoded (ConvertTo-Json @($deptObjs) -Depth 6 -Compress))
            hasSupervisors    = [bool]$sups.Count
            supervisorOptions = $supOptions
            enabled           = [bool]$s.enabled
            intuneOn          = [bool](Test-IntuneConfigured)
            head = $chrome.head; open = $chrome.open; close = $chrome.close
        }
    }
    Add-PodeRoute -Method Post -Path '/users/new/preview' -ScriptBlock {
        if (-not (Require 'create-user' $WebEvent)) { return }
        $b = $WebEvent.Data
        $jt = if ($b.jobTitles) { @([string]$b.jobTitles -split '\|' | Where-Object { $_ }) } else { @() }
        $sup = ("$($b.isSupervisor)" -match '^(true|on|1)$')
        $plan = Get-ProvisionPlan -FirstName $b.firstName -LastName $b.lastName -Username $b.username -Department $b.department -Manager $b.manager -JobTitles $jt -Mobile $b.mobile -IsSupervisor:$sup -IntuneDevice $b.intuneDevice
        $errs = @(Test-ProvisionPlan $plan)
        Write-PodeJsonResponse -Value @{ ok=($errs.Count -eq 0); errors=$errs; plan=$plan }
    }
    Add-PodeRoute -Method Post -Path '/users/new/create' -ScriptBlock {
        if (-not (Require 'create-user' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $b = $WebEvent.Data
        $jt = if ($b.jobTitles) { @([string]$b.jobTitles -split '\|' | Where-Object { $_ }) } else { @() }
        $sup = ("$($b.isSupervisor)" -match '^(true|on|1)$')
        $plan = Get-ProvisionPlan -FirstName $b.firstName -LastName $b.lastName -Username $b.username -Department $b.department -Manager $b.manager -JobTitles $jt -Mobile $b.mobile -IsSupervisor:$sup -IntuneDevice $b.intuneDevice
        $errs = @(Test-ProvisionPlan $plan)
        if ($errs.Count) { Write-PodeJsonResponse -Value @{ ok=$false; errors=$errs }; return }
        $s = Get-ProvisionSettings
        if (-not $s.enabled) {
            # Preview mode - never writes. Audit WITHOUT any secrets.
            Write-Audit $u.username $u.role 'create-user-preview' $plan.userPrincipalName @{ ou=$plan.ou; dept=$plan.department } 'preview' 0 'provisioning disabled'
            Write-PodeJsonResponse -Value @{ ok=$true; preview=$true; plan=$plan; message='Preview only - user provisioning is turned off. Turn it on under Config > Department mapping once AD create-delegation is set up.' }
            return
        }
        if (-not $b.opUser -or -not $b.opPassword) { Write-PodeJsonResponse -Value @{ ok=$false; errors=@('Your AD username and password are required to create the account.') }; return }
        if (-not $b.newPassword) { Write-PodeJsonResponse -Value @{ ok=$false; errors=@('An initial password for the new user is required.') }; return }
        # Default ON when the field is absent (older clients / safety); uncheck for service/shared accounts.
        $mustChange = if ($null -ne $b.mustChangePassword) { ("$($b.mustChangePassword)" -match '^(true|on|1)$') } else { $true }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $res = New-OnPremUser -Plan $plan -Password $b.newPassword -OperatorUser $b.opUser -OperatorPassword $b.opPassword -MustChangePassword:$mustChange
        $sw.Stop()
        # Audit params deliberately EXCLUDE opPassword/newPassword.
        $status = if ($res.ok) { 'success' } else { 'error' }
        $detail = if ($res.ok) { $res.dn } else { $res.error }
        Write-Audit $u.username $u.role 'create-user' $plan.userPrincipalName @{ ou=$plan.ou; dept=$plan.department; by=$b.opUser; mustChangePwd=$mustChange } $status $sw.ElapsedMilliseconds $detail
        if ($res.ok) {
            Add-OnboardingPending -Plan $plan -Operator $u.username -OperatorRole $u.role -Dn $res.dn
            try { Send-UserCreatedNotification -Plan $plan -Operator $u.username -Dn $res.dn | Out-Null } catch {}
        }
        Write-PodeJsonResponse -Value @{ ok=$res.ok; error=$res.error; dn=$res.dn; plan=$plan; cloudPending=[bool]$res.ok }
    }

    # ---- Decommission user (helpdesk + admin): disable + move to Disabled Accounts OU ----
    Add-PodeRoute -Method Get -Path '/users/decommission' -ScriptBlock {
        if (-not (Require 'decommission-user' $WebEvent)) { return }
        $s = Get-ProvisionSettings
        $chrome = Get-AppChrome -Active 'decommission' -User $WebEvent.Session.Data.user -Title 'Decommission User' -Subtitle 'Disable + move to Disabled Accounts OU' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'user-decommission' -Data @{
            user       = $WebEvent.Session.Data.user
            enabled    = [bool]$s.enabled
            disabledOu = (ConvertTo-PSCEncoded ([string]$s.disabledOu))
            head = $chrome.head; open = $chrome.open; close = $chrome.close
        }
    }
    Add-PodeRoute -Method Post -Path '/users/decommission/preview' -ScriptBlock {
        if (-not (Require 'decommission-user' $WebEvent)) { return }
        $plan = Find-AdUserForDecomm -Identity ([string]$WebEvent.Data.username)
        $errs = @(Test-DecommPlan $plan)
        Write-PodeJsonResponse -Value @{
            ok     = ($plan.found -and $errs.Count -eq 0)
            errors = $errs
            plan   = @{
                found=$plan.found; sam=$plan.sam; upn=$plan.upn; displayName=$plan.displayName;
                ou=$plan.ou; enabled=$plan.enabled; inDisabledOu=$plan.inDisabledOu;
                onPremGroups=@($plan.onPremGroups | ForEach-Object { (($_ -split ',')[0] -replace '^CN=','') })
            }
        }
    }
    Add-PodeRoute -Method Post -Path '/users/decommission/run' -ScriptBlock {
        if (-not (Require 'decommission-user' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $b = $WebEvent.Data
        $plan = Find-AdUserForDecomm -Identity ([string]$b.username)
        $errs = @(Test-DecommPlan $plan)
        if ($errs.Count) { Write-PodeJsonResponse -Value @{ ok=$false; errors=$errs }; return }
        if ("$($b.confirm)" -notmatch '^(true|on|1|yes)$') { Write-PodeJsonResponse -Value @{ ok=$false; errors=@('You must tick the confirmation box to proceed.') }; return }
        $s = Get-ProvisionSettings
        if (-not $s.enabled) {
            Write-Audit $u.username $u.role 'decommission-preview' $plan.sam @{ ou=$plan.ou } 'preview' 0 'provisioning disabled'
            Write-PodeJsonResponse -Value @{ ok=$true; preview=$true; message='Preview only - provisioning is turned off (Config > Department mapping). Nothing was changed.' }
            return
        }
        if (-not $b.opUser -or -not $b.opPassword) { Write-PodeJsonResponse -Value @{ ok=$false; errors=@('Your AD username and password are required to decommission the account.') }; return }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $res = Invoke-Decommission -Plan $plan -OperatorUser $b.opUser -OperatorPassword $b.opPassword
        $sw.Stop()
        # Audit params deliberately EXCLUDE opPassword.
        $status = if ($res.ok) { 'success' } else { 'error' }
        $detail = if ($res.ok) { "$($res.dn); removed: $((@($res.groupsRemoved) -join ', '))" } else { $res.error }
        Write-Audit $u.username $u.role 'decommission-user' $plan.sam @{ by=$b.opUser; movedTo=$s.disabledOu; groupsRemoved=@($res.groupsRemoved); groupsFailed=@($res.groupsFailed) } $status $sw.ElapsedMilliseconds $detail
        if ($res.ok) { try { Send-UserDecommissionedNotification -Plan $plan -Operator $u.username -Result $res | Out-Null } catch {} }
        Write-PodeJsonResponse -Value @{ ok=$res.ok; error=$res.error; dn=$res.dn; groupsRemoved=@($res.groupsRemoved); groupsFailed=@($res.groupsFailed) }
    }

    Add-PodeRoute -Method Post -Path '/run' -ScriptBlock {
        if (-not (Require 'run' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $name = Split-Path -Leaf $WebEvent.Data.script          # leaf only - blocks path traversal
        $path = Join-Path $using:ScriptDir $name
        if (-not (Test-Path $path)) { Set-PodeResponseStatus -Code 404; return }
        # Enforce the script's own gates server-side (not just hidden in the UI): admin-only scripts stay
        # admin-only, and Intune scripts refuse to run unless the add-on is enabled.
        $meta = Get-ScriptMeta $path
        if ($u.role -ne 'admin' -and $meta.Role -ne 'HelpDesk') { Set-PodeResponseStatus -Code 403; return }
        if ($meta.Category -eq 'Intune' -and -not (Test-IntuneConfigured)) { Set-PodeResponseStatus -Code 403; return }
        $params = @{}
        foreach ($k in $WebEvent.Data.Keys) { if ($k -like 'p_*') { $params[$k.Substring(2)] = $WebEvent.Data[$k] } }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-ManagedScript -Path $path -Parameters $params
        $sw.Stop()
        Write-Audit $u.username $u.role 'run' $name $params ($(if($r.ok){'success'}else{'error'})) $sw.ElapsedMilliseconds $r.error
        Write-PodeJsonResponse -Value @{ ok=$r.ok; error=$r.error; rows=$r.data }
    }

    # Email the results of a run (the rows already shown to the user) to a typed address.
    Add-PodeRoute -Method Post -Path '/email-results' -ScriptBlock {
        if (-not (Require 'run' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $b = $WebEvent.Data
        $to = ([string]$b.to).Trim()
        if ($to -notmatch '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$') { Write-PodeJsonResponse -Value @{ ok=$false; error='Enter a single valid email address.' }; return }
        if (-not (Test-SmtpConfigured)) { Write-PodeJsonResponse -Value @{ ok=$false; error='Email is not configured on the server.' }; return }
        $name = Split-Path -Leaf ([string]$b.script)
        $rows = @()
        # Capture ConvertFrom-Json into a variable BEFORE @(): WinPS 5.1 emits a parsed JSON array
        # non-enumerated, so @(... | ConvertFrom-Json) would wrap all rows as a single array element.
        try { if ($b.rows) { $parsed = [string]$b.rows | ConvertFrom-Json; $rows = @($parsed) } } catch {}
        $html = ConvertTo-ResultHtml -Title "$name results" -Rows $rows
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $res = Send-PSCMail -To $to -Subject "PSConsole: $name results" -BodyHtml $html
        $sw.Stop()
        Write-Audit $u.username $u.role 'email-results' $name @{ to=$to; rows=@($rows).Count } ($(if($res.ok){'success'}else{'error'})) $sw.ElapsedMilliseconds ($res.error)
        Write-PodeJsonResponse -Value @{ ok=$res.ok; error=$res.error }
    }

    # ---- Admin only ----
    Add-PodeRoute -Method Post -Path '/upload' -ScriptBlock {
        if (-not (Require 'upload' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        # Pode stores the uploaded file's NAME in $WebEvent.Data[<field>] and the file itself
        # in $WebEvent.Files keyed by that name. Save-PodeRequestFile -Key takes the FIELD name.
        $fname = Split-Path -Leaf ([string]$WebEvent.Data['script'])   # leaf-only guards path traversal
        if ([string]::IsNullOrWhiteSpace($fname) -or $fname -notmatch '\.ps1$') { Set-PodeResponseStatus -Code 400; Write-PodeTextResponse -Value 'Only .ps1 allowed'; return }
        Save-PodeRequestFile -Key 'script' -Path (Join-Path $using:ScriptDir $fname)
        Write-Audit $u.username $u.role 'upload' $fname @{} 'success' 0 ''
        Move-PodeResponseUrl -Url '/'
    }
    Add-PodeRoute -Method Get -Path '/admin/config' -ScriptBlock {
        if (-not (Require 'configure' $WebEvent)) { return }
        $cfg = Get-Store config
        $chrome = Get-AppChrome -Active 'config' -User $WebEvent.Session.Data.user -Title 'Config' -Subtitle 'Directory auth, branding, provisioning' -HasLogo ([bool]$cfg.logoFile)
        Write-PodeViewResponse -Path 'config' -Data @{ cfg=$cfg; user=$WebEvent.Session.Data.user; head=$chrome.head; open=$chrome.open; close=$chrome.close }
    }
    Add-PodeRoute -Method Post -Path '/admin/config' -ScriptBlock {
        if (-not (Require 'configure' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $b = $WebEvent.Data
        $cfg = Get-Store config
        $cfg.ldapEnabled = [bool]$b.ldapEnabled; $cfg.ldapServer = $b.ldapServer; $cfg.ldapPort = [int]$b.ldapPort
        $cfg.ldapUseSsl = [bool]$b.ldapUseSsl
        $cfg.roleMap.admin    = @($b.adminGroups    -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $cfg.roleMap.helpdesk = @($b.helpdeskGroups -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        Set-Store config $cfg
        Write-Audit $u.username $u.role 'configure' 'ldap' @{ enabled=$cfg.ldapEnabled } 'success' 0 ''
        Move-PodeResponseUrl -Url '/admin/config'
    }
    Add-PodeRoute -Method Get -Path '/admin/audit' -ScriptBlock {
        if (-not (Require 'view-history' $WebEvent)) { return }
        $from = [string]$WebEvent.Query['from']; $to = [string]$WebEvent.Query['to']
        $rows = if ($from -or $to) { Get-AuditRange -From $from -To $to -Max 2000 } else { Get-AuditTail 500 }
        Write-PodeJsonResponse -Value @{ rows = $rows }
    }

    Add-PodeRoute -Method Post -Path '/admin/logo' -ScriptBlock {
        if (-not (Require 'configure' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $orig = Split-Path -Leaf ([string]$WebEvent.Data['logo'])
        $ext = [System.IO.Path]::GetExtension($orig).ToLower()
        if ($ext -notin @('.png','.jpg','.jpeg','.gif','.webp','.svg')) { Set-PodeResponseStatus -Code 400; Write-PodeTextResponse -Value 'Only .png .jpg .gif .webp .svg allowed'; return }
        $dataDir = Get-DataDir
        $cfg = Get-Store config
        if ($cfg.logoFile) { $old = Join-Path $dataDir $cfg.logoFile; if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue } }
        $fname = "logo$ext"
        Save-PodeRequestFile -Key 'logo' -Path (Join-Path $dataDir $fname)
        $cfg | Add-Member -NotePropertyName logoFile -NotePropertyValue $fname -Force
        Set-Store config $cfg
        Write-Audit $u.username $u.role 'configure' 'logo' @{} 'success' 0 $fname
        Move-PodeResponseUrl -Url '/admin/config'
    }
    Add-PodeRoute -Method Post -Path '/admin/logo/remove' -ScriptBlock {
        if (-not (Require 'configure' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $cfg = Get-Store config
        if ($cfg.logoFile) { $old = Join-Path (Get-DataDir) $cfg.logoFile; if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue } }
        $cfg | Add-Member -NotePropertyName logoFile -NotePropertyValue $null -Force
        Set-Store config $cfg
        Write-Audit $u.username $u.role 'configure' 'logo-remove' @{} 'success' 0 ''
        Move-PodeResponseUrl -Url '/admin/config'
    }

    # ---- Department mapping + provisioning settings (admin) ----
    Add-PodeRoute -Method Get -Path '/admin/deptmap' -ScriptBlock {
        if (-not (Require 'configure' $WebEvent)) { return }
        $s = Get-ProvisionSettings
        $chrome = Get-AppChrome -Active 'config' -User $WebEvent.Session.Data.user -Title 'Department mapping' -Subtitle 'Provisioning settings' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'deptmap' -Data @{
            user = $WebEvent.Session.Data.user
            json = (ConvertTo-PSCEncoded ($s | ConvertTo-Json -Depth 8))
            msg  = (ConvertTo-PSCEncoded ([string]$WebEvent.Query['e']))
            head = $chrome.head; open = $chrome.open; close = $chrome.close
        }
    }
    Add-PodeRoute -Method Post -Path '/admin/deptmap' -ScriptBlock {
        if (-not (Require 'configure' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        try { $parsed = $WebEvent.Data.json | ConvertFrom-Json }
        catch { Move-PodeResponseUrl -Url '/admin/deptmap?e=Invalid+JSON+-+not+saved'; return }
        $depts = if ($null -ne $parsed.departments) { @($parsed.departments) } else { @() }
        Set-ProvisionSettings ([pscustomobject]@{
            enabled                 = [bool]$parsed.enabled
            upnSuffix               = [string]$parsed.upnSuffix
            supervisorGroup         = if ($parsed.supervisorGroup) { [string]$parsed.supervisorGroup } else { 'Supervisors' }
            supervisorGroups        = if ($null -ne $parsed.supervisorGroups) { @($parsed.supervisorGroups) } else { @('Supervisors','Supervisors_TRD') }
            licenseSkuId            = [string]$parsed.licenseSkuId
            usageLocation           = if ($parsed.usageLocation) { [string]$parsed.usageLocation } else { 'US' }
            onboardingAutoRun       = [bool]$parsed.onboardingAutoRun
            disabledOu              = if ($parsed.disabledOu) { [string]$parsed.disabledOu } else { 'OU=Disabled Accounts,DC=example,DC=org' }
            baseGroups              = if ($null -ne $parsed.baseGroups) { @($parsed.baseGroups) } else { @() }
            onCallGroup             = [string]$parsed.onCallGroup
            onCallExceptDepartments = if ($null -ne $parsed.onCallExceptDepartments) { @($parsed.onCallExceptDepartments) } else { @() }
            departments             = $depts
        })
        Write-Audit $u.username $u.role 'configure' 'deptmap' @{ enabled=[bool]$parsed.enabled; count=$depts.Count } 'success' 0 ''
        Move-PodeResponseUrl -Url '/admin/deptmap?e=Saved'
    }

    # ---- Cloud onboarding (Phase 2): apply cloud groups + license once users sync to Entra ----
    Add-PodeRoute -Method Get -Path '/users/onboarding' -ScriptBlock {
        if (-not (Require 'create-user' $WebEvent)) { return }
        try { Clear-CompletedOnboarding -Days 7 | Out-Null } catch {}   # keep the screen tidy on load
        $chrome = Get-AppChrome -Active 'onboarding' -User $WebEvent.Session.Data.user -Title 'Cloud onboarding' -Subtitle 'Phase 2 - applies after Entra sync' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'onboarding' -Data @{
            user       = $WebEvent.Session.Data.user
            queue      = @(Get-Store onboarding)
            writeReady = [bool](Test-GraphWriteConfigured)
            exoReady   = [bool](Test-ExoConfigured)
            autoRun    = [bool](Get-ProvisionSettings).onboardingAutoRun
            head = $chrome.head; open = $chrome.open; close = $chrome.close
        }
    }
    Add-PodeRoute -Method Post -Path '/users/onboarding/run' -ScriptBlock {
        if (-not (Require 'create-user' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $sum = Invoke-Onboarding
        $sw.Stop()
        Write-Audit $u.username $u.role 'onboarding-run' 'cloud' @{ processed=$sum.processed; completed=$sum.completed; partial=$sum.partial; waiting=$sum.waiting } 'success' $sw.ElapsedMilliseconds ''
        Write-PodeJsonResponse -Value $sum
    }

    # Force-complete a stuck onboarding record: used when the outstanding work (e.g. a mail-enabled DL,
    # or a license fixed in the portal) was done MANUALLY outside PSConsole. Stops retries, suppresses
    # further email, and lets the record age out via the normal 7-day cleanup. Helpdesk + admin.
    Add-PodeRoute -Method Post -Path '/users/onboarding/resolve' -ScriptBlock {
        if (-not (Require 'create-user' $WebEvent)) { return }
        $u  = $WebEvent.Session.Data.user
        $id = [string]$WebEvent.Data.id
        $q  = @(Get-Store onboarding)
        $rec = $q | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1
        if (-not $rec) { Write-PodeJsonResponse -Value @{ ok=$false; error='record not found' }; return }
        if ([string]$rec.cloudStatus -eq 'complete') { Write-PodeJsonResponse -Value @{ ok=$true; note='already complete' }; return }
        $prev = [string]$rec.cloudStatus
        $rec | Add-Member -NotePropertyName cloudStatus -NotePropertyValue 'complete' -Force
        $rec | Add-Member -NotePropertyName note        -NotePropertyValue "resolved manually by $($u.username)" -Force
        $rec | Add-Member -NotePropertyName completedAt -NotePropertyValue (Get-Date).ToString('o') -Force
        $rec | Add-Member -NotePropertyName resolvedBy  -NotePropertyValue $u.username -Force
        $rec | Add-Member -NotePropertyName resolvedAt  -NotePropertyValue (Get-Date).ToString('o') -Force
        $rec | Add-Member -NotePropertyName notified    -NotePropertyValue $true -Force   # no further onboarding email
        Set-Store onboarding $q
        Write-Audit $u.username $u.role 'onboarding-resolve' ([string]$rec.upn) @{ from=$prev } 'success' 0 'resolved manually'
        Write-PodeJsonResponse -Value @{ ok=$true }
    }

    # ---- Computer inventory (SharePoint, read-only for now; admin-only) ----
    Add-PodeRoute -Method Get -Path '/inventory' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $q = [string]$WebEvent.Query['q']
        $configured = [bool](Test-InventoryConfigured)
        $items = @(); $err = ''
        if ($configured) {
            try { $items = @(Get-InventoryItems -Search $q) } catch { $err = "Inventory read failed: $($_.Exception.Message)" }
        }
        $chrome = Get-AppChrome -Active 'inventory' -User $u -Title 'Computer inventory' -Subtitle 'SharePoint - read-only' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'inventory' -Data @{
            user = $u; items = $items; q = $q; configured = $configured; err = $err
            head = $chrome.head; open = $chrome.open; close = $chrome.close
        }
    }

    # user typeahead for the swap form - Entra display-name prefix search via the READ app, members only.
    # One non-paged call (Invoke-Graph auto-pages, so we hit the token + REST directly for a capped $top).
    Add-PodeRoute -Method Get -Path '/inventory/users' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $q = ([string]$WebEvent.Query['q']).Trim()
        $out = @()
        if ($q.Length -ge 2) {
            try {
                $flt = [uri]::EscapeDataString("startswith(displayName,'$($q -replace "'", "''")')")
                $tok = Get-GraphToken
                $uri = "https://graph.microsoft.com/v1.0/users?`$filter=$flt&`$select=id,displayName,userPrincipalName&`$top=15"
                $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec 15
                $out = @($resp.value | Where-Object { [string]$_.userPrincipalName -notmatch '#EXT#' } |
                    ForEach-Object { @{ id = [string]$_.id; name = [string]$_.displayName; upn = [string]$_.userPrincipalName } } |
                    Select-Object -First 10)
            } catch {}
        }
        Write-PodeJsonResponse -Value @{ items = $out }
    }

    # device typeahead - inventory Title (computer-name) prefix search
    Add-PodeRoute -Method Get -Path '/inventory/devices' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $q = ([string]$WebEvent.Query['q']).Trim()
        $out = @()
        if ($q.Length -ge 1) {
            try { $out = @(Find-InventoryTitles -Query $q -Max 12 | ForEach-Object { @{ title = $_.title; owner = $_.owner; status = $_.deploymentStatus } }) } catch {}
        }
        Write-PodeJsonResponse -Value @{ items = $out }
    }

    Add-PodeRoute -Method Get -Path '/inventory/swap' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $chrome = Get-AppChrome -Active 'inventory' -User $u -Title 'Computer swap' -Subtitle 'Reassign a device + set Intune primary user' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'inventory-swap' -Data @{
            user = $u; configured = [bool](Test-InventoryConfigured); intuneOn = [bool](Test-IntuneConfigured)
            head = $chrome.head; open = $chrome.open; close = $chrome.close
        }
    }

    Add-PodeRoute -Method Post -Path '/inventory/swap/preview' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $b = $WebEvent.Data
        Write-PodeJsonResponse -Value (Get-SwapPreview -UserDisplayName ([string]$b.userName) -OldTitle ([string]$b.oldDevice) -NewTitle ([string]$b.newDevice))
    }

    Add-PodeRoute -Method Post -Path '/inventory/swap/execute' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $b = $WebEvent.Data
        $res = Invoke-ComputerSwap -UserDisplayName ([string]$b.userName) -UserId ([string]$b.userId) -OldTitle ([string]$b.oldDevice) -NewTitle ([string]$b.newDevice)
        $st = if ($res.ok) { 'success' } else { 'partial' }
        Write-Audit $u.username $u.role 'computer-swap' ([string]$b.newDevice) @{ user = [string]$b.userName; old = [string]$b.oldDevice; new = [string]$b.newDevice } $st 0 ''
        try { Send-SwapNotification -Result $res -Operator $u.username | Out-Null } catch {}
        Write-PodeJsonResponse -Value $res
    }

    # --- Change status (existing device) ---
    Add-PodeRoute -Method Get -Path '/inventory/status' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $dep = @(); $comp = @()
        try { $c = Get-InventoryChoices; $dep = @($c.deployment); $comp = @($c.computer) } catch {}
        $chrome = Get-AppChrome -Active 'inventory' -User $u -Title 'Change computer status' -Subtitle 'Update deployment / computer status' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'inventory-status' -Data @{
            user = $u; deployChoices = $dep; computerChoices = $comp
            head = $chrome.head; open = $chrome.open; close = $chrome.close
        }
    }
    Add-PodeRoute -Method Post -Path '/inventory/status/apply' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $b = $WebEvent.Data
        $hasComment = [bool](([string]$b.comment).Trim())
        $res = Set-InventoryStatus -Title ([string]$b.device) -Deployment ([string]$b.deployment) -Computer ([string]$b.computer) -Comment ([string]$b.comment) -SetComment:$hasComment
        $st = if ($res.ok) { 'success' } else { 'error' }
        Write-Audit $u.username $u.role 'inventory-status' ([string]$b.device) @{ deployment = [string]$b.deployment; computer = [string]$b.computer } $st 0 ([string]$res.error)
        Write-PodeJsonResponse -Value $res
    }

    # --- Add computer (single + CSV bulk; Intune autofill) ---
    Add-PodeRoute -Method Get -Path '/inventory/add' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $dep = @(); $comp = @(); $intu = @()
        try { $c = Get-InventoryChoices; $dep = @($c.deployment); $comp = @($c.computer); $intu = @($c.intune) } catch {}
        $chrome = Get-AppChrome -Active 'inventory' -User $u -Title 'Add computer' -Subtitle 'Single entry or CSV bulk' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'inventory-add' -Data @{
            user = $u; intuneOn = [bool](Test-IntuneConfigured)
            deployChoices = $dep; computerChoices = $comp; intuneChoices = $intu
            head = $chrome.head; open = $chrome.open; close = $chrome.close
        }
    }
    Add-PodeRoute -Method Get -Path '/inventory/lookup' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $d = $null; try { $d = Get-IntuneDeviceDetail ([string]$WebEvent.Query['device']) } catch {}
        if ($d) { Write-PodeJsonResponse -Value @{ found = $true; serial = [string]$d.serialNumber; model = [string]$d.model; brand = [string]$d.manufacturer; os = [string]$d.operatingSystem } }
        else    { Write-PodeJsonResponse -Value @{ found = $false } }
    }
    Add-PodeRoute -Method Post -Path '/inventory/add/single' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $b = $WebEvent.Data
        $row = @{}
        foreach ($k in 'title', 'brand', 'model', 'serial', 'os', 'deploymentStatus', 'computerStatus', 'intuneStatus', 'purchaseDate', 'purchasePrice', 'warranty', 'comment') { $row[$k] = [string]$b.$k }
        $res = Add-InventoryComputer -Row $row
        $st = if ($res.ok) { 'success' } else { 'error' }
        Write-Audit $u.username $u.role 'inventory-add' ([string]$row.title) @{} $st 0 ([string]$res.error)
        Write-PodeJsonResponse -Value $res
    }
    Add-PodeRoute -Method Get -Path '/inventory/add/template' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $hdr = 'ComputerName,Brand,Model,Serial,OS,DeploymentStatus,ComputerStatus,IntuneStatus,PurchaseDate,PurchasePrice,Warranty,Comment'
        $sample = 'LAPTOP999,Dell,Latitude 5540,ABC12345,Windows,Needs Image,Needs to be Imaged,Not Managed,2026-01-15,1200,2029-01-15,new arrival'
        Add-PodeHeader -Name 'Content-Disposition' -Value 'attachment; filename="inventory-template.csv"'
        Write-PodeTextResponse -Value ("$hdr`r`n$sample`r`n") -ContentType 'text/csv'
    }
    Add-PodeRoute -Method Post -Path '/inventory/add/bulk' -ScriptBlock {
        if (-not (Require 'inventory' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $b = $WebEvent.Data
        # rows arrive base64(JSON). Parse with JavaScriptSerializer, NOT ConvertFrom-Json: WinPS 5.1's
        # ConvertFrom-Json collapses a top-level array of uniform simple objects into ONE columnar object
        # (title -> @('a','b')), which merged every CSV row into one. JavaScriptSerializer returns real rows.
        $rows = @()
        try {
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$b.rows))
            Add-Type -AssemblyName System.Web.Extensions
            $rows = @((New-Object System.Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($json))
        } catch {}
        $results = @()
        foreach ($r in $rows) {
            $row = @{}
            foreach ($k in 'title', 'brand', 'model', 'serial', 'os', 'deploymentStatus', 'computerStatus', 'intuneStatus', 'purchaseDate', 'purchasePrice', 'warranty', 'comment') { $row[$k] = [string]$r[$k] }
            $res = Add-InventoryComputer -Row $row
            $results += @{ title = $res.title; ok = [bool]$res.ok; error = [string]$res.error }
        }
        $okCount = @($results | Where-Object { $_.ok }).Count
        Write-Audit $u.username $u.role 'inventory-add-bulk' "$($results.Count) rows" @{ added = $okCount } 'success' 0 ''
        Write-PodeJsonResponse -Value @{ total = $results.Count; added = $okCount; results = $results }
    }

    # ---- Scheduled reports (admin + helpdesk): each user manages their own; admins can view/edit/create
    #      for anyone via ?scope=all (to support helpdesk). ----
    Add-PodeRoute -Method Get -Path '/admin/reports' -ScriptBlock {
        if (-not (Require 'manage-reports' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $isAdmin = ($u.role -eq 'admin')
        $viewAll = ($isAdmin -and ("$($WebEvent.Query['scope'])" -eq 'all'))
        # Catalog is role-scoped: helpdesk sees only HelpDesk-tagged scripts; admin sees all (incl. Intune/Veeam).
        $scriptOptions = Get-ScriptOptionsHtml -Dir $using:ScriptDir -Role $u.role
        $all = @(Get-ReportSchedules)
        $visible = if ($viewAll) { $all } else { @($all | Where-Object { [string]$_.owner -eq $u.username }) }
        # Edit prefill - only for a schedule the user may edit (own, or any when admin).
        $editRec = $null; $editId = [string]$WebEvent.Query['edit']
        if ($editId) {
            $cand = @($all | Where-Object { [string]$_.id -eq $editId }) | Select-Object -First 1
            if ($cand -and ($isAdmin -or [string]$cand.owner -eq $u.username)) { $editRec = $cand }
        }
        $rowsHtml = (@($visible) | ForEach-Object {
            $s = $_
            $when = Get-ReportScheduleText $s
            $rec  = (@($s.recipients) -join ', ')
            $en   = if ($s.enabled) { '<span class="pill s-complete">on</span>' } else { '<span class="pill s-pending-sync">off</span>' }
            $lastTxt = '<span class="note">never</span>'
            if ($s.lastRun) {
                $lt = try { ([datetime]$s.lastRun).ToString('MM/dd/yyyy h:mm tt') } catch { [string]$s.lastRun }
                $lastTxt = "$(ConvertTo-PSCEncoded $lt)<br><span class='note'>$(ConvertTo-PSCEncoded ([string]$s.lastStatus))</span>"
            }
            $ownerCell = if ($viewAll) { "<td>$(ConvertTo-PSCEncoded ([string]$s.owner))</td>" } else { '' }
            "<tr><td>$(ConvertTo-PSCEncoded ([string]$s.name))<br><span class='note'>$(ConvertTo-PSCEncoded ([string]$s.script))</span></td>$ownerCell<td>$(ConvertTo-PSCEncoded $when)</td><td>$(ConvertTo-PSCEncoded $rec)</td><td>$en</td><td>$lastTxt</td><td style='white-space:nowrap'><button class='secondary' onclick=`"repEdit('$($s.id)')`">Edit</button> <button class='secondary' onclick=`"repRun('$($s.id)')`">Run now</button> <button class='danger' onclick=`"repDel('$($s.id)')`">Delete</button></td></tr>"
        }) -join ''
        # Form prefill blob (defaults for create; the selected schedule for edit).
        $ef = [ordered]@{ id=''; name=''; script=''; recipients=''; frequency='daily'; hour=7; minute=0; dayOfWeek=1; dayOfMonth=1; enabled=$true; owner=''; params='' }
        if ($editRec) {
            $pl = ''
            if ($editRec.params) { $pl = (@($editRec.params.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "`n") }
            $ef = [ordered]@{ id=[string]$editRec.id; name=[string]$editRec.name; script=[string]$editRec.script; recipients=(@($editRec.recipients) -join ', '); frequency=[string]$editRec.frequency; hour=[int]$editRec.hour; minute=[int]$editRec.minute; dayOfWeek=[int]$editRec.dayOfWeek; dayOfMonth=[int]$editRec.dayOfMonth; enabled=[bool]$editRec.enabled; owner=[string]$editRec.owner; params=$pl }
        }
        $bs = [char]92
        $efJson = ($ef | ConvertTo-Json -Compress -Depth 4) -replace '<', ($bs + 'u003c') -replace '>', ($bs + 'u003e') -replace '&', ($bs + 'u0026')
        $chrome = Get-AppChrome -Active 'reports' -User $u -Title 'Scheduled reports' -Subtitle 'Run a script on a schedule and email it' -HasLogo ([bool]((Get-Store config).logoFile))
        $backUrl = if ($viewAll) { '/admin/reports?scope=all' } else { '/admin/reports' }
        Write-PodeViewResponse -Path 'reports' -Data @{ user=$u; isAdmin=$isAdmin; viewAll=$viewAll; rowsHtml=$rowsHtml; scriptOptions=$scriptOptions; efJson=$efJson; backUrl=$backUrl; smtpOk=[bool](Test-SmtpConfigured); msg=$WebEvent.Query['e']; head=$chrome.head; open=$chrome.open; close=$chrome.close }
    }
    Add-PodeRoute -Method Post -Path '/admin/reports/save' -ScriptBlock {
        if (-not (Require 'manage-reports' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $b = $WebEvent.Data
        $name = ([string]$b.name).Trim()
        $script = Split-Path -Leaf ([string]$b.script)
        if (-not $name -or -not $script) { Move-PodeResponseUrl -Url '/admin/reports?e=Name+and+script+are+required'; return }
        # Server-side role gate on the chosen script (a helpdesk user can only schedule HelpDesk-tagged scripts,
        # mirroring the /run gate) - not just what the dropdown offered them.
        $spath = Join-Path $using:ScriptDir $script
        if (-not (Test-Path $spath)) { Move-PodeResponseUrl -Url '/admin/reports?e=Unknown+script'; return }
        $smeta = Get-ScriptMeta $spath
        if ($u.role -ne 'admin' -and $smeta.Role -ne 'HelpDesk') { Move-PodeResponseUrl -Url '/admin/reports?e=You+are+not+allowed+to+schedule+that+script'; return }
        if ($smeta.Category -eq 'Intune' -and -not (Test-IntuneConfigured)) { Move-PodeResponseUrl -Url '/admin/reports?e=Intune+add-on+is+not+enabled'; return }
        $recips = @(([string]$b.recipients) -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $recips.Count) { Move-PodeResponseUrl -Url '/admin/reports?e=At+least+one+recipient+is+required'; return }
        # optional params: "Name=Value" per line
        $params = @{}
        foreach ($line in (([string]$b.params) -split "`n")) { if ($line -match '^\s*([^=\s]+)\s*=\s*(.+?)\s*$') { $params[$Matches[1]] = $Matches[2] } }
        $rec = [pscustomobject]@{
            id          = if ($b.id) { [string]$b.id } else { [guid]::NewGuid().ToString('N') }
            name        = $name
            script      = $script
            params      = ([pscustomobject]$params)
            recipients  = $recips
            frequency   = ([string]$b.frequency)
            hour        = [int]$b.hour
            minute      = if ($b.minute) { [int]$b.minute } else { 0 }
            dayOfWeek   = if ($b.dayOfWeek) { [int]$b.dayOfWeek } else { 1 }
            dayOfMonth  = if ($b.dayOfMonth) { [int]$b.dayOfMonth } else { 1 }
            enabled     = ("$($b.enabled)" -match '^(true|on|1)$')
            owner       = if (($u.role -eq 'admin') -and ([string]$b.owner).Trim()) { ([string]$b.owner).Trim() } else { $u.username }
            ownerRole   = $u.role
            lastRun     = ''
            lastStatus  = ''
        }
        $scheds = @(Get-ReportSchedules)
        $existing = @($scheds | Where-Object { $_.id -eq $rec.id })
        if ($existing.Count) {
            # non-admins can only edit their own; admins can edit anyone's (to support helpdesk)
            if (($u.role -ne 'admin') -and ([string]$existing[0].owner -ne $u.username)) { Move-PodeResponseUrl -Url '/admin/reports?e=That+schedule+is+not+yours'; return }
            $rec.lastRun = [string]$existing[0].lastRun; $rec.lastStatus = [string]$existing[0].lastStatus
            # keep the existing owner unless an admin explicitly reassigned it via the owner field
            if (-not (($u.role -eq 'admin') -and ([string]$b.owner).Trim())) { $rec.owner = [string]$existing[0].owner }
            $scheds = @($scheds | Where-Object { $_.id -ne $rec.id })
        }
        $scheds = @($scheds) + $rec
        Set-ReportSchedules $scheds
        Write-Audit $u.username $u.role 'configure' 'report-schedule' @{ name=$name; script=$script } 'success' 0 ''
        Move-PodeResponseUrl -Url '/admin/reports?e=Saved'
    }
    Add-PodeRoute -Method Post -Path '/admin/reports/delete' -ScriptBlock {
        if (-not (Require 'manage-reports' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $id = [string]$WebEvent.Data.id
        $scheds = @(Get-ReportSchedules)
        $target = @($scheds | Where-Object { $_.id -eq $id })
        if ($target.Count -and ($u.role -ne 'admin') -and [string]$target[0].owner -ne $u.username) { Write-PodeJsonResponse -Value @{ ok=$false; error='Not your schedule.' }; return }
        Set-ReportSchedules @($scheds | Where-Object { $_.id -ne $id })
        Write-PodeJsonResponse -Value @{ ok=$true }
    }
    Add-PodeRoute -Method Post -Path '/admin/reports/run' -ScriptBlock {
        if (-not (Require 'manage-reports' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $id = [string]$WebEvent.Data.id
        $scheds = @(Get-ReportSchedules)
        $s = @($scheds | Where-Object { $_.id -eq $id })
        if (-not $s.Count) { Write-PodeJsonResponse -Value @{ ok=$false; error='Schedule not found.' }; return }
        if (($u.role -ne 'admin') -and [string]$s[0].owner -ne $u.username) { Write-PodeJsonResponse -Value @{ ok=$false; error='Not your schedule.' }; return }
        $res = Send-ScheduledReport -Schedule $s[0]
        Set-ReportRunResult -Schedule $s[0] -Result $res
        Set-ReportSchedules $scheds
        Write-Audit $u.username $u.role 'report-run' ([string]$s[0].script) @{ name=[string]$s[0].name; rows=$res.rows; mailed=[bool]$res.mailed } ($(if($res.ok){'success'}else{'error'})) 0 ($res.error)
        Write-PodeJsonResponse -Value @{ ok=$res.ok; rows=$res.rows; mailed=$res.mailed; error=$res.error; mailError=$res.mailError; mailNote=$res.mailNote }
    }

    # ---- Veeam backup reports (admin; OPTIONAL add-on, gated by data\veeam.config.json) ----
    Add-PodeRoute -Method Get -Path '/admin/veeam' -ScriptBlock {
        if (-not (Require 'veeam-reports' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $days = [int]($WebEvent.Query['days']); if ($days -notin 7,30,60,90) { $days = 30 }
        $job  = [string]$WebEvent.Query['job']
        $err = ''; $configured = [bool](Test-VeeamConfigured)
        $pill = { param($res) switch ("$res") { 'Success' { '<span class="pill s-complete">Success</span>' } 'Warning' { '<span class="pill s-manual-needed">Warning</span>' } 'Failed' { '<span class="pill s-partial">Failed</span>' } default { "<span class='pill s-pending-sync'>$(ConvertTo-PSCEncoded ([string]$res))</span>" } } }
        $jobNames = @(); $bodyHtml = ''; $controlsHtml = ''
        $reportRows = @(); $reportTitle = 'Veeam backups'   # flat rows for CSV/email of the current view
        if (-not $configured) {
            $bodyHtml = "<div class='card'><p class='note' style='margin:0'>Veeam is not configured. Run <code>graph-setup\Set-VeeamConfig.ps1</code> on the server.</p></div>"
        }
        else {
            $sr = Get-VeeamSessions -Days $days
            if (-not $sr.ok) {
                $err = [string]$sr.error
                $bodyHtml = "<div class='card'><p class='note' style='margin:0'>Unavailable - see the message above.</p></div>"
            }
            else {
                $jobNames = @(@(Get-VeeamLastJobStatus $sr) | Select-Object -Expand Job)
                if ($job -and ($jobNames -contains $job)) {
                    # ---- one job: its individual runs inside the window ----
                    $runs = @(Get-VeeamJobSessions $sr -Job $job)
                    $jh   = @(Get-VeeamJobHistory $sr) | Where-Object { $_.Job -eq $job } | Select-Object -First 1
                    $sum  = if ($jh) { "$($jh.Success) success &middot; $($jh.Warning) warning &middot; $($jh.Failed) failed &middot; $($jh.Total) runs" } else { 'no runs in this window' }
                    $runRows = if ($runs.Count) { (@($runs) | ForEach-Object {
                        $en = try { ([datetime]$_.End).ToString('MM/dd/yyyy h:mm tt') } catch { [string]$_.End }
                        "<tr><td>$(ConvertTo-PSCEncoded $en)</td><td>$(& $pill $_.Result)</td><td>$(ConvertTo-PSCEncoded ([string]$_.Duration))</td></tr>"
                    }) -join '' } else { "<tr><td colspan='3' class='note'>No runs for this job in the last $days days.</td></tr>" }
                    $bodyHtml = "<div class='card'><h3 style='margin:0 0 4px'>$(ConvertTo-PSCEncoded $job) &mdash; last $days days</h3><p class='note' style='margin:0 0 10px'>$sum</p><div style='overflow-x:auto'><table><tr><th>Run (ended)</th><th>Result</th><th>Duration</th></tr>$runRows</table></div></div>"
                    $reportRows = @(Get-VeeamJobReportRows $sr -Job $job); $reportTitle = "$job (last $days days)"
                }
                else {
                    $job = ''   # normalize to "All jobs"
                    $last = @(Get-VeeamLastJobStatus $sr); $hist = @(Get-VeeamJobHistory $sr)
                    $lastHtml = if ($last.Count) { (@($last) | ForEach-Object {
                        $lr = try { ([datetime]$_.LastRun).ToString('MM/dd/yyyy h:mm tt') } catch { [string]$_.LastRun }
                        "<tr><td>$(ConvertTo-PSCEncoded ([string]$_.Job))</td><td>$(& $pill $_.Result)</td><td>$(ConvertTo-PSCEncoded $lr)</td></tr>"
                    }) -join '' } else { "<tr><td colspan='3' class='note'>No jobs found.</td></tr>" }
                    $histHtml = if ($hist.Count) { (@($hist) | ForEach-Object {
                        "<tr><td>$(ConvertTo-PSCEncoded ([string]$_.Job))</td><td class='ok'>$($_.Success)</td><td class='man'>$($_.Warning)</td><td class='fail'>$($_.Failed)</td><td>$($_.Total)</td></tr>"
                    }) -join '' } else { "<tr><td colspan='5' class='note'>No backup sessions found in the last $days days.</td></tr>" }
                    $bodyHtml = "<div class='card'><h3 style='margin:0 0 4px'>Last backup result per job</h3><p class='note' style='margin:0 0 10px'>The most recent run of each job (regardless of window).</p><div style='overflow-x:auto'><table><tr><th>Job</th><th>Last result</th><th>Last run</th></tr>$lastHtml</table></div></div>" +
                                "<div class='card'><h3>Success / warning / failure &mdash; last $days days</h3><div style='overflow-x:auto'><table><tr><th>Job</th><th>Success</th><th>Warning</th><th>Failed</th><th>Total</th></tr>$histHtml</table></div><p class='note' style='margin-top:10px'>Read-only view of Veeam sessions over PowerShell remoting. No backups are started or changed.</p></div>"
                    $reportRows = @(Get-VeeamReportRows $sr); $reportTitle = "Veeam backups (last $days days)"
                }
            }
        }
        if ($configured) {
            $jobEnc  = [uri]::EscapeDataString([string]$job)
            $jobOpts = "<option value=''>All jobs</option>" + ((@($jobNames) | ForEach-Object {
                $selAttr = if ($_ -eq $job) { ' selected' } else { '' }
                "<option$selAttr>$(ConvertTo-PSCEncoded ([string]$_))</option>"
            }) -join '')
            $winHtml = (@(7,30,60,90) | ForEach-Object {
                if ($_ -eq $days) { "<b>$($_)d</b>" } else { "<a href='/admin/veeam?days=$($_)&job=$jobEnc'>$($_)d</a>" }
            }) -join ' &middot; '
            $controlsHtml = "<div class='card'>" +
                "<div style='display:flex;gap:14px;align-items:flex-end;flex-wrap:wrap'>" +
                    "<div><label>Job</label><br><select onchange=`"location.href='/admin/veeam?days=$days&job='+encodeURIComponent(this.value)`">$jobOpts</select></div>" +
                    "<div style='margin-left:auto' class='note'>Window: $winHtml</div>" +
                "</div>" +
                "<div style='display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:12px'>" +
                    "<button class='secondary' onclick='veeamCsv()'>Export CSV</button>" +
                    $(if (Test-SharePointConfigured) { "<button class='secondary' onclick=`"location.href='/admin/veeam/remediation'`">Remediation</button>" } else { '' }) +
                    "<span style='margin-left:auto;display:flex;gap:8px;align-items:center'>" +
                        "<input id='veeamMailTo' placeholder='email address' style='width:210px'>" +
                        "<button class='secondary' onclick='veeamEmail()'>Email</button> <span id='veeamMailStatus' style='font-size:12px'></span>" +
                    "</span>" +
                "</div></div>"
        }
        # Flat rows of the current view (all-jobs summary OR one job's runs) for client-side CSV/email.
        $rowsJson = if (@($reportRows).Count) { '[' + ((@($reportRows) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 }) -join ',') + ']' } else { '[]' }
        # Escape HTML-significant chars as \uXXXX so an injected job name (e.g. containing "</script>") can't
        # break out of the inline <script> where this JSON is embedded. Stays valid JSON / JS.
        $bs = [char]92   # backslash, built via char code to keep the \uXXXX escapes unambiguous
        $rowsJson = $rowsJson -replace '<', ($bs + 'u003c') -replace '>', ($bs + 'u003e') -replace '&', ($bs + 'u0026')
        $chrome = Get-AppChrome -Active 'veeam' -User $u -Title 'Veeam backups' -Subtitle 'Per-job status and success/failure history' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'veeam' -Data @{ user=$u; configured=$configured; days=$days; job=$job; err=$err; controlsHtml=$controlsHtml; bodyHtml=$bodyHtml; rowsJson=$rowsJson; reportTitle=$reportTitle; head=$chrome.head; open=$chrome.open; close=$chrome.close }
    }

    # ---- Veeam -> SharePoint remediation tracking (admin, optional add-on) ----
    Add-PodeRoute -Method Get -Path '/admin/veeam/remediation' -ScriptBlock {
        if (-not (Require 'veeam-reports' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $configured = [bool](Test-SharePointConfigured)
        $err = ''; $rows = @()
        if ($configured) { try { $rows = @(Get-SPRemediationRows) } catch { $err = "$($_.Exception.Message)" } }
        $pill = { param($res) switch ("$res") { 'Success' { '<span class="pill s-complete">Success</span>' } 'Warning' { '<span class="pill s-manual-needed">Warning</span>' } 'Failed' { '<span class="pill s-partial">Failed</span>' } default { "<span class='pill s-pending-sync'>$(ConvertTo-PSCEncoded ([string]$res))</span>" } } }
        $statusOpts = @('N/A','Open','Investigating','Remediated','Ignored')
        $bodyRows = if (@($rows).Count) { (@($rows) | ForEach-Object {
            $r = $_
            $sel = (@($statusOpts) | ForEach-Object { "<option$(if ($_ -eq $r.RemStatus) { ' selected' } else { '' })>$_</option>" }) -join ''
            $meta = "by $(ConvertTo-PSCEncoded ([string]$r.RemediatedBy)) $(ConvertTo-PSCEncoded ([string]$r.RemediatedAt))"
            "<tr data-id='$(ConvertTo-PSCEncoded ([string]$r.ItemId))'>" +
            "<td>$(ConvertTo-PSCEncoded ([string]$r.Job))</td>" +
            "<td>$(ConvertTo-PSCEncoded ([string]$r.BackupDate))</td>" +
            "<td>$(& $pill $r.VeeamResult)<div class='note'>S$($r.Success)/W$($r.Warning)/F$($r.Failed)</div></td>" +
            "<td><select class='remStatus'>$sel</select></td>" +
            "<td><textarea class='remNote' rows='2' style='width:100%;min-width:220px' placeholder='what fixed it'>$(ConvertTo-PSCEncoded ([string]$r.FixNote))</textarea><div class='note remMeta'>$meta</div></td>" +
            "<td><button class='secondary' onclick='remSave(this)'>Save</button></td></tr>"
        }) -join '' } else { "<tr><td colspan='6' class='note'>$(if ($configured) { 'No open items - successful backups need no remediation. Click <b>Sync now</b> to refresh from Veeam.' } else { 'Configure the add-on to begin.' })</td></tr>" }
        $chrome = Get-AppChrome -Active 'veeam' -User $u -Title 'Veeam remediation' -Subtitle 'Track and resolve backup failures via SharePoint' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'veeam-remediation' -Data @{ user=$u; configured=$configured; err=$err; bodyRows=$bodyRows; head=$chrome.head; open=$chrome.open; close=$chrome.close }
    }
    Add-PodeRoute -Method Post -Path '/admin/veeam/remediation/save' -ScriptBlock {
        if (-not (Require 'veeam-reports' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $b = $WebEvent.Data
        $id = [string]$b.itemId
        if (-not $id) { Write-PodeJsonResponse -Value @{ ok=$false; error='Missing item id.' }; return }
        $res = Set-SPRemediation -ItemId $id -Status ([string]$b.status) -Note ([string]$b.note) -By $u.username
        $when = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Write-Audit $u.username $u.role 'veeam-remediation' $id @{ status=[string]$b.status } ($(if ($res.ok) { 'success' } else { 'error' })) 0 ([string]$res.error)
        Write-PodeJsonResponse -Value @{ ok=$res.ok; error=$res.error; by=$u.username; at=$when }
    }
    Add-PodeRoute -Method Post -Path '/admin/veeam/remediation/sync' -ScriptBlock {
        if (-not (Require 'veeam-reports' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $res = Sync-VeeamToSharePoint -Days 7
        $sw.Stop()
        Write-Audit $u.username $u.role 'veeam-sp-sync' 'sharepoint' @{ created=$res.created; updated=$res.updated } ($(if ($res.ok) { 'success' } else { 'error' })) $sw.ElapsedMilliseconds ([string]$res.error)
        Write-PodeJsonResponse -Value $res
    }

    # Scheduled-report dispatcher: fires every 15 min, sends any report whose time has passed for its
    # current occurrence (see Reports.ps1 Test-ReportDue). No-op when there are no due schedules.
    Add-PodeSchedule -Name 'scheduled-reports' -Cron '*/15 * * * *' -ScriptBlock {
        try { Invoke-DueReports } catch {}
    }

    # Optional auto-processor: only acts when onboardingAutoRun is true in settings (default off).
    # Idempotent, so re-runs are harmless. Manual "Run now" always works. Runs every 3 min - a touch
    # FASTER than the ~5-min Entra Connect (ADSync) delta sync on the DC, so a freshly-synced new user
    # is picked up within one poll no matter how the two schedules' phases drift (the gMSA sync task
    # fires on a registration-relative clock, this fires on wall-clock boundaries).
    Add-PodeSchedule -Name 'cloud-onboarding' -Cron '*/3 * * * *' -ScriptBlock {
        try { Clear-CompletedOnboarding -Days 7 | Out-Null } catch {}   # prune finished users after 7 days (runs regardless of autoRun)
        try { if ((Get-ProvisionSettings).onboardingAutoRun) { Invoke-Onboarding | Out-Null } } catch {}
    }

    # Veeam job alerts: every 2 hours, email the configured recipient (smtp veeamAlertTo) about any NEW
    # Failed/Warning backup session. Deduped in data\veeam-alerts.json so each run alerts once; failed jobs
    # ask for remediation. No-op unless the Veeam add-on is configured.
    Add-PodeSchedule -Name 'veeam-alert' -Cron '15 */2 * * *' -ScriptBlock {
        try { if (Test-VeeamConfigured) { Send-VeeamJobAlerts -Days 3 | Out-Null } } catch {}
    }

    # Daily Veeam -> SharePoint status sync at 08:00. No-op unless the SharePoint add-on is configured;
    # writes only the synced columns, so it never disturbs remediation notes. Manual "Sync now" also works.
    Add-PodeSchedule -Name 'veeam-sharepoint-sync' -Cron '0 8 * * *' -ScriptBlock {
        try { if (Test-SharePointConfigured) { Sync-VeeamToSharePoint -Days 8 | Out-Null } } catch {}
    }
}

