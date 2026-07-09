# Audit.ps1 - append-only per-run audit log (JSONL). Requires Store.ps1.
function Write-Audit($User, $Role, $Action, $Script, $Params, $Status, $DurationMs, $Detail) {
    $line = [PSCustomObject]@{
        ts=(Get-Date).ToString('o'); user=$User; role=$Role; action=$Action;
        script=$Script; params=$Params; status=$Status; durationMs=$DurationMs; detail=$Detail
    } | ConvertTo-Json -Compress -Depth 6
    $log = Join-Path (Get-DataDir) 'audit.jsonl'
    # With multiple request threads, concurrent appends can hit a file-sharing violation.
    # Retry briefly rather than throwing (which would 500 the request).
    for ($i = 0; $i -lt 5; $i++) {
        try { Add-Content -Path $log -Value $line -Encoding UTF8 -ErrorAction Stop; break }
        catch { if ($i -eq 4) { throw }; Start-Sleep -Milliseconds 50 }
    }
}
# Most recent $Count events, newest first.
function Get-AuditTail([int]$Count=200) {
    $log = Join-Path (Get-DataDir) 'audit.jsonl'
    if (-not (Test-Path $log)) { return @() }
    $rows = @(Get-Content $log -Tail $Count | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
    [array]::Reverse($rows)          # file is chronological; show newest first
    @($rows)
}

# Events between two timestamps (inclusive), newest first. Empty $From/$To = open-ended on that side.
# $From/$To are strings so an absent bound stays absent (a typed [datetime] would default to MinValue).
function Get-AuditRange {
    param([string]$From, [string]$To, [int]$Max = 2000)
    $log = Join-Path (Get-DataDir) 'audit.jsonl'
    if (-not (Test-Path $log)) { return @() }
    $f = $null; $t = $null
    if ($From) { try { $f = [datetime]::Parse($From) } catch {} }
    if ($To)   { try { $t = [datetime]::Parse($To) } catch {} }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Get-Content $log)) {
        if (-not $line) { continue }
        $o = $null; try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not $o.ts) { continue }
        $ts = $null; try { $ts = [datetime]$o.ts } catch { continue }
        if ($f -and $ts -lt $f) { continue }
        if ($t -and $ts -gt $t) { continue }
        [void]$rows.Add($o)
    }
    $sorted = @($rows | Sort-Object { [datetime]$_.ts } -Descending)
    if ($Max -gt 0 -and $sorted.Count -gt $Max) { $sorted = @($sorted | Select-Object -First $Max) }
    @($sorted)
}
