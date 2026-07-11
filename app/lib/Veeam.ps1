# Veeam.ps1 - OPTIONAL add-on: read-only Veeam Backup & Replication reporting.
#
# Config: data\veeam.config.json (helper: graph-setup\Set-VeeamConfig.ps1), shaped:
#   { "enabled": true, "server": "backupserver.example.org", "useSsl": false,
#     "username": "DOMAIN\\svc-veeamread", "secret": "<DPAPI>" }   # username/secret optional
#
# Queries run via PowerShell REMOTING into the Veeam server, where the Veeam PowerShell surface lives,
# so this host does NOT need the Veeam console installed. The account used (service account by default,
# or the configured credential) must be able to WinRM into the Veeam server and read VBR (e.g. a Veeam
# "Backup Viewer"/"Restore Operator" role). This is READ-ONLY reporting - no backup is started/changed.
#
# Verified against a live Veeam B&R 12 server: the "last run per job" view uses Get-VBRJob +
# FindLastSession() (fast, ~1s), and the N-day history uses the per-job session store
# [Veeam.Backup.Core.CBackupSession]::GetByJob() (fast, ~15s). The unfiltered Get-VBRBackupSession is
# deliberately avoided - it materialises the ENTIRE session history and takes minutes on busy servers.

function Get-VeeamConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'veeam.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\veeam.config.json' }
}

function Get-VeeamConfig {
    $p = Get-VeeamConfigPath
    if (-not (Test-Path $p)) { return $null }
    try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null }
}

function Test-VeeamConfigured {
    $c = Get-VeeamConfig
    return ([bool]$c -and [bool]$c.enabled -and [bool]$c.server)
}

function Get-VeeamCredential {
    param($Cfg)
    if (-not $Cfg -or -not $Cfg.username) { return $null }
    $pw = ''
    if ($Cfg.secret) {
        Add-Type -AssemblyName System.Security
        $pw = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$Cfg.secret), $null, 'LocalMachine'))
    }
    New-Object System.Management.Automation.PSCredential([string]$Cfg.username, (ConvertTo-SecureString $pw -AsPlainText -Force))
}

