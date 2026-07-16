# Audit.ps1 - append-only audit log (JSONL) with size-based rotation + retention. Requires Store.ps1.
#
# audit.jsonl is the ACTIVE file. When it passes the configured size (config.auditMaxMB, default 5 MB) a
# write rotates it into audit-archive\audit-<yyyyMMdd-HHmmss>.jsonl and starts a fresh active file, so no
# single file ever bloats. Archives older than config.auditRetentionDays (default 730 = 2 years; 0 = keep
# forever) are pruned on rotation. Because the active file stays small, the dashboard tail and the default
# Audit view are fast; a date-range search reads the active file PLUS only the archives whose window
# overlaps the requested range.

function Get-AuditLogPath { Join-Path (Get-DataDir) 'audit.jsonl' }
function Get-AuditArchiveDir { Join-Path (Get-DataDir) 'audit-archive' }

# Rotation/retention settings from config, cached ~60s so we don't read config on every single write.
$script:AuditSettings = $null
$script:AuditSettingsAt = [datetime]::MinValue
function Get-AuditSettings {
    if ($script:AuditSettings -and (((Get-Date) - $script:AuditSettingsAt).TotalSeconds -lt 60)) { return $script:AuditSettings }
    $maxMB = 5.0; $days = 730
    try {
        $cfg = Get-Store config
        if ($cfg) {
            if (($cfg.PSObject.Properties.Name -contains 'auditMaxMB') -and $cfg.auditMaxMB) { $maxMB = [double]$cfg.auditMaxMB }
            if (($cfg.PSObject.Properties.Name -contains 'auditRetentionDays') -and ($null -ne $cfg.auditRetentionDays)) { $days = [int]$cfg.auditRetentionDays }
        }
    } catch {}
    if ($maxMB -lt 1) { $maxMB = 1 }
    if ($days -lt 0)  { $days = 0 }
    $script:AuditSettings = @{ maxBytes = [long]($maxMB * 1MB); retentionDays = $days }
    $script:AuditSettingsAt = Get-Date
    $script:AuditSettings
}

# Rotate the active log if it's over size, then prune expired archives. Best-effort + race-safe: if another
# request thread already rotated, the Move simply fails and we move on. Called after each successful append.
function Invoke-AuditMaintenance {
    $log = Get-AuditLogPath
    if (-not (Test-Path $log)) { return }
    $s = Get-AuditSettings
    $len = 0; try { $len = (Get-Item -LiteralPath $log -ErrorAction Stop).Length } catch { return }
    if ($len -lt $s.maxBytes) { return }
    $arc = Get-AuditArchiveDir
    try { if (-not (Test-Path $arc)) { New-Item -ItemType Directory -Path $arc -Force -ErrorAction Stop | Out-Null } } catch { return }
    $dest = Join-Path $arc ("audit-{0}.jsonl" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    if (Test-Path $dest) { return }                                   # already rotated within this second
    try { Move-Item -LiteralPath $log -Destination $dest -ErrorAction Stop }
    catch { return }                                                  # another thread won the race / transient lock
    # Prune archives older than retention (0 = keep forever).
    if ($s.retentionDays -gt 0) {
        $cut = (Get-Date).AddDays(-$s.retentionDays)
        try {
            Get-ChildItem -LiteralPath $arc -Filter 'audit-*.jsonl' -ErrorAction Stop |
                Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

function Write-Audit($User, $Role, $Action, $Script, $Params, $Status, $DurationMs, $Detail) {
    $line = [PSCustomObject]@{
        ts=(Get-Date).ToString('o'); user=$User; role=$Role; action=$Action;
        script=$Script; params=$Params; status=$Status; durationMs=$DurationMs; detail=$Detail
    } | ConvertTo-Json -Compress -Depth 6
    $log = Get-AuditLogPath
    # With multiple request threads, concurrent appends can hit a file-sharing violation.
    # Retry briefly rather than throwing (which would 500 the request).
    for ($i = 0; $i -lt 5; $i++) {
        try { Add-Content -Path $log -Value $line -Encoding UTF8 -ErrorAction Stop; break }
        catch { if ($i -eq 4) { throw }; Start-Sleep -Milliseconds 50 }
    }
    try { Invoke-AuditMaintenance } catch {}
}

# Most recent $Count events, newest first. Reads the active file's tail; if it was just rotated and holds
# fewer than $Count lines, tops up from the newest archive(s) so the view stays full.
function Get-AuditTail([int]$Count=200) {
    $log = Get-AuditLogPath
    $lines = @()
    if (Test-Path $log) { $lines = @(Get-Content $log -Tail $Count | Where-Object { $_ }) }
    if ($lines.Count -lt $Count) {
        $arc = Get-AuditArchiveDir
        if (Test-Path $arc) {
            foreach ($af in @(Get-ChildItem -LiteralPath $arc -Filter 'audit-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
                $need = $Count - $lines.Count
                if ($need -le 0) { break }
                $pre = @(Get-Content $af.FullName -Tail $need | Where-Object { $_ })   # older events -> prepend
                $lines = @($pre + $lines)
            }
        }
    }
    $rows = @($lines | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
    if ($rows.Count -gt 1) { [array]::Reverse($rows) }                # files are chronological; show newest first
    @($rows)
}

# Events between two timestamps (inclusive), newest first. Empty $From/$To = open-ended on that side.
# $From/$To are strings so an absent bound stays absent (a typed [datetime] would default to MinValue).
# Reads the active file, plus - only when a bound is set - the archive files whose window overlaps the range
# (archive filename/LastWriteTime bounds let us skip archives entirely outside the requested window).
function Get-AuditRange {
    param([string]$From, [string]$To, [int]$Max = 2000)
    $log = Get-AuditLogPath
    $f = $null; $t = $null
    if ($From) { try { $f = [datetime]::Parse($From) } catch {} }
    if ($To)   { try { $t = [datetime]::Parse($To) } catch {} }

    $files = New-Object System.Collections.Generic.List[string]
    if (Test-Path $log) { $files.Add($log) }
    if ($f -or $t) {
        $arc = Get-AuditArchiveDir
        if (Test-Path $arc) {
            $archives = @(Get-ChildItem -LiteralPath $arc -Filter 'audit-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
            for ($k = 0; $k -lt $archives.Count; $k++) {
                $end   = $archives[$k].LastWriteTime                                             # ~ newest event in this archive
                $start = if ($k -eq 0) { [datetime]::MinValue } else { $archives[$k-1].LastWriteTime }   # ~ oldest event
                if ($f -and $end -lt $f) { continue }
                if ($t -and $start -gt $t) { continue }
                $files.Add($archives[$k].FullName)
            }
        }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        foreach ($line in (Get-Content -LiteralPath $file)) {
            if (-not $line) { continue }
            $o = $null; try { $o = $line | ConvertFrom-Json } catch { continue }
            if (-not $o.ts) { continue }
            $ts = $null; try { $ts = [datetime]$o.ts } catch { continue }
            if ($f -and $ts -lt $f) { continue }
            if ($t -and $ts -gt $t) { continue }
            [void]$rows.Add($o)
        }
    }
    $sorted = @($rows | Sort-Object { [datetime]$_.ts } -Descending)
    if ($Max -gt 0 -and $sorted.Count -gt $Max) { $sorted = @($sorted | Select-Object -First $Max) }
    @($sorted)
}
