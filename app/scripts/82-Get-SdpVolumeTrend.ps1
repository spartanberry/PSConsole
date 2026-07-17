<#
.SYNOPSIS
    ServiceDesk Plus request volume by month - created vs. completed - for the last N months.
.DESCRIPTION
    Counts requests by the month of their creation and, separately, by the month they were completed,
    then aligns them per month. Use it to see intake vs. throughput trends. -Months defaults to 6
    (clamped 1-36). The current month is partial. Read-only SQL.
.CATEGORY Service Desk
.ROLE Admin
.RUNEXAMPLE -Months 12
#>
[CmdletBinding()]
param(
    [int]$Months = 6
)

. (Join-Path $PSScriptRoot '..\lib\Sdp.ps1')
if (-not (Test-SdpConfigured)) { Write-Error 'ServiceDesk Plus add-on is not configured (run sdp-setup\Set-SdpConfig.ps1 on this host).'; return }

if ($Months -lt 1)  { $Months = 1 }
if ($Months -gt 36) { $Months = 36 }

$createdSql = @"
DECLARE @from BIGINT = DATEDIFF_BIG(MILLISECOND, '19700101', DATEADD(MONTH, -@m, GETUTCDATE()));
SELECT FORMAT(DATEADD(SECOND, CREATEDTIME/1000, '19700101'), 'yyyy-MM') AS Mon, COUNT(*) AS Cnt
FROM WorkOrder WHERE CREATEDTIME >= @from
GROUP BY FORMAT(DATEADD(SECOND, CREATEDTIME/1000, '19700101'), 'yyyy-MM')
"@
$completedSql = @"
DECLARE @from BIGINT = DATEDIFF_BIG(MILLISECOND, '19700101', DATEADD(MONTH, -@m, GETUTCDATE()));
SELECT FORMAT(DATEADD(SECOND, COMPLETEDTIME/1000, '19700101'), 'yyyy-MM') AS Mon, COUNT(*) AS Cnt
FROM WorkOrder WHERE COMPLETEDTIME >= @from
GROUP BY FORMAT(DATEADD(SECOND, COMPLETEDTIME/1000, '19700101'), 'yyyy-MM')
"@

$cRes = Invoke-SdpQuery -Sql $createdSql   -Parameters @{ m = $Months } -TimeoutSec 60
if (-not $cRes.ok) { Write-Error "Service Desk query failed: $($cRes.error)"; return }
$dRes = Invoke-SdpQuery -Sql $completedSql -Parameters @{ m = $Months } -TimeoutSec 60
if (-not $dRes.ok) { Write-Error "Service Desk query failed: $($dRes.error)"; return }

$created   = @{}; foreach ($r in $cRes.rows) { if ($r.Mon) { $created[[string]$r.Mon]   = [int]$r.Cnt } }
$completed = @{}; foreach ($r in $dRes.rows) { if ($r.Mon) { $completed[[string]$r.Mon] = [int]$r.Cnt } }

$monthSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($k in $created.Keys)   { [void]$monthSet.Add($k) }
foreach ($k in $completed.Keys) { [void]$monthSet.Add($k) }
if (-not $monthSet.Count) { [pscustomobject]@{ Month='(no data)'; Created=0; Completed=0 }; return }

foreach ($m in ($monthSet | Sort-Object)) {
    [pscustomobject]@{
        Month     = $m
        Created   = $(if ($created.ContainsKey($m))   { $created[$m] }   else { 0 })
        Completed = $(if ($completed.ContainsKey($m)) { $completed[$m] } else { 0 })
    }
}
