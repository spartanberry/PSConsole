# Alerts.ps1 - proactive alerting hub. Currently: the weekly credential-expiration digest, delivered
# through the reusable channels in Notify.ps1 (email via Send-PSCMail, Teams via Send-TeamsMessage).
#
# Settings live in the main config store under `expirationAlert`:
#   { enabled:bool, thresholdDays:int(30), channels:['email','teams'], recipients:['a@x'] }
# Cadence is fixed weekly (Monday 08:00) by the 'expiration-alert' Pode schedule in Start-PSConsole;
# the digest is sent every week regardless (an all-clear when nothing is within the threshold), which
# is what a weekly digest means. Everything is best-effort - a send failure never throws.

$script:ExpirationAlertScript = '40-Get-ExpiringCredentials.ps1'

function Get-ExpirationAlertSettings {
    $def = [ordered]@{ enabled = $false; thresholdDays = 30; channels = @('email'); recipients = @() }
    $cfg = Get-Store config
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'expirationAlert') -and $cfg.expirationAlert) {
        $s = $cfg.expirationAlert
        if ($null -ne $s.enabled)       { $def.enabled       = [bool]$s.enabled }
        if ($s.thresholdDays)           { $def.thresholdDays = [int]$s.thresholdDays }
        if ($null -ne $s.channels)      { $def.channels      = @(@($s.channels) | Where-Object { $_ -in @('email','teams') }) }
        if ($null -ne $s.recipients)    { $def.recipients    = @(@($s.recipients) | Where-Object { $_ }) }
    }
    $def
}

function Set-ExpirationAlertSettings {
    param([bool]$Enabled, [int]$ThresholdDays, [string[]]$Channels, [string[]]$Recipients)
    if ($ThresholdDays -lt 1)   { $ThresholdDays = 1 }
    if ($ThresholdDays -gt 365) { $ThresholdDays = 365 }
    $val = [ordered]@{
        enabled       = [bool]$Enabled
        thresholdDays = $ThresholdDays
        channels      = @(@($Channels) | Where-Object { $_ -in @('email','teams') })
        recipients    = @(@($Recipients) | Where-Object { $_ })
    }
    $cfg = Get-Store config
    $cfg | Add-Member -NotePropertyName expirationAlert -NotePropertyValue $val -Force
    Set-Store config $cfg
    $val
}

# Build + send the digest. Returns @{ ran; actionable; total; email=@{..}; teams=@{..} } (never throws).
# -Force runs even when disabled (used by the "send now" test button).
function Invoke-ExpirationAlert {
    param([switch]$Force)
    $s = Get-ExpirationAlertSettings
    if (-not $s.enabled -and -not $Force) { return @{ ran = $false; note = 'disabled' } }

    $days = [int]$s.thresholdDays
    $r = Invoke-ReportScriptFile -Name $script:ExpirationAlertScript -Parameters @{ Days = $days } -TimeoutSec 120
    $rows = @($r.data)
    if (-not $r.ok) { Write-NotifyLog "expiration-alert: script error: $($r.error)" }

    # Actionable = expired or within the threshold window (the script already flags with -Days = threshold).
    $act = @($rows | Where-Object { $_.Status -eq 'EXPIRED' -or ([string]$_.Status) -like 'Expiring*' } |
        Sort-Object @{ E = { if ($null -eq $_.DaysLeft) { [double]::MaxValue } else { [double]$_.DaysLeft } } })
    $expired  = @($act | Where-Object { $_.Status -eq 'EXPIRED' }).Count
    $soon     = @($act).Count - $expired

    $result = @{ ran = $true; actionable = @($act).Count; total = $rows.Count; expired = $expired; soon = $soon }

    # ---- Email channel ----
    if ($s.channels -contains 'email') {
        $recips = @($s.recipients) | Where-Object { $_ }
        if (-not $recips.Count) { $recips = @(Get-NotifyRecipients 'expiration') }   # falls back to smtp 'to'
        $subj = if (@($act).Count) { "PSConsole: $(@($act).Count) credential(s) expiring within $days days ($expired expired)" }
                else               { "PSConsole: credential expirations - all clear (nothing within $days days)" }
        $intro = if (@($act).Count) { "<p style='font-family:Segoe UI,Arial,sans-serif'>The following credentials are expired or expiring within $days days. Renew them before they lapse.</p>" }
                 else               { "<p style='font-family:Segoe UI,Arial,sans-serif'>No app secrets/certificates or Apple tokens are expired or expiring within $days days.</p>" }
        $html = $intro + (ConvertTo-ResultHtml -Title "Credential expirations (within $days days)" -Rows $act)
        $result.email = Send-PSCMail -To $recips -Subject $subj -BodyHtml $html
    }

    # ---- Teams channel ----
    if ($s.channels -contains 'teams') {
        if (@($act).Count) {
            $facts = @($act | Select-Object -First 15 | ForEach-Object {
                @{ title = "$($_.Type): $($_.Identity)"; value = "$($_.Status) - expires $($_.Expires)" }
            })
            $more  = if (@($act).Count -gt 15) { "`n(+$((@($act).Count) - 15) more - see PSConsole > Expirations.)" } else { '' }
            $title = "Credential expirations - $(@($act).Count) within $days days ($expired expired)"
            $result.teams = Send-TeamsMessage -Title $title -Text ("Renew these before they lapse.$more") -Facts $facts -Color 'Attention'
        } else {
            $result.teams = Send-TeamsMessage -Title 'Credential expirations - all clear' -Text "Nothing expired or expiring within $days days." -Color 'Good'
        }
    }
    $result
}

