# SharePoint.ps1 - OPTIONAL add-on: sync Veeam job status into a SharePoint list and track remediation.
#
# Config: data\sharepoint.config.json (helper: graph-setup\Set-SharePointConfig.ps1), shaped:
#   { "enabled": true, "siteHostname": "contoso.sharepoint.com", "sitePath": "/sites/ITOps",
#     "listName": "Veeam Backup Status" }
#
# Auth REUSES the app-only PSConsole-Graph-Write app (GraphWrite.ps1 / data\graph-write.config.json), which
# must ALSO hold the Sites.Selected application permission AND be granted write access to the target site
# (one-time; see docs\ADMIN-GUIDE). Client-credentials tokens use scope=.default, so the added permission
# applies with no secret change.
#
# The list has two column groups. SYNCED columns (Title=Job, VeeamResult, LastRun, SuccessCount,
# WarningCount, FailedCount, LastSynced) are overwritten by the daily sync. REMEDIATION columns (RemStatus,
# FixNote, RemediatedBy, RemediatedAt) are owned by people + the PSConsole remediation editor and are NEVER
# written by the sync - so re-running the sync can't wipe a fix note. RemStatus is seeded to 'Open' only when
# a row is first CREATED.

function Get-SharePointConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'sharepoint.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\sharepoint.config.json' }
}
function Get-SharePointConfig {
    $p = Get-SharePointConfigPath
    if (-not (Test-Path $p)) { return $null }
    try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null }
}
function Test-SharePointConfigured {
    $c = Get-SharePointConfig
    return ([bool]$c -and [bool]$c.enabled -and [bool]$c.siteHostname -and [bool]$c.sitePath -and [bool]$c.listName)
}

# Resolve + cache the Graph site id and list id for the configured site/list.
function Get-SPContext {
    $cfg = Get-SharePointConfig
    if (-not (Test-SharePointConfigured)) { throw 'SharePoint add-on is not configured (data\sharepoint.config.json).' }
    $key = "$($cfg.siteHostname)|$($cfg.sitePath)|$($cfg.listName)"
    if ($script:SPCtx -and $script:SPCtxKey -eq $key) { return $script:SPCtx }
    $path = '/' + ([string]$cfg.sitePath).Trim('/')
    $site = Invoke-GraphWrite -Method GET -Uri "/sites/$($cfg.siteHostname):$path"
    if (-not $site.id) { throw "SharePoint site not found: $($cfg.siteHostname)$path" }
    $lists = Invoke-GraphWrite -Method GET -Uri "/sites/$($site.id)/lists?`$select=id,displayName&`$top=200"
    $list = @($lists.value) | Where-Object { [string]$_.displayName -eq [string]$cfg.listName } | Select-Object -First 1
    if (-not $list.id) { throw "SharePoint list '$($cfg.listName)' not found on the site." }
    $script:SPCtx = @{ siteId = [string]$site.id; listId = [string]$list.id }
    $script:SPCtxKey = $key
    $script:SPCtx
}

# List items (with fields), following paging. Optional OData $filter (e.g. on the indexed BackupDate /
# RemStatus columns) to avoid pulling the whole multi-thousand-row history.
function Get-SPListItems {
    param([string]$Filter)
    $ctx = Get-SPContext
    $items = @()
    $uri = "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items?`$expand=fields&`$top=200"
    # The tolerance header lets us filter columns that aren't indexed yet (works while the list is small and
    # remains harmless once BackupDate/RemStatus are indexed - see ADMIN-GUIDE for the one-time index step).
    $hdr = if ($Filter) { @{ Prefer = 'HonorNonIndexedQueriesWarningMayFailRandomly' } } else { $null }
    if ($Filter) { $uri += "&`$filter=$Filter" }
    do {
        $resp = Invoke-GraphWrite -Method GET -Uri $uri -Headers $hdr
        $items += @($resp.value)
        $uri = [string]$resp.'@odata.nextLink'
    } while ($uri)
    $items
}