# Fetch Veeam job status from the last $Days days via remoting. Returns
#   @{ ok; error;
#      last    =@({ Job; Result; LastRun }, ...)              # most recent run per job (absolute latest)
#      sessions=@({ Job; Result; Start; End }, ...) }         # every run inside the window (all jobs)
# Aggregate counts (Get-VeeamJobHistory) and per-job run lists (Get-VeeamJobSessions) derive from sessions.
# Never throws - connection/permission problems come back as ok=$false with a message.
function Get-VeeamSessions {
    param([int]$Days = 30)
    $cfg = Get-VeeamConfig
    if (-not (Test-VeeamConfigured)) { return @{ ok = $false; error = 'Veeam is not configured (data\veeam.config.json).'; last = @(); sessions = @() } }

    # The Veeam.Backup.PowerShell module targets PowerShell 7, but the default WinRM endpoint is Windows
    # PowerShell 5.1 (where the module can't load - it needs SMA 7.x). Rather than require a PS7 remoting
    # endpoint on the Veeam server, we remote in (5.1) and shell out to pwsh.exe locally there; pwsh loads
    # the module, runs the two fast queries, and prints JSON, which we parse back here. Read-only throughout.
    $remote = {
        param($Days)
        $ErrorActionPreference = 'Stop'
        $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
        if (-not $pwsh) { foreach ($p in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "$env:ProgramW6432\PowerShell\7\pwsh.exe")) { if (Test-Path $p) { $pwsh = $p; break } } }
        if (-not $pwsh) { throw 'PowerShell 7 (pwsh.exe) not found on the Veeam server; the Veeam module requires it.' }
        # Inner script runs under pwsh 7 on the Veeam server (here-string keeps quotes literal).
        # "last" = each job's most recent session (FindLastSession, fast); "history" = per-job Success/
        # Warning/Failed counts over the window via the per-job session store (fast). We avoid the
        # unfiltered Get-VBRBackupSession, which walks all history and takes minutes.
        # The inner script catches its own errors and prints a clean {"__error__":"..."} JSON to STDOUT,
        # so a Veeam auth/permission failure surfaces as a readable message instead of raw CLIXML on stderr.
        $inner = @'
$ErrorActionPreference='Stop'; $WarningPreference='SilentlyContinue'
try {
  Import-Module Veeam.Backup.PowerShell -DisableNameChecking
  Connect-VBRServer -Server localhost -ErrorAction Stop | Out-Null
  $since=(Get-Date).AddDays(-1*__DAYS__)
  $jobs=@(Get-VBRJob)
  $last=@(foreach($j in $jobs){ $s=$null; try{$s=$j.FindLastSession()}catch{}; [PSCustomObject]@{ Job=[string]$j.Name; Result=$(if($s){[string]$s.Result}else{''}); LastRun=$(if($s -and $s.EndTime){$s.EndTime.ToString('o')}else{''}) } })
  $sessions=@(foreach($j in $jobs){
    $sess=@(); try{ $sess=@([Veeam.Backup.Core.CBackupSession]::GetByJob($j.Id)) }catch{}
    foreach($s in $sess){ if($s.EndTime -and $s.EndTime -ge $since){
      [PSCustomObject]@{ Job=[string]$j.Name; Result=[string]$s.Result; Start=$(if($s.CreationTime){$s.CreationTime.ToString('o')}else{''}); End=$s.EndTime.ToString('o') }
    } }
  })
  @{ last=@($last); sessions=@($sessions) } | ConvertTo-Json -Depth 4 -Compress
} catch {
  @{ __error__ = [string]$_.Exception.Message } | ConvertTo-Json -Compress
}
'@
        $inner = $inner -replace '__DAYS__', [string][int]$Days
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
        # Run pwsh as a HARD-BOUNDED child process (async reads so buffers can't deadlock; killed if it
        # overruns) so a slow/hung Veeam query can never hang the connection indefinitely.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $pwsh
        $psi.Arguments = "-NoProfile -NonInteractive -EncodedCommand $enc"
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(90000)) { try { $proc.Kill() } catch {}; throw 'Veeam query timed out on the Veeam server (took over 90s).' }
        $stdout = $outTask.Result.Trim(); $stderr = $errTask.Result.Trim()
        if (-not $stdout -and $stderr) { throw "Veeam query error on the server: $stderr" }
        $stdout
    }

    try {
        # WinRM waits a bit longer than the inner process bound so the inner timeout reports first.
        $ic = @{ ComputerName = [string]$cfg.server; ScriptBlock = $remote; ArgumentList = @($Days); ErrorAction = 'Stop'
                 SessionOption = (New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 120000 -CancelTimeout 5000) }
        $cred = Get-VeeamCredential -Cfg $cfg
        if ($cred) {
            $ic.Credential = $cred
            # CredSSP delegates the credential to the Veeam server so Connect-VBRServer's second hop to
            # the Veeam Identity service can authenticate - fixes "Failed to connect to Identity service"
            # for a service/reader account. Requires CredSSP enabled on BOTH this host (Role Client,
            # -DelegateComputer <veeam server>) and the Veeam server (Role Server).
            if ($cfg.useCredSsp) { $ic.Authentication = 'Credssp' }
        }
        if ($cfg.useSsl) { $ic.UseSSL = $true }
        $json = ("$(Invoke-Command @ic)").Trim()
        if (-not $json -or $json -eq 'null') { return @{ ok = $true; last = @(); sessions = @() } }
        try { $parsed = $json | ConvertFrom-Json } catch { return @{ ok = $false; error = "Unexpected response from Veeam server: $json"; last = @(); sessions = @() } }
        if ($parsed.__error__) { return @{ ok = $false; error = "Veeam: $([string]$parsed.__error__)"; last = @(); sessions = @() } }
        return @{ ok = $true; last = @($parsed.last); sessions = @($parsed.sessions) }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message; last = @(); sessions = @() }
    }
}

# Most recent session per job (the "last time it ran" quick view). Shaped server-side; sort here.
function Get-VeeamLastJobStatus {
    param($SessionResult)
    @(@($SessionResult.last) | Where-Object { $_ } | Sort-Object Job)
}

# Success/Warning/Failed counts per job over the fetched window (the aggregate N-day report), from sessions.
function Get-VeeamJobHistory {
    param($SessionResult)
    @(@($SessionResult.sessions) | Where-Object { $_ } | Group-Object Job | ForEach-Object {
        $g = @($_.Group)
        [PSCustomObject]@{
            Job     = $_.Name
            Success = @($g | Where-Object { "$($_.Result)" -eq 'Success' }).Count
            Warning = @($g | Where-Object { "$($_.Result)" -eq 'Warning' }).Count
            Failed  = @($g | Where-Object { "$($_.Result)" -eq 'Failed'  }).Count
            Total   = $g.Count
        }
    } | Sort-Object Job)
}