# --- VB365 backup-coverage alert ---------------------------------------------------------------------
# Unlike the expiration digest, this only sends WHEN there is a gap (licensed M365 users with no VB365
# backup) - a quiet check, not a periodic digest. Settings live under `vboCoverageAlert`:
#   { enabled:bool, recipients:['a@x'], exclude:['Display Name', ...] }  (exclude = known service accounts)
# Email only, via Send-PSCMail. Cadence is a daily Pode schedule in Start-PSConsole.
$script:VboCoverageAlertScript = '37-Get-Vbo365CoverageGap.ps1'

function Get-Vbo365CoverageAlertSettings {
    $def = [ordered]@{ enabled = $false; recipients = @(); exclude = @() }
    $cfg = Get-Store config
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'vboCoverageAlert') -and $cfg.vboCoverageAlert) {
        $s = $cfg.vboCoverageAlert
        if ($null -ne $s.enabled)    { $def.enabled    = [bool]$s.enabled }
        if ($null -ne $s.recipients) { $def.recipients = @(@($s.recipients) | Where-Object { $_ }) }
        if ($null -ne $s.exclude)    { $def.exclude    = @(@($s.exclude) | Where-Object { $_ }) }
    }
    $def
}

function Set-Vbo365CoverageAlertSettings {
    param([bool]$Enabled, [string[]]$Recipients, [string[]]$Exclude)
    $val = [ordered]@{
        enabled    = [bool]$Enabled
        recipients = @(@($Recipients) | Where-Object { $_ })
        exclude    = @(@($Exclude) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
    $cfg = Get-Store config
    $cfg | Add-Member -NotePropertyName vboCoverageAlert -NotePropertyValue $val -Force
    Set-Store config $cfg
    $val
}

# Run the coverage check; email the gap ONLY if non-empty (after excluding known service accounts).
# Returns @{ ran; total; gap; excluded; email } - never throws. -Force runs even when disabled (test button).
function Invoke-Vbo365CoverageAlert {
    param([switch]$Force)
    $s = Get-Vbo365CoverageAlertSettings
    if (-not $s.enabled -and -not $Force) { return @{ ran = $false; note = 'disabled' } }
    if (-not (Test-VeeamConfigured)) { return @{ ran = $false; note = 'veeam/vb365 not configured' } }

    $r = Invoke-ReportScriptFile -Name $script:VboCoverageAlertScript -TimeoutSec 210
    if (-not $r.ok) { Write-NotifyLog "vbo-coverage-alert: script error: $($r.error)"; return @{ ran = $false; error = $r.error } }
    $rows = @($r.data)
    $ex = @($s.exclude)
    # Drop the '(all licensed users are protected)' placeholder row and any excluded service accounts (case-insensitive).
    $gap = @($rows | Where-Object { $_.User -and ([string]$_.User) -notlike '(*' -and ($ex -notcontains [string]$_.User) })
    $result = @{ ran = $true; total = @($rows | Where-Object { $_.User -and ([string]$_.User) -notlike '(*' }).Count; gap = @($gap).Count; excluded = @($ex).Count }

    if (-not @($gap).Count) { $result.note = 'no coverage gap - no alert sent'; return $result }
    $recips = @($s.recipients) | Where-Object { $_ }
    if (-not $recips.Count) { $result.note = 'gap found but no recipients configured'; return $result }

    $subj  = "PSConsole: $(@($gap).Count) licensed M365 user(s) NOT backed up by Veeam"
    $intro = "<p style='font-family:Segoe UI,Arial,sans-serif'>These licensed, active users are not protected by any Veeam Backup for Microsoft 365 job. Add them to the appropriate backup job (or add known service accounts to the alert's exclusion list).</p>"
    $html  = $intro + (ConvertTo-ResultHtml -Title 'Licensed users with no VB365 backup coverage' -Rows $gap)
    $result.email = Send-PSCMail -To $recips -Subject $subj -BodyHtml $html
    $result
}

# --- Defender for Endpoint alert notification --------------------------------------------------------
# Pings only when a NEW active alert (of the configured severities) appears - a watermark (lastSeen alert time)
# stops it re-alerting on the same one. Settings under `defenderAlert`:
#   { enabled, recipients:[], channels:['email','teams'], minSeverity:['High','Medium'], lastSeen:iso }
function Get-DefenderAlertSettings {
    $def = [ordered]@{ enabled = $false; recipients = @(); channels = @('email'); minSeverity = @('High','Medium'); lastSeen = '' }
    $cfg = Get-Store config
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'defenderAlert') -and $cfg.defenderAlert) {
        $s = $cfg.defenderAlert
        if ($null -ne $s.enabled)     { $def.enabled     = [bool]$s.enabled }
        if ($null -ne $s.recipients)  { $def.recipients  = @(@($s.recipients) | Where-Object { $_ }) }
        if ($null -ne $s.channels)    { $def.channels     = @(@($s.channels) | Where-Object { $_ -in @('email','teams') }) }
        if ($null -ne $s.minSeverity) { $def.minSeverity = @(@($s.minSeverity) | Where-Object { $_ -in @('High','Medium','Low','Informational') }) }
        if ($s.lastSeen)              { $def.lastSeen     = [string]$s.lastSeen }
    }
    $def
}
function Save-DefenderAlertConfig {
    param([bool]$Enabled, [string[]]$Recipients, [string[]]$Channels, [string[]]$MinSeverity, [string]$LastSeen)
    $val = [ordered]@{
        enabled     = [bool]$Enabled
        recipients  = @(@($Recipients) | Where-Object { $_ })
        channels    = @(@($Channels) | Where-Object { $_ -in @('email','teams') })
        minSeverity = @(@($MinSeverity) | Where-Object { $_ -in @('High','Medium','Low','Informational') })
        lastSeen    = [string]$LastSeen
    }
    if (-not $val.minSeverity.Count) { $val.minSeverity = @('High','Medium') }
    $cfg = Get-Store config
    $cfg | Add-Member -NotePropertyName defenderAlert -NotePropertyValue $val -Force
    Set-Store config $cfg
    $val
}
function Set-DefenderAlertSettings {
    param([bool]$Enabled, [string[]]$Recipients, [string[]]$Channels, [string[]]$MinSeverity)
    $cur = Get-DefenderAlertSettings
    $ls  = [string]$cur.lastSeen
    # Starting fresh: watermark = now, so enabling never blasts pre-existing alerts - only new ones after this.
    if ($Enabled -and -not $ls) { $ls = (Get-Date).ToUniversalTime().ToString('o') }
    Save-DefenderAlertConfig -Enabled $Enabled -Recipients $Recipients -Channels $Channels -MinSeverity $MinSeverity -LastSeen $ls
}