# Next business day after $Date (Fri/Sat/Sun -> Monday). Weekend backups aren't reviewed until Monday.
function Get-ReviewDueDate {
    param([datetime]$Date)
    $d = $Date.Date.AddDays(1)
    while ($d.DayOfWeek -eq [DayOfWeek]::Saturday -or $d.DayOfWeek -eq [DayOfWeek]::Sunday) { $d = $d.AddDays(1) }
    $d
}

# Collapse the flat Veeam session list into one row per Job per calendar day: worst result of the day wins
# (Failed > Warning > Success), with per-day session counts.
function Get-VeeamDailyRows {
    param($SessionResult)
    $byKey = @{}
    foreach ($s in @($SessionResult.sessions)) {
        $job = [string]$s.Job
        if (-not $job) { continue }
        $d = $null
        try { if ($s.End) { $d = ([datetime]$s.End).Date } } catch {}
        if (-not $d) { try { if ($s.Start) { $d = ([datetime]$s.Start).Date } } catch {} }
        if (-not $d) { continue }
        $key = "$job|$($d.ToString('yyyy-MM-dd'))"
        if (-not $byKey.ContainsKey($key)) { $byKey[$key] = [ordered]@{ Job = $job; Date = $d; Success = 0; Warning = 0; Failed = 0 } }
        switch -Regex ([string]$s.Result) {
            'Fail'    { $byKey[$key].Failed++ }
            'Warn'    { $byKey[$key].Warning++ }
            'Success' { $byKey[$key].Success++ }
            default   { }
        }
    }
    foreach ($k in $byKey.Keys) {
        $v = $byKey[$k]
        $worst = if ($v.Failed -gt 0) { 'Failed' } elseif ($v.Warning -gt 0) { 'Warning' } else { 'Success' }
        [PSCustomObject]@{ Job = $v.Job; Date = $v.Date; Result = $worst; Success = $v.Success; Warning = $v.Warning; Failed = $v.Failed }
    }
}

# Send Graph write requests in $batch groups of 20, retrying 429/503 sub-requests with backoff. For the big
# one-time history backfill. $Requests = list of @{ method; url; body }. Returns @{ ok; failed }.
function Invoke-GraphBatchWrite {
    param([System.Collections.Generic.List[object]]$Requests)
    $ok = 0; $failed = 0; $i = 0
    while ($i -lt $Requests.Count) {
        $slice = @()
        for ($j = 0; $j -lt 20 -and $i -lt $Requests.Count; $j++, $i++) {
            $r = $Requests[$i]
            $slice += @{ id = [string]$j; method = $r.method; url = $r.url; headers = @{ 'Content-Type' = 'application/json' }; body = $r.body }
        }
        $attempt = 0
        do {
            $resp = Invoke-GraphWrite -Method POST -Uri '/$batch' -Body @{ requests = $slice }
            $retry = @(); $wait = 0
            foreach ($rr in @($resp.responses)) {
                $st = [int]$rr.status
                if ($st -ge 200 -and $st -lt 300) { $ok++ }
                elseif ($st -eq 429 -or $st -ge 500) {
                    # 429 = throttled, >=500 = transient SharePoint error (incl. the empty-message UnknownError
                    # that shows up under rapid item creation) - both are safe to retry.
                    $orig = $slice | Where-Object { [string]$_.id -eq [string]$rr.id }
                    if ($orig) { $retry += $orig }
                    $ra = 0; try { $ra = [int]$rr.headers.'Retry-After' } catch {}
                    if ($ra -gt $wait) { $wait = $ra }
                }
                else { $failed++ }
            }
            $slice = @($retry); $attempt++
            if ($slice.Count) { if ($wait -le 0) { $wait = 10 }; Start-Sleep -Seconds ([Math]::Min($wait, 30)) }
        } while ($slice.Count -and $attempt -lt 6)
        $failed += $slice.Count
    }
    @{ ok = $ok; failed = $failed }
}

