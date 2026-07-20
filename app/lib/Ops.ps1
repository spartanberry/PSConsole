# Ops.ps1 - the Operations dashboard: a "living checklist" for the morning-open / end-of-day-close glance.
# Each tile is computed from an existing add-on (best-effort, wrapped so one slow/unconfigured source never
# breaks the snapshot). The snapshot is CACHED to data\ops-snapshot.json (the dashboard renders it instantly);
# a schedule + a Refresh button recompute it, since the underlying checks are slow remote/Graph calls.
#
# status values: 'crit' (red - act now), 'warn' (yellow - soon), 'ok' (green - all clear), 'info' (neutral),
#                'na' (gray - not configured / check failed).

function Get-OpsSnapshotPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'ops-snapshot.json' }
    else { Join-Path $PSScriptRoot '..\..\data\ops-snapshot.json' }
}
function New-OpsTile {
    param([string]$Area, [string]$Status, [string]$Headline, [string]$Detail = '', [string]$Href = '')
    [pscustomobject]@{ area = $Area; status = $Status; headline = $Headline; detail = $Detail; href = $Href }
}

# --- individual tiles (each returns one tile; own try/catch so a failure degrades to 'na', never throws) ---

function Get-OpsTileBackups {
    if (-not (Test-VeeamConfigured)) { return New-OpsTile 'Backups (last 24h)' 'na' 'Veeam not configured' '' '/admin/veeam' }
    try {
        $sessions = @()
        $sr = Get-VeeamSessions -Days 1;                 if ($sr.ok)  { $sessions += @($sr.sessions) }
        $vbo = Get-VboSessions -Days 1 -EnabledOnly;     if ($vbo.ok) { $sessions += @($vbo.sessions) }
        $failed = @($sessions | Where-Object { "$($_.Result)" -eq 'Failed'  }).Count
        $warned = @($sessions | Where-Object { "$($_.Result)" -eq 'Warning' }).Count
        $total  = @($sessions).Count
        if ($failed) { return New-OpsTile 'Backups (last 24h)' 'crit' "$failed failed, $warned warning" "$total runs" '/admin/veeam' }
        if ($warned) { return New-OpsTile 'Backups (last 24h)' 'warn' "$warned finished with warnings" "$total runs, 0 failed" '/admin/veeam' }
        if ($total)  { return New-OpsTile 'Backups (last 24h)' 'ok'  'All backups succeeded' "$total runs" '/admin/veeam' }
        return New-OpsTile 'Backups (last 24h)' 'info' 'No runs in the last 24h' '' '/admin/veeam'
    } catch { return New-OpsTile 'Backups (last 24h)' 'na' 'Check failed' ([string]$_.Exception.Message) '/admin/veeam' }
}

function Get-OpsTileRemediation {
    if (-not (Test-SharePointConfigured)) { return New-OpsTile 'Backup remediation' 'na' 'SharePoint not configured' '' '/admin/veeam/remediation' }
    try {
        $n = @(Get-SPRemediationRows).Count
        if ($n) { return New-OpsTile 'Backup remediation' 'warn' "$n open item(s)" 'Failed backups awaiting sign-off' '/admin/veeam/remediation' }
        return New-OpsTile 'Backup remediation' 'ok' 'Nothing open' '' '/admin/veeam/remediation'
    } catch { return New-OpsTile 'Backup remediation' 'na' 'Check failed' ([string]$_.Exception.Message) '/admin/veeam/remediation' }
}

function Get-OpsTileSecurity {
    $href = '/?script=93-Get-DefenderAlerts.ps1'
    if (-not (Test-DefenderConfigured)) { return New-OpsTile 'Security alerts' 'na' 'Defender not configured' '' '' }
    try {
        $res = Get-DefenderAlerts -Days 7 -ActiveOnly -Severity @('High','Medium')
        if (-not $res.ok) { return New-OpsTile 'Security alerts' 'na' 'Check failed' ([string]$res.error) $href }
        $a = @($res.alerts); $high = @($a | Where-Object { $_.Severity -eq 'High' }).Count; $med = @($a | Where-Object { $_.Severity -eq 'Medium' }).Count
        if ($high) { return New-OpsTile 'Security alerts' 'crit' "$high High, $med Medium active" 'Defender for Endpoint' $href }
        if ($med)  { return New-OpsTile 'Security alerts' 'warn' "$med Medium active" 'Defender for Endpoint' $href }
        return New-OpsTile 'Security alerts' 'ok' 'No active High/Medium alerts' '' $href
    } catch { return New-OpsTile 'Security alerts' 'na' 'Check failed' ([string]$_.Exception.Message) $href }
}

