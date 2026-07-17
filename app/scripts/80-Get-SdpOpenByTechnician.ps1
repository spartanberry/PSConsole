<#
.SYNOPSIS
    Open ServiceDesk Plus requests grouped by technician, with 7-day and 30-day backlog counts.
.DESCRIPTION
    "Open" = any request whose status is pending (Open / In Progress / Assigned / On-hold / Waiting) per
    StatusDefinition.ISPENDING - not Closed/Resolved/Cancelled. Read-only SQL against the SDP backend.
.CATEGORY Service Desk
.ROLE Admin
.RUNEXAMPLE (no parameters)
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\lib\Sdp.ps1')
if (-not (Test-SdpConfigured)) { Write-Error 'ServiceDesk Plus add-on is not configured (run sdp-setup\Set-SdpConfig.ps1 on this host).'; return }

$sql = @"
DECLARE @now BIGINT = DATEDIFF_BIG(MILLISECOND, '19700101', GETUTCDATE());
SELECT
   ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(au.FIRST_NAME,'') + ' ' + ISNULL(au.LAST_NAME,''))),''),'(unassigned)') AS Technician,
   COUNT(*) AS [Open],
   SUM(CASE WHEN (@now - wo.CREATEDTIME) >= 604800000  THEN 1 ELSE 0 END) AS [Over 7d],
   SUM(CASE WHEN (@now - wo.CREATEDTIME) >= 2592000000 THEN 1 ELSE 0 END) AS [Over 30d]
FROM WorkOrderStates ws
JOIN WorkOrder wo        ON wo.WORKORDERID = ws.WORKORDERID
JOIN StatusDefinition sd ON sd.STATUSID    = ws.STATUSID
LEFT JOIN AaaUser au     ON au.USER_ID      = ws.OWNERID
WHERE sd.ISPENDING = 1
GROUP BY au.FIRST_NAME, au.LAST_NAME
ORDER BY [Open] DESC
"@

$res = Invoke-SdpQuery -Sql $sql -TimeoutSec 60
if (-not $res.ok) { Write-Error "Service Desk query failed: $($res.error)"; return }
if (-not @($res.rows).Count) { [pscustomobject]@{ Technician='(no open requests)'; Open=0; 'Over 7d'=0; 'Over 30d'=0 }; return }
$res.rows