# DAILY SYNC: upsert one row per Job per DAY over the recent window using REAL Veeam data. Failed days seed
# RemStatus='Open' (needs remediation); Warning/Success -> 'N/A' (warnings are informational only). Never
# stomps a human's RemStatus/FixNote on an existing row - only auto-opens a row that is still 'N/A'.
function Sync-VeeamToSharePoint {
    param([int]$Days = 8)
    if (-not (Test-SharePointConfigured)) { return @{ ok = $false; error = 'SharePoint add-on is not configured.' } }
    if (-not (Test-VeeamConfigured))      { return @{ ok = $false; error = 'Veeam add-on is not configured.' } }
    try {
        $sr = Get-VeeamSessions -Days $Days
        if (-not $sr.ok) { return @{ ok = $false; error = "Veeam query failed: $($sr.error)" } }
        # Server (VBR) daily rows, plus the VB365 job's daily rows (tagged Office 365 so the view sort can
        # order it after the server jobs). Get-VboSessions returns the same shape, so Get-VeeamDailyRows works.
        $work = @()
        foreach ($r in @(Get-VeeamDailyRows -SessionResult $sr)) { $work += [pscustomobject]@{ row = $r; source = $null } }
        try { $vbo = Get-VboSessions -Days $Days -EnabledOnly; if ($vbo.ok) { foreach ($r in @(Get-VeeamDailyRows -SessionResult $vbo)) { $work += [pscustomobject]@{ row = $r; source = 'Office 365' } } } } catch {}
        $ctx   = Get-SPContext
        $since = (Get-Date).Date.AddDays(-([Math]::Abs($Days) + 2)).ToString('yyyy-MM-ddT00:00:00Z')
        $existing = @{}
        foreach ($it in (Get-SPListItems -Filter "fields/BackupDate ge '$since'")) {
            $t = [string]$it.fields.Title; $bd = ''
            try { if ($it.fields.BackupDate) { $bd = ([datetime]$it.fields.BackupDate).ToString('yyyy-MM-dd') } } catch {}
            if ($t -and $bd) { $existing["$t|$bd"] = $it }
        }
        $now = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        $created = 0; $updated = 0
        foreach ($w in $work) {
            $r        = $w.row
            $ds       = $r.Date.ToString('yyyy-MM-dd')
            $needsRem = ($r.Result -eq 'Failed')
            $item     = $existing["$($r.Job)|$ds"]
            if ($item) {
                $fields = @{ VeeamResult = $r.Result; SuccessCount = $r.Success; WarningCount = $r.Warning; FailedCount = $r.Failed; LastSynced = $now }
                if ($w.source) { $fields['Source'] = $w.source }
                $cur = [string]$item.fields.RemStatus
                if ($needsRem -and ($cur -eq 'N/A' -or [string]::IsNullOrEmpty($cur))) { $fields['RemStatus'] = 'Open' }
                Invoke-GraphWrite -Method PATCH -Uri "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items/$($item.id)/fields" -Body $fields | Out-Null
                $updated++
            }
            else {
                $fields = @{
                    Title = $r.Job; BackupDate = $ds; BackupYear = $r.Date.Year
                    VeeamResult = $r.Result; SuccessCount = $r.Success; WarningCount = $r.Warning; FailedCount = $r.Failed
                    ReviewDue = (Get-ReviewDueDate $r.Date).ToString('yyyy-MM-dd')
                    RemStatus = $(if ($needsRem) { 'Open' } else { 'N/A' }); LastSynced = $now
                }
                if ($w.source) { $fields['Source'] = $w.source }
                Invoke-GraphWrite -Method POST -Uri "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items" -Body @{ fields = $fields } | Out-Null
                $created++
            }
        }
        return @{ ok = $true; created = $created; updated = $updated; days = $work.Count }
    }
    catch { return @{ ok = $false; error = (Get-GraphError $_) } }
}

