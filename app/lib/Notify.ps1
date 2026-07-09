# Notify.ps1 - optional email notifications for user create / decommission events.
#
# Configuration lives in data\smtp.config.json (see graph-setup\Set-SmtpConfig.ps1), shaped:
#   { "enabled": true, "server": "smtp.host", "port": 25, "useSsl": false,
#     "from": "psconsole@example.com", "to": ["it@example.com"],
#     "username": "", "secret": "" }         # username/secret optional (anonymous relay if blank)
# "secret" (if present) is a DPAPI LocalMachine-encrypted password, same pattern as the Graph creds.
#
# Sending is ALWAYS best-effort: if SMTP isn't configured or a send fails, it is logged to
# data\notify.log and the caller continues. A notification failure must never break a create/decommission.

function Get-SmtpConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'smtp.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\smtp.config.json' }
}

function Test-SmtpConfigured {
    $p = Get-SmtpConfigPath
    if (-not (Test-Path $p)) { return $false }
    try { $c = Get-Content $p -Raw | ConvertFrom-Json; return ([bool]$c.enabled -and [bool]$c.server -and [bool]$c.from) } catch { return $false }
}

function Write-NotifyLog([string]$Msg) {
    try { Add-Content -Path (Join-Path (Get-DataDir) 'notify.log') -Value ("{0} {1}" -f (Get-Date).ToString('o'), $Msg) } catch {}
}

# Core sender: HTML email to EXPLICIT recipients. Returns @{ ok=..; note/error=.. }. Never throws.
function Send-PSCMail {
    param([string[]]$To,[string]$Subject,[string]$BodyHtml)
    if (-not (Test-SmtpConfigured)) { return @{ ok=$false; note='smtp not configured' } }
    $recips = @($To) | Where-Object { $_ }
    if (-not $recips.Count) { return @{ ok=$false; note='no recipients' } }
    $msg = $null; $smtp = $null
    try {
        $c  = Get-Content (Get-SmtpConfigPath) -Raw | ConvertFrom-Json
        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From = New-Object System.Net.Mail.MailAddress([string]$c.from)
        foreach ($t in $recips) { $msg.To.Add([string]$t) }
        $msg.Subject = $Subject
        $msg.Body = $BodyHtml
        $msg.IsBodyHtml = $true
        $smtp = New-Object System.Net.Mail.SmtpClient([string]$c.server, [int]$c.port)
        $smtp.EnableSsl = [bool]$c.useSsl
        if ($c.username) {
            $pw = ''
            if ($c.secret) {
                Add-Type -AssemblyName System.Security
                $pw = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$c.secret),$null,'LocalMachine'))
            }
            $smtp.Credentials = New-Object System.Net.NetworkCredential([string]$c.username, $pw)
        }
        $smtp.Send($msg)
        return @{ ok=$true }
    } catch {
        Write-NotifyLog "send to '$($recips -join ',')' failed: $($_.Exception.Message)"
        return @{ ok=$false; error=$_.Exception.Message }
    } finally {
        if ($msg)  { $msg.Dispose() }
        if ($smtp) { $smtp.Dispose() }
    }
}

# Send to the DEFAULT notification recipients from smtp.config.json ("to"). Used by create/decommission.
function Send-PSCNotification {
    param([string]$Subject,[string]$BodyHtml)
    if (-not (Test-SmtpConfigured)) { return @{ ok=$false; note='smtp not configured' } }
    try { $c = Get-Content (Get-SmtpConfigPath) -Raw | ConvertFrom-Json } catch { return @{ ok=$false; error='bad smtp config' } }
    $to = @($c.to) | Where-Object { $_ }
    if (-not $to.Count) { return @{ ok=$false; note='no default notification recipients set' } }
    Send-PSCMail -To $to -Subject $Subject -BodyHtml $BodyHtml
}

