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