# ONE-TIME BACKFILL: create a daily Success row per job back $Years (default 3). Everything is 'Success'/'N/A'
# except the recent window, which Sync-VeeamToSharePoint then overwrites with real results. Idempotent - skips
# any Job|Date that already exists. Batched via $batch. Use -WhatIf to get the row count/estimate first.
function Initialize-VeeamHistory {
    param([int]$Years = 3, [switch]$WhatIf)
    if (-not (Test-SharePointConfigured)) { return @{ ok = $false; error = 'SharePoint add-on is not configured.' } }
    if (-not (Test-VeeamConfigured))      { return @{ ok = $false; error = 'Veeam add-on is not configured.' } }
    try {
        $sr = Get-VeeamSessions -Days 8
        if (-not $sr.ok) { return @{ ok = $false; error = "Veeam query failed: $($sr.error)" } }
        $jobs = @(@(Get-VeeamLastJobStatus $sr) | ForEach-Object { [string]$_.Job } | Where-Object { $_ } | Sort-Object -Unique)
        if (-not $jobs.Count) { return @{ ok = $false; error = 'No Veeam jobs found to backfill.' } }
        $ctx = Get-SPContext
        $existing = @{}
        foreach ($it in (Get-SPListItems)) {
            $t = [string]$it.fields.Title; $bd = ''
            try { if ($it.fields.BackupDate) { $bd = ([datetime]$it.fields.BackupDate).ToString('yyyy-MM-dd') } } catch {}
            if ($t -and $bd) { $existing["$t|$bd"] = $true }
        }
        $today = (Get-Date).Date
        $start = $today.AddYears(-[Math]::Abs($Years))
        $now   = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        $reqs  = New-Object System.Collections.Generic.List[object]
        for ($d = $start; $d -le $today; $d = $d.AddDays(1)) {
            $ds     = $d.ToString('yyyy-MM-dd')
            $review = (Get-ReviewDueDate $d).ToString('yyyy-MM-dd')
            foreach ($job in $jobs) {
                if ($existing.ContainsKey("$job|$ds")) { continue }
                $fields = @{ Title = $job; BackupDate = $ds; BackupYear = $d.Year; VeeamResult = 'Success'; ReviewDue = $review; RemStatus = 'N/A'; LastSynced = $now }
                $reqs.Add(@{ method = 'POST'; url = "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items"; body = @{ fields = $fields } })
            }
        }
        if ($WhatIf) { return @{ ok = $true; whatIf = $true; wouldCreate = $reqs.Count; jobs = $jobs.Count } }
        $res = Invoke-GraphBatchWrite -Requests $reqs
        $script:SPCtx = $ctx
        return @{ ok = $true; created = $res.ok; failed = $res.failed; total = $reqs.Count; jobs = $jobs.Count }
    }
    catch { return @{ ok = $false; error = (Get-GraphError $_) } }
}

# ONE-TIME BACKFILL for the VB365 (Office 365) job: a daily Success row from the LIST'S earliest date through
# today, tagged Source='Office 365', so its history lines up with the server jobs' range. Idempotent - skips any
# Job|Date already present. -WhatIf returns the row count without writing. The daily Sync-VeeamToSharePoint then
# overwrites the recent window with real results.
function Initialize-Vbo365History {
    param([switch]$WhatIf)
    if (-not (Test-SharePointConfigured)) { return @{ ok = $false; error = 'SharePoint add-on is not configured.' } }
    if (-not (Test-VeeamConfigured))      { return @{ ok = $false; error = 'Veeam/VB365 add-on is not configured.' } }
    try {
        $vbo = Get-VboSessions -Days 8 -EnabledOnly
        if (-not $vbo.ok) { return @{ ok = $false; error = "VB365 query failed: $($vbo.error)" } }
        $jobs = @(@(Get-VeeamLastJobStatus $vbo) | ForEach-Object { [string]$_.Job } | Where-Object { $_ } | Sort-Object -Unique)
        if (-not $jobs.Count) { return @{ ok = $false; error = 'No enabled VB365 job found to backfill.' } }
        $ctx = Get-SPContext
        $existing = @{}; $earliest = $null
        foreach ($it in (Get-SPListItems)) {
            $t = [string]$it.fields.Title; $bd = ''
            try { if ($it.fields.BackupDate) { $d = [datetime]$it.fields.BackupDate; $bd = $d.ToString('yyyy-MM-dd'); if (-not $earliest -or $d -lt $earliest) { $earliest = $d } } } catch {}
            if ($t -and $bd) { $existing["$t|$bd"] = $true }
        }
        if (-not $earliest) { return @{ ok = $false; error = 'List is empty - nothing to align to.' } }
        $today = (Get-Date).Date; $start = $earliest.Date; $now = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        $reqs = New-Object System.Collections.Generic.List[object]
        for ($d = $start; $d -le $today; $d = $d.AddDays(1)) {
            $ds     = $d.ToString('yyyy-MM-dd')
            $review = (Get-ReviewDueDate $d).ToString('yyyy-MM-dd')
            foreach ($job in $jobs) {
                if ($existing.ContainsKey("$job|$ds")) { continue }
                $fields = @{ Title = $job; BackupDate = $ds; BackupYear = $d.Year; VeeamResult = 'Success'; ReviewDue = $review; RemStatus = 'N/A'; LastSynced = $now; Source = 'Office 365' }
                $reqs.Add(@{ method = 'POST'; url = "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items"; body = @{ fields = $fields } })
            }
        }
        if ($WhatIf) { return @{ ok = $true; whatIf = $true; wouldCreate = $reqs.Count; jobs = $jobs.Count; from = $start.ToString('yyyy-MM-dd') } }
        $res = Invoke-GraphBatchWrite -Requests $reqs
        return @{ ok = $true; created = $res.ok; failed = $res.failed; total = $reqs.Count; jobs = $jobs.Count; from = $start.ToString('yyyy-MM-dd') }
    }
    catch { return @{ ok = $false; error = (Get-GraphError $_) } }
}