# Individual runs for ONE job inside the window, newest first, with a friendly duration (for the per-job view).
function Get-VeeamJobSessions {
    param($SessionResult, [string]$Job)
    @(@($SessionResult.sessions) | Where-Object { $_ -and $_.Job -eq $Job } | ForEach-Object {
        $dur = ''
        try { if ($_.Start -and $_.End) { $ts = [datetime]$_.End - [datetime]$_.Start; $dur = ('{0:0}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds) } } catch {}
        [PSCustomObject]@{ Result = [string]$_.Result; Start = $_.Start; End = $_.End; Duration = $dur }
    } | Sort-Object { try { [datetime]$_.End } catch { [datetime]::MinValue } } -Descending)
}

# --- Flat report rows (shared by the CSV export, the "email now" action, and the catalog report script) ---

# One row PER JOB: last result plus the window's Success/Warning/Failed/Total counts. This is the
# "all jobs" summary shape used for scheduled/emailed reports and the all-jobs CSV/email export.
function Get-VeeamReportRows {
    param($SessionResult)
    $hist = @{}
    foreach ($h in @(Get-VeeamJobHistory $SessionResult)) { $hist[[string]$h.Job] = $h }
    @(@(Get-VeeamLastJobStatus $SessionResult) | ForEach-Object {
        $h  = $hist[[string]$_.Job]
        $lr = ''
        try { if ($_.LastRun) { $lr = ([datetime]$_.LastRun).ToString('yyyy-MM-dd HH:mm') } } catch { $lr = [string]$_.LastRun }
        [PSCustomObject][ordered]@{
            Job           = [string]$_.Job
            'Last result' = [string]$_.Result
            'Last run'    = $lr
            Success       = if ($h) { [int]$h.Success } else { 0 }
            Warning       = if ($h) { [int]$h.Warning } else { 0 }
            Failed        = if ($h) { [int]$h.Failed  } else { 0 }
            Total         = if ($h) { [int]$h.Total   } else { 0 }
        }
    })
}

# Individual runs for ONE job in the window (the per-job CSV/email export shape).
function Get-VeeamJobReportRows {
    param($SessionResult, [string]$Job)
    @(@(Get-VeeamJobSessions $SessionResult -Job $Job) | ForEach-Object {
        $en = ''
        try { if ($_.End) { $en = ([datetime]$_.End).ToString('yyyy-MM-dd HH:mm') } } catch { $en = [string]$_.End }
        [PSCustomObject][ordered]@{ 'Run (ended)' = $en; Result = [string]$_.Result; Duration = [string]$_.Duration }
    })
}

# Scan recent Veeam sessions and email an alert for every NEW Failed/Warning session. Deduped via
# data\veeam-alerts.json (key = "Job|EndTime") so a given run alerts exactly once across polls. One
# email per invocation summarizes all new sessions. Best-effort; safe to run on a schedule. Requires
# the Veeam add-on configured AND smtp configured (Send-VeeamAlertNotification is a no-op otherwise).
# Returns @{ ok; new }.
function Send-VeeamJobAlerts {
    param([int]$Days = 3)
    if (-not (Test-VeeamConfigured)) { return @{ ok=$false; note='veeam not configured' } }
    $res = Get-VeeamSessions -Days $Days
    $sessions = @($res.sessions | Where-Object { $_ -and (("$($_.Result)" -eq 'Failed') -or ("$($_.Result)" -eq 'Warning')) })

    $statePath = Join-Path (Get-DataDir) 'veeam-alerts.json'
    $seen = @{}
    if (Test-Path $statePath) {
        try { @((Get-Content $statePath -Raw | ConvertFrom-Json).alerted) | Where-Object { $_ } | ForEach-Object { $seen["$_"] = $true } } catch {}
    }
    $new = @()
    foreach ($s in $sessions) {
        $key = "$($s.Job)|$($s.End)"
        if (-not $seen.ContainsKey($key)) { $new += $s; $seen[$key] = $true }
    }
    if ($new.Count) {
        Send-VeeamAlertNotification -Sessions $new | Out-Null
        # persist + prune keys whose session ended more than 30 days ago (parse End back from "Job|EndISO")
        $cut = (Get-Date).AddDays(-30)
        $keep = @($seen.Keys | Where-Object {
            $parts = "$_" -split '\|', 2
            $d = [datetime]::MinValue
            if ($parts.Count -eq 2 -and [datetime]::TryParse($parts[1], [ref]$d)) { $d -gt $cut } else { $true }
        })
        try { (@{ alerted = @($keep); updated = (Get-Date).ToString('o') } | ConvertTo-Json -Depth 4) | Set-Content -Path $statePath -Encoding UTF8 } catch {}
    }
    @{ ok=$true; new=$new.Count }
}
