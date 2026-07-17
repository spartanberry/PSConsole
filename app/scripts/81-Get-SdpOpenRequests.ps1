<#
.SYNOPSIS
    Open ServiceDesk Plus requests, oldest first, with age in days (the "what's aging" view).
.DESCRIPTION
    Lists every pending request (StatusDefinition.ISPENDING=1) with its technician, requester, status,
    priority, creation date and age. Optional -MinAgeDays filters to only requests older than N days
    (e.g. -MinAgeDays 30 to see the stale backlog). Read-only SQL.
.CATEGORY Service Desk
.ROLE Admin
.RUNEXAMPLE -MinAgeDays 30
#>
[CmdletBinding()]
param(
    [int]$MinAgeDays = 0
)

. (Join-Path $PSScriptRoot '..\lib\Sdp.ps1')
if (-not (Test-SdpConfigured)) { Write-Error 'ServiceDesk Plus add-on is not configured (run sdp-setup\Set-SdpConfig.ps1 on this host).'; return }

if ($MinAgeDays -lt 0) { $MinAgeDays = 0 }
$minMs = [int64]$MinAgeDays * 86400000

$sql = @"
DECLARE @now BIGINT = DATEDIFF_BIG(MILLISECOND, '19700101', GETUTCDATE());
SELECT
   wo.WORKORDERID AS ID,
   wo.TITLE       AS Subject,
   sd.STATUSNAME  AS Status,
   ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(ta.FIRST_NAME,'') + ' ' + ISNULL(ta.LAST_NAME,''))),''),'(unassigned)') AS Technician,
   LTRIM(RTRIM(ISNULL(ra.FIRST_NAME,'') + ' ' + ISNULL(ra.LAST_NAME,''))) AS Requester,
   ISNULL(pd.PRIORITYNAME,'') AS Priority,
   wo.CREATEDTIME AS CreatedRaw,
   CAST((@now - wo.CREATEDTIME) / 86400000 AS INT) AS AgeDays
FROM WorkOrderStates ws
JOIN WorkOrder wo         ON wo.WORKORDERID = ws.WORKORDERID
JOIN StatusDefinition sd  ON sd.STATUSID    = ws.STATUSID
LEFT JOIN AaaUser ta      ON ta.USER_ID     = ws.OWNERID
LEFT JOIN AaaUser ra      ON ra.USER_ID     = wo.REQUESTERID
LEFT JOIN PriorityDefinition pd ON pd.PRIORITYID = ws.PRIORITYID
WHERE sd.ISPENDING = 1 AND (@now - wo.CREATEDTIME) >= @minMs
ORDER BY wo.CREATEDTIME ASC
"@

$res = Invoke-SdpQuery -Sql $sql -Parameters @{ minMs = $minMs } -TimeoutSec 60
if (-not $res.ok) { Write-Error "Service Desk query failed: $($res.error)"; return }
if (-not @($res.rows).Count) { [pscustomobject]@{ ID=''; Subject="(no open requests$(if($MinAgeDays){" older than $MinAgeDays days"}))"; Status=''; Technician=''; Requester=''; Priority=''; Created=''; AgeDays='' }; return }

foreach ($row in $res.rows) {
    [pscustomobject]@{
        ID         = $row.ID
        Subject    = $row.Subject
        Status     = $row.Status
        Technician = $row.Technician
        Requester  = $row.Requester
        Priority   = $row.Priority
        Created    = Format-SdpDate $row.CreatedRaw
        AgeDays    = $row.AgeDays
    }
}