# Check for new active alerts and notify. -Force ignores the watermark + runs even when disabled (test button):
# it shows ALL current active alerts of the configured severities without advancing the watermark.
function Invoke-DefenderAlert {
    param([switch]$Force)
    $s = Get-DefenderAlertSettings
    if (-not $s.enabled -and -not $Force) { return @{ ran = $false; note = 'disabled' } }
    if (-not (Test-DefenderConfigured))   { return @{ ran = $false; note = 'defender not configured' } }

    $res = Get-DefenderAlerts -Days 14 -ActiveOnly -Severity $s.minSeverity
    if (-not $res.ok) { Write-NotifyLog "defender-alert: $($res.error)"; return @{ ran = $false; error = $res.error } }
    $active = @($res.alerts)

    $wm = $null; if ($s.lastSeen) { try { $wm = [datetimeoffset]$s.lastSeen } catch {} }
    $new = if ($Force -or -not $wm) { $active } else { @($active | Where-Object { try { [datetimeoffset]$_.CreatedRaw -gt $wm } catch { $true } }) }

    # Advance the watermark to the newest active alert (scheduled runs only), so the next run won't repeat it.
    if (-not $Force -and $active.Count) {
        $maxIso = (@($active) | Sort-Object { try { [datetimeoffset]$_.CreatedRaw } catch { [datetimeoffset]::MinValue } } -Descending | Select-Object -First 1).CreatedRaw
        if ($maxIso) { Save-DefenderAlertConfig -Enabled $s.enabled -Recipients $s.recipients -Channels $s.channels -MinSeverity $s.minSeverity -LastSeen ([string]$maxIso) | Out-Null }
    }

    $result = @{ ran = $true; activeTotal = $active.Count; new = @($new).Count }
    if (-not @($new).Count) { $result.note = 'no new alerts'; return $result }

    $sevSummary = (@($new | Group-Object Severity | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', ')
    if ($s.channels -contains 'email') {
        $recips = @($s.recipients) | Where-Object { $_ }
        if ($recips.Count) {
            $subj = "PSConsole: $(@($new).Count) new Defender alert(s) - $sevSummary"
            $html = "<p style='font-family:Segoe UI,Arial,sans-serif'>New active Microsoft Defender for Endpoint alerts. Review them in the Defender portal.</p>" +
                    (ConvertTo-ResultHtml -Title 'New Defender alerts' -Rows @($new | Select-Object Severity, Status, Title, Category, Device, Created))
            $result.email = Send-PSCMail -To $recips -Subject $subj -BodyHtml $html
        } else { $result.note = 'new alerts but no recipients configured' }
    }
    if ($s.channels -contains 'teams') {
        $facts = @($new | Select-Object -First 15 | ForEach-Object { @{ title = "$($_.Severity) - $($_.Device)"; value = [string]$_.Title } })
        $result.teams = Send-TeamsMessage -Title "$(@($new).Count) new Defender alert(s) - $sevSummary" -Text 'Active alerts in Microsoft Defender for Endpoint. Review in the portal.' -Facts $facts -Color 'Attention'
    }
    $result
}
