<#
.SYNOPSIS Microsoft Defender for Endpoint alerts. Defaults to the actionable set (active High/Medium).
.DESCRIPTION Read-only pull of /api/alerts. By default shows only New/InProgress High and Medium alerts in the
    window (the "what needs attention" view) - pass -All to see every alert regardless of severity/status.
    Needs the WindowsDefenderATP Alert.Read.All app permission (alongside Machine.Read.All).
.CATEGORY Defender
.ROLE Admin
.RUNEXAMPLE -Days 30
.RUNEXAMPLE -Days 90 -All
#>
[CmdletBinding()]
param([int]$Days = 30, [switch]$All)

. (Join-Path $PSScriptRoot '..\lib\Graph.ps1')
. (Join-Path $PSScriptRoot '..\lib\Defender.ps1')
if (-not (Test-DefenderConfigured)) { Write-Error 'Defender add-on is not configured (data\defender.config.json).'; return }
if ($Days -lt 1) { $Days = 30 }

$res = if ($All) { Get-DefenderAlerts -Days $Days } else { Get-DefenderAlerts -Days $Days -ActiveOnly -Severity @('High','Medium') }
if (-not $res.ok) { Write-Error "Defender alerts query failed: $($res.error)"; return }

$alerts = @($res.alerts)
if (-not $alerts.Count) {
    $msg = if ($All) { "(no alerts in the last $Days days)" } else { "(no active High/Medium alerts in the last $Days days)" }
    [pscustomobject]@{ Severity = ''; Status = ''; Title = $msg; Category = ''; Device = ''; Created = '' }
    return
}
$alerts | Select-Object Severity, Status, Title, Category, Device, Created
