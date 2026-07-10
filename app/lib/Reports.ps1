# Reports.ps1 - user-defined SCHEDULED REPORTS: run a catalog script on a schedule and email the
# result as an HTML table. Standard feature (admin-managed). Everything lives in the module so the
# Pode schedule runspace can drive it (schedules only see module functions, not script-scope ones).
#
# A schedule record (stored in data\report-schedules.json):
#   { id, name, script, params:{...}, recipients:[...], frequency:'daily|weekly|monthly',
#     hour:0-23, minute:0-59, dayOfWeek:0-6 (weekly), dayOfMonth:1-28 (monthly),
#     enabled:bool, lastRun:iso, lastStatus:str }
#
# Dispatch model: ONE Pode schedule fires every 15 min and calls Invoke-DueReports, which sends any
# report whose scheduled time has passed for its current occurrence and hasn't been sent yet
# (tracked via lastRun). This supports arbitrary user-defined schedules without per-report cron.

$script:ReportsScriptDir = Join-Path $PSScriptRoot '..\scripts'

function Get-ReportSchedules { @(Get-Store report-schedules) }
function Set-ReportSchedules { param($Schedules) Set-Store report-schedules @($Schedules) }

# Self-contained script runner (mirrors Start-PSConsole's Invoke-ManagedScript, but in the module so
# it's callable from schedule runspaces). Leaf-only path guards traversal.
function Invoke-ReportScriptFile {
    param([string]$Name, [hashtable]$Parameters, [int]$TimeoutSec = 120)
    $path = Join-Path $script:ReportsScriptDir (Split-Path -Leaf $Name)
    if (-not (Test-Path $path)) { return @{ ok = $false; error = "script not found: $Name"; data = @() } }
    $ps = [PowerShell]::Create()
    [void]$ps.AddCommand($path)
    if ($Parameters) { foreach ($k in $Parameters.Keys) { if ($null -ne $Parameters[$k] -and "$($Parameters[$k])" -ne '') { [void]$ps.AddParameter($k, $Parameters[$k]) } } }
    $async = $ps.BeginInvoke()
    if (-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSec))) { $ps.Stop(); $ps.Dispose(); return @{ ok = $false; error = "Timed out after ${TimeoutSec}s"; data = @() } }
    try {
        $out  = $ps.EndInvoke($async)
        $errs = @($ps.Streams.Error | ForEach-Object { $_.ToString() })
        @{ ok = ($errs.Count -eq 0); error = ($errs -join "`n"); data = @($out) }
    } catch { @{ ok = $false; error = $_.Exception.Message; data = @() } }
    finally { $ps.Dispose() }
}

# Convert a schedule's stored params object (from JSON) into a hashtable for the runner.
function ConvertTo-ReportParams {
    param($ParamObj)
    $h = @{}
    if ($ParamObj) { foreach ($p in $ParamObj.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

# Human-readable schedule description, e.g. "Daily 07:00" / "Weekly Mon 06:30" / "Monthly day 1 08:00".
function Get-ReportScheduleText {
    param($Schedule)
    $t = '{0:00}:{1:00}' -f [int]$Schedule.hour, [int]$Schedule.minute
    switch ([string]$Schedule.frequency) {
        'weekly'  { $dow = @('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[[int]$Schedule.dayOfWeek]; "Weekly $dow $t" }
        'monthly' { "Monthly day $([int]$Schedule.dayOfMonth) $t" }
        default   { "Daily $t" }
    }
}

# Is this schedule due to send now (scheduled time passed for the current occurrence, not already sent)?
function Test-ReportDue {
    param($Schedule, [datetime]$Now = (Get-Date))
    if (-not $Schedule.enabled) { return $false }
    switch ([string]$Schedule.frequency) {
        'daily'   { }
        'weekly'  { if ([int]$Now.DayOfWeek -ne [int]$Schedule.dayOfWeek) { return $false } }
        'monthly' { if ($Now.Day -ne [int]$Schedule.dayOfMonth) { return $false } }
        default   { return $false }
    }
    $sched = $Now.Date.AddHours([int]$Schedule.hour).AddMinutes([int]$Schedule.minute)
    if ($Now -lt $sched) { return $false }
    if ($Schedule.lastRun) {
        $last = [datetime]::MinValue; try { $last = [datetime]$Schedule.lastRun } catch {}
        if ($last -ge $sched) { return $false }   # already sent this occurrence
    }
    return $true
}

# Run a schedule's script and email the result to its recipients. Returns a status hashtable.
function Send-ScheduledReport {
    param($Schedule)
    $params = ConvertTo-ReportParams $Schedule.params
    $r      = Invoke-ReportScriptFile -Name ([string]$Schedule.script) -Parameters $params
    $rows   = @($r.data)
    $title  = if ($Schedule.name) { [string]$Schedule.name } else { [string]$Schedule.script }
    $html   = ConvertTo-ResultHtml -Title $title -Rows $rows
    if (-not $r.ok) { $html = "<p style='font-family:Segoe UI,Arial,sans-serif;color:#b91c1c'>Script reported an error: $(ConvertTo-PSCEncoded $r.error)</p>" + $html }
    $recips = @($Schedule.recipients) | Where-Object { $_ }
    $mail   = Send-PSCMail -To $recips -Subject "PSConsole report: $title" -BodyHtml $html
    @{ ok = $r.ok; mailed = $mail.ok; rows = $rows.Count; error = $r.error; mailError = $mail.error; mailNote = $mail.note }
}

# Stamp a schedule with the outcome of a send (mutates in place).
function Set-ReportRunResult {
    param($Schedule, $Result, [datetime]$When = (Get-Date))
    $status = if ($Result.ok) { "success - $($Result.rows) row(s)" } else { "script error: $($Result.error)" }
    if (-not $Result.mailed) { $status += " | email NOT sent ($(if ($Result.mailError) { $Result.mailError } else { $Result.mailNote }))" }
    $Schedule | Add-Member -NotePropertyName lastRun    -NotePropertyValue $When.ToString('o') -Force
    $Schedule | Add-Member -NotePropertyName lastStatus -NotePropertyValue $status             -Force
}

# Dispatcher: called by the Pode schedule. Sends every due report and persists lastRun/lastStatus.
function Invoke-DueReports {
    $scheds = @(Get-ReportSchedules)
    if (-not $scheds.Count) { return }
    $now = Get-Date; $changed = $false
    foreach ($s in $scheds) {
        if (Test-ReportDue -Schedule $s -Now $now) {
            $res = Send-ScheduledReport -Schedule $s
            Set-ReportRunResult -Schedule $s -Result $res -When $now
            $changed = $true
        }
    }
    if ($changed) { Set-ReportSchedules $scheds }
}