function Get-OpsTileExpirations {
    $href = '/?script=40-Get-ExpiringCredentials.ps1'
    try {
        $r = Invoke-ReportScriptFile -Name '40-Get-ExpiringCredentials.ps1' -Parameters @{ Days = 14 } -TimeoutSec 120
        if (-not $r.ok) { return New-OpsTile 'Expirations (14d)' 'na' 'Check failed' ([string]$r.error) $href }
        $rows = @($r.data)
        $exp  = @($rows | Where-Object { "$($_.Status)" -eq 'EXPIRED' }).Count
        $soon = @($rows | Where-Object { "$($_.Status)" -like 'Expiring*' }).Count
        if ($exp)  { return New-OpsTile 'Expirations (14d)' 'crit' "$exp expired, $soon expiring" 'App secrets / certs / Apple tokens' $href }
        if ($soon) { return New-OpsTile 'Expirations (14d)' 'warn' "$soon expiring within 14 days" 'App secrets / certs / Apple tokens' $href }
        return New-OpsTile 'Expirations (14d)' 'ok' 'Nothing expiring soon' '' $href
    } catch { return New-OpsTile 'Expirations (14d)' 'na' 'Check failed' ([string]$_.Exception.Message) $href }
}

function Get-OpsTileHelpdesk {
    $href = '/?script=81-Get-SdpOpenRequests.ps1'
    if (-not (Test-SdpConfigured)) { return New-OpsTile 'Helpdesk queue' 'na' 'ServiceDesk not configured' '' '' }
    try {
        # Optionally drop tickets owned by specific technicians. Names live in config (data\, not source) as
        # opsHelpdeskExcludeTechs = @('First Last', ...) - matched on the SDP owner's full name; quotes escaped.
        $exclTechs  = @((Get-Store config).opsHelpdeskExcludeTechs) | Where-Object { $_ }
        $exclClause = ''
        if ($exclTechs.Count) {
            $inList = ($exclTechs | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
            $exclClause = "  AND LTRIM(RTRIM(ISNULL(au.FIRST_NAME,'') + ' ' + ISNULL(au.LAST_NAME,''))) NOT IN ($inList)"
        }
        $sql = @"
DECLARE @now BIGINT = DATEDIFF_BIG(MILLISECOND, '19700101', GETUTCDATE());
SELECT COUNT(*) AS OpenCnt,
       SUM(CASE WHEN (@now - wo.CREATEDTIME) >= 2592000000 THEN 1 ELSE 0 END) AS Aged
FROM WorkOrderStates ws
JOIN WorkOrder wo        ON wo.WORKORDERID = ws.WORKORDERID
JOIN StatusDefinition sd ON sd.STATUSID    = ws.STATUSID
LEFT JOIN AaaUser au     ON au.USER_ID      = ws.OWNERID
WHERE sd.ISPENDING = 1
$exclClause
"@
        $res = Invoke-SdpQuery -Sql $sql -TimeoutSec 30
        if (-not $res.ok) { return New-OpsTile 'Helpdesk queue' 'na' 'Check failed' ([string]$res.error) $href }
        $row = @($res.rows)[0]; $open = [int]$row.OpenCnt; $aged = [int]$row.Aged
        $status = if ($aged -gt 0) { 'warn' } else { 'info' }
        $detail = 'ServiceDesk Plus'
        if ($exclTechs.Count) { $detail += ' - excl. ' + ($exclTechs -join ', ') }
        return New-OpsTile 'Helpdesk queue' $status "$open open, $aged aged 30+ days" $detail $href
    } catch { return New-OpsTile 'Helpdesk queue' 'na' 'Check failed' ([string]$_.Exception.Message) $href }
}

# Microsoft Defender XDR / cloud alerts (Office 365 email, Identity, DLP) via Graph Security - SEPARATE from the
# endpoint 'Security alerts' tile. Operational noise is suppressed and DLP is bucketed on its own (never drives the
# status), so only genuine cloud/identity signal escalates. See Xdr.ps1.
function Get-OpsTileXdr {
    $href = '/?script=45-Get-XdrAlerts.ps1'
    if (-not (Test-XdrConfigured)) { return New-OpsTile 'Cloud alerts' 'na' 'Graph not configured' '' '' }
    try {
        $r = Get-XdrAlerts -Days 30
        if (-not $r.ok) { return New-OpsTile 'Cloud alerts' 'na' 'Check failed' ([string]$r.error) $href }
        # Only these sources ESCALATE the tile (config xdrAlerts.escalateSources; default Identity = active AD
        # attack). Email (auto-remediated by MDO) and DLP (near-always FP) are shown as "to review" counts only.
        $esc  = @((Get-Store config).xdrAlerts.escalateSources); if (-not @($esc).Count) { $esc = @('Identity') }
        $open = @('new','active','inProgress')
        $vis  = @($r.alerts | Where-Object { -not $_.Suppressed -and ($open -contains "$($_.Status)") })
        $escOpen = @($vis | Where-Object { $esc -contains "$($_.Source)" })
        $review  = @($vis | Where-Object { $esc -notcontains "$($_.Source)" })
        $dlpN    = @($review | Where-Object { $_.Bucket -eq 'dlp' }).Count
        $emailN  = @($review).Count - $dlpN
        $bits = @(); if ($emailN) { $bits += "$emailN email" }; if ($dlpN) { $bits += "$dlpN DLP" }
        $detail = if ($bits.Count) { 'to review: ' + ($bits -join ', ') } else { 'Office 365 / Identity / DLP' }
        $high = @($escOpen | Where-Object { "$($_.Severity)" -eq 'high' }).Count
        $med  = @($escOpen | Where-Object { "$($_.Severity)" -eq 'medium' }).Count
        if ($high) { return New-OpsTile 'Cloud alerts' 'crit' "$high high (identity/cloud)" $detail $href }
        if ($med)  { return New-OpsTile 'Cloud alerts' 'warn' "$($escOpen.Count) identity/cloud alert(s)" $detail $href }
        if ($escOpen.Count) { return New-OpsTile 'Cloud alerts' 'info' "$($escOpen.Count) identity/cloud alert(s)" $detail $href }
        if ($review.Count)  { return New-OpsTile 'Cloud alerts' 'info' 'Email/DLP to review' $detail $href }
        return New-OpsTile 'Cloud alerts' 'ok' 'No active cloud alerts' 'Office 365 / Identity / DLP' $href
    } catch { return New-OpsTile 'Cloud alerts' 'na' 'Check failed' ([string]$_.Exception.Message) $href }
}

# UniFi network infrastructure: switches / APs / gateways that are offline (clients are deliberately ignored).
# Cameras are NOT covered here - they live in UniFi Protect (a separate API not wired into this add-on).
function Get-OpsTileUnifiDevices {
    $href = '/?script=30-Get-UnifiDevices.ps1'
    if (-not (Test-UnifiConfigured)) { return New-OpsTile 'Network devices' 'na' 'UniFi not configured' '' '' }
    try {
        $r = Invoke-ReportScriptFile -Name '30-Get-UnifiDevices.ps1' -TimeoutSec 120
        if (-not $r.ok) { return New-OpsTile 'Network devices' 'na' 'Check failed' ([string]$r.error) $href }
        $rows = @($r.data)
        $good = @($rows | Where-Object { "$($_.Site)" -ne '(error)' })
        if (-not $good.Count) { return New-OpsTile 'Network devices' 'na' 'Could not query UniFi' '' $href }
        $down = @($good | Where-Object { "$($_.State)".ToUpper() -ne 'ONLINE' })
        if ($down.Count) {
            $names = (@($down | Select-Object -First 6 | ForEach-Object { [string]$_.Name }) -join ', ')
            if ($down.Count -gt 6) { $names += ", +$($down.Count - 6) more" }
            return New-OpsTile 'Network devices' 'crit' "$($down.Count) offline" $names $href
        }
        return New-OpsTile 'Network devices' 'ok' "All $($good.Count) online" 'Switches / APs / gateways' $href
    } catch { return New-OpsTile 'Network devices' 'na' 'Check failed' ([string]$_.Exception.Message) $href }
}

# WAN / internet uplink health per site (UniFi WAN + WWW subsystems). error -> crit, warning -> warn.
function Get-OpsTileWan {
    $href = '/?script=32-Get-UnifiHealth.ps1'
    if (-not (Test-UnifiConfigured)) { return New-OpsTile 'WAN / Internet' 'na' 'UniFi not configured' '' '' }
    try {
        $r = Invoke-ReportScriptFile -Name '32-Get-UnifiHealth.ps1' -TimeoutSec 120
        if (-not $r.ok) { return New-OpsTile 'WAN / Internet' 'na' 'Check failed' ([string]$r.error) $href }
        $rows = @($r.data | Where-Object { "$($_.Site)" -ne '(error)' -and @('WAN','WWW') -contains "$($_.Subsystem)" })
        if (-not $rows.Count) { return New-OpsTile 'WAN / Internet' 'na' 'No WAN data' '' $href }
        $bad    = @($rows | Where-Object { "$($_.Status)".ToLower() -eq 'error' })
        $degr   = @($rows | Where-Object { $s = "$($_.Status)".ToLower(); $s -and $s -ne 'ok' -and $s -ne 'error' })
        $sites  = @($rows | Where-Object { "$($_.Subsystem)" -eq 'WAN' }).Count
        if ($bad.Count)  { $w = (@($bad  | ForEach-Object { "$($_.Console) $($_.Subsystem)" }) -join ', '); return New-OpsTile 'WAN / Internet' 'crit' "$($bad.Count) link(s) down" $w $href }
        if ($degr.Count) { $w = (@($degr | ForEach-Object { "$($_.Console) $($_.Subsystem)" }) -join ', '); return New-OpsTile 'WAN / Internet' 'warn' "$($degr.Count) link(s) degraded" $w $href }
        return New-OpsTile 'WAN / Internet' 'ok' "All $sites site(s) up" 'WAN + internet uplinks' $href
    } catch { return New-OpsTile 'WAN / Internet' 'na' 'Check failed' ([string]$_.Exception.Message) $href }
}

# UniFi Protect cameras: any camera not CONNECTED. Degrades to 'na' until the Protect Integration API is
# enabled on the console(s) (the fetch reports UNREACHABLE, which we surface as "not enabled" - never a false down).
function Get-OpsTileCameras {
    $href = '/?script=44-Get-UnifiCameras.ps1'
    if (-not (Test-UnifiConfigured)) { return New-OpsTile 'Cameras' 'na' 'UniFi not configured' '' '' }
    try {
        $r = Invoke-ReportScriptFile -Name '44-Get-UnifiCameras.ps1' -TimeoutSec 120
        if (-not $r.ok) { return New-OpsTile 'Cameras' 'na' 'Check failed' ([string]$r.error) $href }
        $rows = @($r.data)
        $cams = @($rows | Where-Object { "$($_.State)" -and "$($_.State)" -ne 'UNREACHABLE' -and "$($_.Camera)" -ne '(no cameras)' })
        $unreach = @($rows | Where-Object { "$($_.State)" -eq 'UNREACHABLE' })
        if (-not $cams.Count) {
            if ($unreach.Count) { return New-OpsTile 'Cameras' 'na' 'Protect API not enabled' 'Enable the UniFi Protect Integration API' $href }
            return New-OpsTile 'Cameras' 'na' 'No cameras found' '' $href
        }
        $down = @($cams | Where-Object { "$($_.State)".ToUpper() -ne 'CONNECTED' })
        if ($down.Count) {
            $names = (@($down | Select-Object -First 6 | ForEach-Object { [string]$_.Camera }) -join ', ')
            if ($down.Count -gt 6) { $names += ", +$($down.Count - 6) more" }
            return New-OpsTile 'Cameras' 'crit' "$($down.Count) offline" $names $href
        }
        return New-OpsTile 'Cameras' 'ok' "All $($cams.Count) online" 'UniFi Protect' $href
    } catch { return New-OpsTile 'Cameras' 'na' 'Check failed' ([string]$_.Exception.Message) $href }
}

# Hyper-V failover-cluster hosts: any node not Up (Down -> crit, Paused/maintenance -> warn).
function Get-OpsTileHyperVNodes {
    $href = '/?script=61-Get-HyperVClusterNodes.ps1'
    if (-not (Test-HyperVConfigured)) { return New-OpsTile 'Hyper-V nodes' 'na' 'Hyper-V not configured' '' '' }
    try {
        $r = Invoke-ReportScriptFile -Name '61-Get-HyperVClusterNodes.ps1' -TimeoutSec 120
        if (-not $r.ok) { return New-OpsTile 'Hyper-V nodes' 'na' 'Check failed' ([string]$r.error) $href }
        $nodes = @($r.data)
        if (-not $nodes.Count) { return New-OpsTile 'Hyper-V nodes' 'na' 'No cluster data' '' $href }
        $down   = @($nodes | Where-Object { "$($_.State)" -eq 'Down' })
        $paused = @($nodes | Where-Object { "$($_.State)" -eq 'Paused' })
        $up     = @($nodes | Where-Object { "$($_.State)" -eq 'Up' }).Count
        if ($down.Count)   { $w = (@($down   | ForEach-Object { [string]$_.Node }) -join ', '); return New-OpsTile 'Hyper-V nodes' 'crit' "$($down.Count) node(s) down" $w $href }
        if ($paused.Count) { $w = (@($paused | ForEach-Object { [string]$_.Node }) -join ', '); return New-OpsTile 'Hyper-V nodes' 'warn' "$($paused.Count) node(s) paused" $w $href }
        return New-OpsTile 'Hyper-V nodes' 'ok' "All $up node(s) up" 'Failover cluster' $href
    } catch { return New-OpsTile 'Hyper-V nodes' 'na' 'Check failed' ([string]$_.Exception.Message) $href }
}

# Hyper-V clustered VMs: any VM role in a real failure state (Failed/PartialOnline/Pending). An intentionally
# Offline VM is NOT flagged as an incident - only noted in the ok detail - so the tile stays quiet unless a VM broke.
function Get-OpsTileHyperVVms {
    $href = '/?script=62-Get-HyperVClusterRoles.ps1'
    if (-not (Test-HyperVConfigured)) { return New-OpsTile 'Hyper-V VMs' 'na' 'Hyper-V not configured' '' '' }
    try {
        $r = Invoke-ReportScriptFile -Name '62-Get-HyperVClusterRoles.ps1' -TimeoutSec 120
        if (-not $r.ok) { return New-OpsTile 'Hyper-V VMs' 'na' 'Check failed' ([string]$r.error) $href }
        $vms = @($r.data | Where-Object { "$($_.Type)" -eq 'VirtualMachine' })
        if (-not $vms.Count) { return New-OpsTile 'Hyper-V VMs' 'na' 'No VM roles' '' $href }
        $failed = @($vms | Where-Object { @('Failed','PartialOnline','Pending') -contains "$($_.State)" })
        $off    = @($vms | Where-Object { "$($_.State)" -eq 'Offline' })
        $online = @($vms | Where-Object { "$($_.State)" -eq 'Online' }).Count
        if ($failed.Count) {
            $w = (@($failed | Select-Object -First 5 | ForEach-Object { "$($_.Role)=$($_.State)" }) -join ', ')
            return New-OpsTile 'Hyper-V VMs' 'crit' "$($failed.Count) VM(s) failed" $w $href
        }
        $detail = if ($off.Count) { "$($off.Count) intentionally off" } else { 'Clustered roles' }
        return New-OpsTile 'Hyper-V VMs' 'ok' "$online VM(s) online" $detail $href
    } catch { return New-OpsTile 'Hyper-V VMs' 'na' 'Check failed' ([string]$_.Exception.Message) $href }
}

# Compute the whole snapshot (slow - runs all the remote checks). Order = importance.
function Get-OpsSnapshot {
    $tiles = New-Object System.Collections.Generic.List[object]
    $tiles.Add((Get-OpsTileBackups))
    $tiles.Add((Get-OpsTileRemediation))
    $tiles.Add((Get-OpsTileSecurity))
    $tiles.Add((Get-OpsTileXdr))
    $tiles.Add((Get-OpsTileWan))
    $tiles.Add((Get-OpsTileUnifiDevices))
    $tiles.Add((Get-OpsTileCameras))
    $tiles.Add((Get-OpsTileHyperVNodes))
    $tiles.Add((Get-OpsTileHyperVVms))
    $tiles.Add((Get-OpsTileExpirations))
    $tiles.Add((Get-OpsTileHelpdesk))
    @{ generatedAt = (Get-Date).ToString('o'); tiles = $tiles.ToArray() }
}

function Save-OpsSnapshot {
    param($Snapshot)
    try { ([pscustomobject]$Snapshot) | ConvertTo-Json -Depth 6 | Set-Content (Get-OpsSnapshotPath) -Encoding UTF8; $true } catch { $false }
}
# Read the cached snapshot (fast). Returns $null if none yet.
function Get-CachedOpsSnapshot {
    $p = Get-OpsSnapshotPath
    if (-not (Test-Path $p)) { return $null }
    try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null }
}
# Recompute + cache (used by the schedule and the Refresh button).
function Update-OpsSnapshot { $s = Get-OpsSnapshot; [void](Save-OpsSnapshot $s); $s }