# ---- 3-year rolling prune (keeps the CARF log bounded without touching schema or the actual Veeam backups) ----
# Settings live under `veeamHistoryPrune`: { enabled:bool, retentionYears:int(3) }.
function Get-VeeamHistoryPruneSettings {
    $def = [ordered]@{ enabled = $false; retentionYears = 3 }
    $cfg = Get-Store config
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'veeamHistoryPrune') -and $cfg.veeamHistoryPrune) {
        $s = $cfg.veeamHistoryPrune
        if ($null -ne $s.enabled)        { $def.enabled        = [bool]$s.enabled }
        if ($s.retentionYears)           { $def.retentionYears = [int]$s.retentionYears }
    }
    $def
}
function Set-VeeamHistoryPruneSettings {
    param([bool]$Enabled, [int]$RetentionYears)
    if ($RetentionYears -lt 1)  { $RetentionYears = 3 }
    if ($RetentionYears -gt 30) { $RetentionYears = 30 }
    $val = [ordered]@{ enabled = [bool]$Enabled; retentionYears = $RetentionYears }
    $cfg = Get-Store config
    $cfg | Add-Member -NotePropertyName veeamHistoryPrune -NotePropertyValue $val -Force
    Set-Store config $cfg
    $val
}

# Delete Backup-Status rows older than the retention window. NEVER deletes rows still Open/Investigating (so an
# unresolved failure is never auto-purged). -WhatIf previews the count without deleting. A scheduled call is a
# no-op unless enabled; -WhatIf always previews regardless. Returns @{ ok; wouldDelete/deleted; exemptOpen; cutoff }.
function Invoke-VeeamHistoryPrune {
    param([switch]$WhatIf, [int]$Years)
    if (-not (Test-SharePointConfigured)) { return @{ ok = $false; error = 'SharePoint add-on is not configured.' } }
    $s = Get-VeeamHistoryPruneSettings
    if (-not $WhatIf -and -not $s.enabled) { return @{ ok = $false; note = 'disabled' } }
    $yrs = if ($Years -ge 1) { $Years } else { [int]$s.retentionYears }
    if ($yrs -lt 1) { $yrs = 3 }
    try {
        $cutoff    = (Get-Date).Date.AddYears(-$yrs)
        $cutoffStr = $cutoff.ToString('yyyy-MM-ddT00:00:00Z')
        $ctx = Get-SPContext
        $old = @(Get-SPListItems -Filter "fields/BackupDate lt '$cutoffStr'")
        $del = @($old | Where-Object { $rs = [string]$_.fields.RemStatus; $rs -ne 'Open' -and $rs -ne 'Investigating' })
        $exempt = @($old).Count - @($del).Count
        if ($WhatIf) { return @{ ok = $true; whatIf = $true; wouldDelete = @($del).Count; exemptOpen = $exempt; cutoff = $cutoff.ToString('yyyy-MM-dd'); years = $yrs } }
        $reqs = New-Object System.Collections.Generic.List[object]
        foreach ($it in $del) { $reqs.Add(@{ method = 'DELETE'; url = "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items/$($it.id)" }) }
        $res = if ($reqs.Count) { Invoke-GraphBatchWrite -Requests $reqs } else { @{ ok = 0; failed = 0 } }
        return @{ ok = $true; deleted = $res.ok; failed = $res.failed; total = $reqs.Count; exemptOpen = $exempt; cutoff = $cutoff.ToString('yyyy-MM-dd'); years = $yrs }
    }
    catch { return @{ ok = $false; error = (Get-GraphError $_) } }
}

