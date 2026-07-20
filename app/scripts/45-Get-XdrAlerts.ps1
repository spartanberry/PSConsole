<#
.SYNOPSIS Microsoft Defender XDR / cloud alerts (Office 365 email, Identity, DLP) from the Graph Security API - separate from the endpoint alert feed. Operational noise is filtered by a config suppression list; DLP is bucketed on its own.
.DESCRIPTION Unified alerts (alerts_v2) for the last N days, newest first, tagged by Source and Bucket (security vs
    dlp). By default the suppressed operational noise (user junk votes, quarantine-release requests, admin
    investigations, Tenant Allow/Block List housekeeping) is hidden - pass -IncludeSuppressed to see it and tune the
    list in Config. Read-only via the shared Graph app (needs SecurityAlert.Read.All).
.CATEGORY Defender
.ROLE Admin
.RUNEXAMPLE -Days 30
.RUNEXAMPLE -Days 30 -IncludeSuppressed
#>
[CmdletBinding()]
param([int]$Days = 30, [switch]$IncludeSuppressed)

. (Join-Path $PSScriptRoot '..\lib\Store.ps1')   # Xdr.ps1 reads the suppress/escalate lists via Get-Store
. (Join-Path $PSScriptRoot '..\lib\Graph.ps1')
. (Join-Path $PSScriptRoot '..\lib\Xdr.ps1')

$r = Get-XdrAlerts -Days $Days
if (-not $r.ok) { Write-Error $r.error; return }
$rows = @($r.alerts)
if (-not $IncludeSuppressed) { $rows = @($rows | Where-Object { -not $_.Suppressed }) }
if (-not $rows.Count) { [pscustomobject]@{ Source = '(no alerts in window)'; Severity = ''; Status = ''; Bucket = ''; Title = ''; Created = '' }; return }

if ($IncludeSuppressed) {
    $rows | Select-Object Source, Severity, Status, Bucket, Suppressed, Title, Created
} else {
    $rows | Select-Object Source, Severity, Status, Bucket, Title, Created
}
