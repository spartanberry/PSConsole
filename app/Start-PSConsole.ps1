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
    Enable-PodeSessionMiddleware -Duration 3600 -Extend
    Set-PodeViewEngine -Type Pode

    function Get-User { $WebEvent.Session.Data.user }
    function Require($role, $action, $WebEvent) {
        $u = $WebEvent.Session.Data.user
        if (-not $u) { Move-PodeResponseUrl -Url '/login'; return $false }
        if (-not (Test-Authorized $u.role $action)) { Set-PodeResponseStatus -Code 403; Write-PodeTextResponse -Value 'Forbidden'; return $false }
        $true
    }

    Add-PodeRoute -Method Get -Path '/login' -ScriptBlock {
        Write-PodeViewResponse -Path 'login' -Data @{ error = $WebEvent.Query['e']; hasLogo = [bool]((Get-Store config).logoFile); head = (Get-LoginHead) }
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
            Move-PodeResponseUrl -Url '/'
        } else {
            Write-Audit $b.username 'n/a' 'login' '' @{} 'fail' 0 $res.reason
            Move-PodeResponseUrl -Url '/login?e=Invalid+credentials+or+no+assigned+role'
        }
    }
    Add-PodeRoute -Method Post -Path '/logout' -ScriptBlock { Remove-PodeSession; Move-PodeResponseUrl -Url '/login' }

    Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
        if (-not (Require 'helpdesk' 'run' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $scripts = Get-ChildItem $using:ScriptDir -Filter *.ps1 | Select-Object -Expand Name
        $chrome = Get-AppChrome -Active 'run' -User $u -Title 'Run scripts' -Subtitle 'Execute a curated PowerShell script' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'dashboard' -Data @{ user=$u; scripts=$scripts; head=$chrome.head; open=$chrome.open; close=$chrome.close }
    }

    # Admin landing / overview dashboard (helpdesk can be added later by relaxing the role check).
    Add-PodeRoute -Method Get -Path '/dashboard' -ScriptBlock {
        if (-not (Require 'helpdesk' 'run' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        if ($u.role -ne 'admin') { Set-PodeResponseStatus -Code 403; Write-PodeTextResponse -Value 'Admin only'; return }
        $q = @(Get-Store onboarding)
        $pending = @($q | Where-Object { $_.cloudStatus -ne 'complete' }).Count
        $scriptCount = @(Get-ChildItem $using:ScriptDir -Filter *.ps1).Count
        $recentRows = (@(Get-AuditTail 8) | ForEach-Object {
            $ts = try { ([datetime]$_.ts).ToString('MM/dd/yyyy h:mm tt') } catch { [string]$_.ts }
            "<tr><td>$(ConvertTo-PSCEncoded $ts)</td><td>$(ConvertTo-PSCEncoded ([string]$_.user))</td><td>$(ConvertTo-PSCEncoded ([string]$_.action))</td><td>$(ConvertTo-PSCEncoded ([string]$_.script))</td><td>$(ConvertTo-PSCEncoded ([string]$_.status))</td></tr>"
        }) -join ''
        $chrome = Get-AppChrome -Active 'dashboard' -User $u -Title 'Dashboard' -Subtitle 'Overview' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'admin-dashboard' -Data @{ user=$u; pending=$pending; scriptCount=$scriptCount; recentRows=$recentRows; head=$chrome.head; open=$chrome.open; close=$chrome.close }
    }

    # ---- User provisioning (admin-only for now; Phase 1 = on-prem AD create) ----
    Add-PodeRoute -Method Get -Path '/users/new' -ScriptBlock {
        if (-not (Require 'admin' 'create-user' $WebEvent)) { return }
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
            head = $chrome.head; open = $chrome.open; close = $chrome.close
        }
    }
    Add-PodeRoute -Method Post -Path '/users/new/preview' -ScriptBlock {
        if (-not (Require 'admin' 'create-user' $WebEvent)) { return }
        $b = $WebEvent.Data
        $jt = if ($b.jobTitles) { @([string]$b.jobTitles -split '\|' | Where-Object { $_ }) } else { @() }
        $sup = ("$($b.isSupervisor)" -match '^(true|on|1)$')
        $plan = Get-ProvisionPlan -FirstName $b.firstName -LastName $b.lastName -Username $b.username -Department $b.department -Manager $b.manager -JobTitles $jt -Mobile $b.mobile -IsSupervisor:$sup
        $errs = @(Test-ProvisionPlan $plan)
        Write-PodeJsonResponse -Value @{ ok=($errs.Count -eq 0); errors=$errs; plan=$plan }
    }
    Add-PodeRoute -Method Post -Path '/users/new/create' -ScriptBlock {
        if (-not (Require 'admin' 'create-user' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user; $b = $WebEvent.Data
        $jt = if ($b.jobTitles) { @([string]$b.jobTitles -split '\|' | Where-Object { $_ }) } else { @() }
        $sup = ("$($b.isSupervisor)" -match '^(true|on|1)$')
        $plan = Get-ProvisionPlan -FirstName $b.firstName -LastName $b.lastName -Username $b.username -Department $b.department -Manager $b.manager -JobTitles $jt -Mobile $b.mobile -IsSupervisor:$sup
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
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $res = New-OnPremUser -Plan $plan -Password $b.newPassword -OperatorUser $b.opUser -OperatorPassword $b.opPassword
        $sw.Stop()
        # Audit params deliberately EXCLUDE opPassword/newPassword.
        $status = if ($res.ok) { 'success' } else { 'error' }
        $detail = if ($res.ok) { $res.dn } else { $res.error }
        Write-Audit $u.username $u.role 'create-user' $plan.userPrincipalName @{ ou=$plan.ou; dept=$plan.department; by=$b.opUser } $status $sw.ElapsedMilliseconds $detail
        if ($res.ok) {
            Add-OnboardingPending -Plan $plan -Operator $u.username -Dn $res.dn
            try { Send-UserCreatedNotification -Plan $plan -Operator $u.username -Dn $res.dn | Out-Null } catch {}
        }
        Write-PodeJsonResponse -Value @{ ok=$res.ok; error=$res.error; dn=$res.dn; plan=$plan; cloudPending=[bool]$res.ok }
    }

    # ---- Decommission user (helpdesk + admin): disable + move to Disabled Accounts OU ----
    Add-PodeRoute -Method Get -Path '/users/decommission' -ScriptBlock {
        if (-not (Require 'helpdesk' 'decommission-user' $WebEvent)) { return }
        $s = Get-ProvisionSettings
        $chrome = Get-AppChrome -Active 'decommission' -User $WebEvent.Session.Data.user -Title 'Decommission User' -Subtitle 'Disable + move to Disabled Accounts OU' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'user-decommission' -Data @{
            user       = $WebEvent.Session.Data.user
            enabled    = [bool]$s.enabled
            disabledOu = [string]$s.disabledOu
            head = $chrome.head; open = $chrome.open; close = $chrome.close
        }
    }
    Add-PodeRoute -Method Post -Path '/users/decommission/preview' -ScriptBlock {
        if (-not (Require 'helpdesk' 'decommission-user' $WebEvent)) { return }
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
        if (-not (Require 'helpdesk' 'decommission-user' $WebEvent)) { return }
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
        if (-not (Require 'helpdesk' 'run' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $name = Split-Path -Leaf $WebEvent.Data.script          # leaf only - blocks path traversal
        $path = Join-Path $using:ScriptDir $name
        if (-not (Test-Path $path)) { Set-PodeResponseStatus -Code 404; return }
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
        if (-not (Require 'helpdesk' 'run' $WebEvent)) { return }
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
        if (-not (Require 'admin' 'upload' $WebEvent)) { return }
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
        if (-not (Require 'admin' 'configure' $WebEvent)) { return }
        $cfg = Get-Store config
        $chrome = Get-AppChrome -Active 'config' -User $WebEvent.Session.Data.user -Title 'Config' -Subtitle 'Directory auth, branding, provisioning' -HasLogo ([bool]$cfg.logoFile)
        Write-PodeViewResponse -Path 'config' -Data @{ cfg=$cfg; user=$WebEvent.Session.Data.user; head=$chrome.head; open=$chrome.open; close=$chrome.close }
    }
    Add-PodeRoute -Method Post -Path '/admin/config' -ScriptBlock {
        if (-not (Require 'admin' 'configure' $WebEvent)) { return }
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
        if (-not (Require 'admin' 'view-history' $WebEvent)) { return }
        $from = [string]$WebEvent.Query['from']; $to = [string]$WebEvent.Query['to']
        $rows = if ($from -or $to) { Get-AuditRange -From $from -To $to -Max 2000 } else { Get-AuditTail 500 }
        Write-PodeJsonResponse -Value @{ rows = $rows }
    }

    Add-PodeRoute -Method Post -Path '/admin/logo' -ScriptBlock {
        if (-not (Require 'admin' 'configure' $WebEvent)) { return }
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
        if (-not (Require 'admin' 'configure' $WebEvent)) { return }
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
        if (-not (Require 'admin' 'configure' $WebEvent)) { return }
        $s = Get-ProvisionSettings
        $chrome = Get-AppChrome -Active 'config' -User $WebEvent.Session.Data.user -Title 'Department mapping' -Subtitle 'Provisioning settings' -HasLogo ([bool]((Get-Store config).logoFile))
        Write-PodeViewResponse -Path 'deptmap' -Data @{
            user = $WebEvent.Session.Data.user
            json = (ConvertTo-PSCEncoded ($s | ConvertTo-Json -Depth 8))
            msg  = $WebEvent.Query['e']
            head = $chrome.head; open = $chrome.open; close = $chrome.close
        }
    }
    Add-PodeRoute -Method Post -Path '/admin/deptmap' -ScriptBlock {
        if (-not (Require 'admin' 'configure' $WebEvent)) { return }
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
        if (-not (Require 'admin' 'create-user' $WebEvent)) { return }
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
        if (-not (Require 'admin' 'create-user' $WebEvent)) { return }
        $u = $WebEvent.Session.Data.user
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $sum = Invoke-Onboarding
        $sw.Stop()
        Write-Audit $u.username $u.role 'onboarding-run' 'cloud' @{ processed=$sum.processed; completed=$sum.completed; partial=$sum.partial; waiting=$sum.waiting } 'success' $sw.ElapsedMilliseconds ''
        Write-PodeJsonResponse -Value $sum
    }

    # Optional auto-processor: runs every 5 min but only acts when onboardingAutoRun is true in
    # settings (default off). Idempotent, so re-runs are harmless. Manual "Run now" always works.
    Add-PodeSchedule -Name 'cloud-onboarding' -Cron '*/5 * * * *' -ScriptBlock {
        try { if ((Get-ProvisionSettings).onboardingAutoRun) { Invoke-Onboarding | Out-Null } } catch {}
    }
}