# Rows for the remediation editor page. By default only ACTIONABLE rows (RemStatus Open/Investigating) so the
# page doesn't pull the whole multi-thousand-row history; -All returns everything (rarely needed).
function Get-SPRemediationRows {
    param([switch]$All)
    $filter = if ($All) { $null } else { "fields/RemStatus eq 'Open' or fields/RemStatus eq 'Investigating'" }
    $out = @()
    foreach ($it in (Get-SPListItems -Filter $filter)) {
        $f = $it.fields
        $bd = ''
        try { if ($f.BackupDate) { $bd = ([datetime]$f.BackupDate).ToString('yyyy-MM-dd') } } catch { $bd = [string]$f.BackupDate }
        $out += [PSCustomObject]@{
            ItemId       = [string]$it.id
            Job          = [string]$f.Title
            BackupDate   = $bd
            VeeamResult  = [string]$f.VeeamResult
            Success      = [int]$f.SuccessCount
            Warning      = [int]$f.WarningCount
            Failed       = [int]$f.FailedCount
            LastSynced   = [string]$f.LastSynced
            RemStatus    = if ($f.RemStatus) { [string]$f.RemStatus } else { 'N/A' }
            FixNote      = [string]$f.FixNote
            RemediatedBy = [string]$f.RemediatedBy
            RemediatedAt = [string]$f.RemediatedAt
        }
    }
    @($out | Sort-Object BackupDate, Job)
}

# Write the remediation columns for one item (from the editor). Stamps RemediatedBy/At. Never called by the sync.
function Set-SPRemediation {
    param([string]$ItemId, [string]$Status, [string]$Note, [string]$By)
    if (-not (Test-SharePointConfigured)) { return @{ ok = $false; error = 'SharePoint add-on is not configured.' } }
    if (-not $ItemId) { return @{ ok = $false; error = 'Missing item id.' } }
    $valid = @('N/A', 'Open', 'Investigating', 'Remediated', 'Ignored')
    $status = if ($Status) { [string]$Status } else { 'Open' }
    if ($valid -notcontains $status) { return @{ ok = $false; error = "Invalid status '$status'." } }
    try {
        $ctx = Get-SPContext
        $fields = @{
            RemStatus    = $status
            FixNote      = [string]$Note
            RemediatedBy = [string]$By
            RemediatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        }
        Invoke-GraphWrite -Method PATCH -Uri "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items/$ItemId/fields" -Body $fields | Out-Null
        return @{ ok = $true }
    }
    catch { return @{ ok = $false; error = (Get-GraphError $_) } }
}