# Render script-run rows (array of objects) as a simple HTML table for emailing. Values are encoded.
function ConvertTo-ResultHtml {
    param([string]$Title,$Rows)
    $r = @($Rows)
    $head = "<div style='font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#111'><h2 style='margin:0 0 8px'>$(ConvertTo-PSCEncoded $Title)</h2>"
    $foot = "<p style='color:#888;font-size:12px'>Sent by PSConsole - $(@($r).Count) row(s), $((Get-Date).ToString('yyyy-MM-dd HH:mm')).</p></div>"
    if (-not $r.Count) { return $head + "<p>No rows.</p>" + $foot }
    $cols = @($r[0].PSObject.Properties.Name)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<table style='border-collapse:collapse;font-size:13px'><tr>")
    foreach ($c in $cols) { [void]$sb.Append("<th style='border:1px solid #ccc;padding:4px 8px;background:#f3f4f6;text-align:left'>$(ConvertTo-PSCEncoded $c)</th>") }
    [void]$sb.Append('</tr>')
    foreach ($row in $r) {
        [void]$sb.Append('<tr>')
        foreach ($c in $cols) { [void]$sb.Append("<td style='border:1px solid #ccc;padding:4px 8px'>$(ConvertTo-PSCEncoded ([string]$row.$c))</td>") }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')
    $head + $sb.ToString() + $foot
}

function New-NotifyRow($k,$v) { "<tr><td style='color:#555;padding:3px 10px 3px 0'>$(ConvertTo-PSCEncoded $k)</td><td style='padding:3px 0'>$(ConvertTo-PSCEncoded ([string]$v))</td></tr>" }

# Resolve the recipient list for a notification event from smtp.config.json:
#   'create'       -> createTo        (admin action)
#   'decommission' -> decommissionTo  (helpdesk action)
# Each falls back to the general "to" list if its specific list is empty.
function Get-NotifyRecipients([string]$Event) {
    if (-not (Test-SmtpConfigured)) { return @() }
    try { $c = Get-Content (Get-SmtpConfigPath) -Raw | ConvertFrom-Json } catch { return @() }
    $list = switch ($Event) {
        'create'       { $c.createTo }
        'decommission' { $c.decommissionTo }
        default        { $c.to }
    }
    $list = @($list) | Where-Object { $_ }
    if (-not $list.Count) { $list = @($c.to) | Where-Object { $_ } }
    @($list)
}

# --- event helpers used by the routes -------------------------------------------------------------

function Send-UserCreatedNotification {
    param([pscustomobject]$Plan,[string]$Operator,[string]$Dn)
    $groups = if (@($Plan.cloudGroups).Count) { (@($Plan.cloudGroups) -join ', ') } else { '(none)' }
    $body = "<div style='font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#111'>" +
            "<h2 style='margin:0 0 8px'>User created</h2>" +
            "<table style='border-collapse:collapse'>" +
            (New-NotifyRow 'Display name' $Plan.displayName) +
            (New-NotifyRow 'Username'     $Plan.samAccountName) +
            (New-NotifyRow 'Sign-in (UPN)' $Plan.userPrincipalName) +
            (New-NotifyRow 'Department'   $Plan.department) +
            (New-NotifyRow 'Job title'    $Plan.title) +
            (New-NotifyRow 'Mobile'       $Plan.mobile) +
            (New-NotifyRow 'Manager'      $Plan.manager) +
            (New-NotifyRow 'OU'           $Dn) +
            (New-NotifyRow 'Cloud groups' $groups) +
            (New-NotifyRow 'Created by'   $Operator) +
            (New-NotifyRow 'When'         ((Get-Date).ToString('yyyy-MM-dd HH:mm'))) +
            "</table><p style='color:#888;font-size:12px'>Sent by PSConsole. Cloud groups/license are applied after the account syncs to Entra.</p></div>"
    Send-PSCMail -To (Get-NotifyRecipients 'create') -Subject "PSConsole: user created - $($Plan.displayName)" -BodyHtml $body
}

function Send-UserDecommissionedNotification {
    param([pscustomobject]$Plan,[string]$Operator,$Result)
    $removed = if (@($Result.groupsRemoved).Count) { (@($Result.groupsRemoved) -join ', ') } else { '(none)' }
    $failed  = if (@($Result.groupsFailed).Count)  { (@($Result.groupsFailed)  -join ', ') } else { '(none)' }
    $body = "<div style='font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#111'>" +
            "<h2 style='margin:0 0 8px'>User decommissioned</h2>" +
            "<table style='border-collapse:collapse'>" +
            (New-NotifyRow 'Display name' $Plan.displayName) +
            (New-NotifyRow 'Username'     $Plan.sam) +
            (New-NotifyRow 'Sign-in (UPN)' $Plan.upn) +
            (New-NotifyRow 'Action'       'Disabled + moved to Disabled Accounts OU') +
            (New-NotifyRow 'Now at'       $Result.dn) +
            (New-NotifyRow 'On-prem groups removed' $removed) +
            (New-NotifyRow 'Group removals failed'  $failed) +
            (New-NotifyRow 'Decommissioned by' $Operator) +
            (New-NotifyRow 'When'         ((Get-Date).ToString('yyyy-MM-dd HH:mm'))) +
            "</table><p style='color:#888;font-size:12px'>Sent by PSConsole. Entra removal follows on the next ADSync cycle (out of sync scope).</p></div>"
    Send-PSCMail -To (Get-NotifyRecipients 'decommission') -Subject "PSConsole: user decommissioned - $($Plan.displayName)" -BodyHtml $body
}