# The columns PSConsole's daily sync + remediation editor expect. Used to both create a new list and to
# reconcile (add missing columns to) a list that already exists. Title is built-in and holds the job name;
# each row is one job on one day (keyed Title + BackupDate).
function Get-SPVeeamDesiredColumns {
    @(
        @{ name = 'BackupDate';   spec = @{ dateTime = @{ format = 'dateOnly'; displayAs = 'standard' } } }
        @{ name = 'BackupYear';   spec = @{ number   = @{ decimalPlaces = 'none' } } }
        @{ name = 'VeeamResult';  spec = @{ choice   = @{ choices = @('Success', 'Warning', 'Failed'); displayAs = 'dropDownMenu' } } }
        @{ name = 'SuccessCount'; spec = @{ number   = @{} } }
        @{ name = 'WarningCount'; spec = @{ number   = @{} } }
        @{ name = 'FailedCount';  spec = @{ number   = @{} } }
        @{ name = 'ReviewDue';    spec = @{ dateTime = @{ format = 'dateOnly'; displayAs = 'standard' } } }
        @{ name = 'RemStatus';    spec = @{ choice   = @{ choices = @('N/A', 'Open', 'Investigating', 'Remediated', 'Ignored'); displayAs = 'dropDownMenu' } } }
        @{ name = 'FixNote';      spec = @{ text     = @{ allowMultipleLines = $true } } }
        @{ name = 'RemediatedBy'; spec = @{ text     = @{} } }
        @{ name = 'RemediatedAt'; spec = @{ text     = @{} } }
        @{ name = 'LastSynced';   spec = @{ text     = @{} } }
        # Distinguishes VBR (server) jobs from the VB365 job. Only the Office 365 rows are tagged; server rows
        # are left blank, so a "BackupDate desc, Source asc" view sort puts the O365 row last within each day
        # without mass-editing the existing server rows. See Sync-VeeamToSharePoint + Initialize-Vbo365History.
        @{ name = 'Source';       spec = @{ choice   = @{ choices = @('Server', 'Office 365'); displayAs = 'dropDownMenu' } } }
    )
}

# Provision the configured list WITH all required columns. Idempotent: creates the list if absent, and either
# way adds any MISSING columns (so it also fixes up a list you created by hand). Requires the graph-write app
# to be granted the Manage role on the site (Sites.Selected) - schema changes (list/column creation) need more
# than Write. Returns @{ ok; listId; note; columnsAdded; error }.
function New-SPVeeamList {
    if (-not (Test-SharePointConfigured)) { return @{ ok = $false; error = 'SharePoint add-on is not configured.' } }
    $cfg = Get-SharePointConfig
    try {
        $path = '/' + ([string]$cfg.sitePath).Trim('/')
        $site = Invoke-GraphWrite -Method GET -Uri "/sites/$($cfg.siteHostname):$path"
        if (-not $site.id) { return @{ ok = $false; error = "Site not found: $($cfg.siteHostname)$path" } }
        $lists    = Invoke-GraphWrite -Method GET -Uri "/sites/$($site.id)/lists?`$select=id,displayName&`$top=200"
        $existing = @($lists.value) | Where-Object { [string]$_.displayName -eq [string]$cfg.listName } | Select-Object -First 1
        if ($existing.id) {
            $listId = [string]$existing.id
            $note   = 'list already existed'
        }
        else {
            $created = Invoke-GraphWrite -Method POST -Uri "/sites/$($site.id)/lists" -Body @{ displayName = [string]$cfg.listName; list = @{ template = 'genericList' } }
            $listId  = [string]$created.id
            $note    = 'list created'
        }
        # Reconcile columns: add any of the desired columns not already present.
        $byName = @{}
        foreach ($c in @((Invoke-GraphWrite -Method GET -Uri "/sites/$($site.id)/lists/$listId/columns?`$select=id,name").value)) { $byName[[string]$c.name] = $c }
        $added = @()
        foreach ($d in (Get-SPVeeamDesiredColumns)) {
            if (-not $byName.ContainsKey($d.name)) {
                Invoke-GraphWrite -Method POST -Uri "/sites/$($site.id)/lists/$listId/columns" -Body (@{ name = $d.name } + $d.spec) | Out-Null
                $added += $d.name
            }
        }
        # Ensure RemStatus carries the 'N/A' choice (for first-try successes) even if the column pre-existed.
        if ($byName.ContainsKey('RemStatus')) {
            try { Invoke-GraphWrite -Method PATCH -Uri "/sites/$($site.id)/lists/$listId/columns/$($byName['RemStatus'].id)" -Body @{ choice = @{ choices = @('N/A', 'Open', 'Investigating', 'Remediated', 'Ignored'); displayAs = 'dropDownMenu' } } | Out-Null } catch {}
        }
        $script:SPCtx = $null
        return @{ ok = $true; listId = $listId; note = $note; columnsAdded = $added }
    }
    catch { return @{ ok = $false; error = (Get-GraphError $_) } }
}
