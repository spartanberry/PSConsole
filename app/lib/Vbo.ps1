# Vbo.ps1 - OPTIONAL add-on helper: Veeam Backup for Microsoft 365 (VB365). Reuses data\veeam.config.json
# (server + credential) because VB365 runs on the SAME server as VBR here. Remotes into that server (WinRM)
# and drives the Veeam.Archiver.PowerShell module - trying Windows PowerShell 5.1 first, falling back to
# pwsh 7 - the same way the VBR add-on does. Reads are read-only; the only write is Remove-VboJobBackupUsers,
# which removes selected users from a job (existing restore points are retained under retention).
#
# Depends on Veeam.ps1 (Get-VeeamConfig / Get-VeeamCredential / Test-VeeamConfigured).

# Run a VB365 inner script (single-quoted, self-contained, prints a JSON line; errors -> {"__error__":..}) on
# the Veeam/VB365 server. Returns @{ ok; error; data } - never throws.
function Invoke-VboRemote {
    param([Parameter(Mandatory)][string]$InnerText, [int]$TimeoutSec = 180)
    if (-not (Test-VeeamConfigured)) { return @{ ok = $false; error = 'Veeam/VB365 add-on is not configured (data\veeam.config.json).' } }
    $cfg = Get-VeeamConfig
    $remote = {
        param($InnerText, $TimeoutSec)
        $ErrorActionPreference = 'Stop'
        $can51 = $false
        try { Import-Module Veeam.Archiver.PowerShell -DisableNameChecking -ErrorAction Stop; $can51 = $true } catch {}
        if ($can51) { return (& ([scriptblock]::Create($InnerText))) }
        $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
        if (-not $pwsh) { foreach ($p in @("$env:ProgramFiles\PowerShell\7\pwsh.exe","$env:ProgramW6432\PowerShell\7\pwsh.exe")) { if (Test-Path $p) { $pwsh = $p; break } } }
        if (-not $pwsh) { return (@{ __error__ = 'Veeam.Archiver.PowerShell will not load in Windows PowerShell 5.1 and pwsh.exe was not found.' } | ConvertTo-Json -Compress) }
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($InnerText))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $pwsh; $psi.Arguments = "-NoProfile -NonInteractive -EncodedCommand $enc"
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $o = $proc.StandardOutput.ReadToEndAsync(); $e = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) { try { $proc.Kill() } catch {}; return (@{ __error__ = "VB365 query timed out (> $TimeoutSec s)." } | ConvertTo-Json -Compress) }
        $so = $o.Result.Trim(); $se = $e.Result.Trim()
        if (-not $so -and $se) { return (@{ __error__ = "pwsh error on server: $se" } | ConvertTo-Json -Compress) }
        return $so
    }
    $ic = @{ ComputerName = [string]$cfg.server; ScriptBlock = $remote; ArgumentList = @($InnerText, $TimeoutSec); ErrorAction = 'Stop'
             SessionOption = (New-PSSessionOption -OpenTimeout 15000 -OperationTimeout (($TimeoutSec + 30) * 1000) -CancelTimeout 5000) }
    $cred = Get-VeeamCredential -Cfg $cfg
    if ($cred) { $ic.Credential = $cred; if ($cfg.useCredSsp) { $ic.Authentication = 'Credssp' } }
    if ($cfg.useSsl) { $ic.UseSSL = $true }
    try {
        $out = ("$(Invoke-Command @ic)").Trim()
        if (-not $out) { return @{ ok = $false; error = 'Empty response from VB365 server.' } }
        $j = $out | ConvertFrom-Json
        if ($j.__error__) { return @{ ok = $false; error = [string]$j.__error__ } }
        return @{ ok = $true; data = $j }
    } catch { return @{ ok = $false; error = $_.Exception.Message } }
}

# All org users: @{ ok; error; users=@({ officeId; name; type; backedUp }) }. IsBackedUp = protected by any job.
function Get-VboOrgUsers {
    $inner = @'
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue'
try {
  Import-Module Veeam.Archiver.PowerShell -DisableNameChecking -ErrorAction Stop
  try { Connect-VBOServer -Server localhost -ErrorAction Stop | Out-Null } catch {}
  $org=@(Get-VBOOrganization)|Select-Object -First 1
  $out=@(foreach($u in @(Get-VBOOrganizationUser -Organization $org)){ @{ officeId=[string]$u.OfficeId; name=[string]$u.DisplayName; type=[string]$u.Type; backedUp=[bool]$u.IsBackedUp } })
  @{ ok=$true; users=$out } | ConvertTo-Json -Depth 5 -Compress
} catch { @{ __error__=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
    $r = Invoke-VboRemote -InnerText $inner -TimeoutSec 150
    if (-not $r.ok) { return @{ ok = $false; error = $r.error; users = @() } }
    @{ ok = $true; users = @($r.data.users) }
}

# Grouped errors/warnings across all VB365 jobs in the last N days, collapsed by normalized message pattern.
# @{ ok; error; jobCount; badSessions; detailRecords; rows=@({ Job; Severity; Pattern; Count }) }. Read-only.
function Get-VboJobErrors {
    param([int]$Days = 7)
    $inner = @'
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue'
try {
  Import-Module Veeam.Archiver.PowerShell -DisableNameChecking -ErrorAction Stop
  try { Connect-VBOServer -Server localhost -ErrorAction Stop | Out-Null } catch {}
  $since=(Get-Date).AddDays(-1*__DAYS__)
  $jobs=@(Get-VBOJob)
  $group=@{}; $bad=0; $detail=0
  foreach($j in $jobs){
    $sess=@(); try{ $sess=@(Get-VBOJobSession -Job $j) }catch{}
    foreach($s in $sess){
      $end=$null; try{ $end=[datetime]$s.EndTime }catch{}
      if($end -and $end -lt $since){ continue }
      if(("$($s.Status)") -notmatch 'Warn|Fail'){ continue }
      $bad++
      $recs=@(); try{ if($s.Log){ $recs=@($s.Log) } }catch{}
      foreach($lr in $recs){
        $t=[string]$lr.Title
        if(-not $t){ continue }
        $sev=''; if($t -match '^\s*\[(\w+)\]\s*'){ $sev=$Matches[1] }
        if($sev -notmatch '^(Warning|Error|Failed)$'){ continue }
        $msg=$t -replace '^\s*\[\w+\]\s*',''
        $detail++
        $norm=$msg
        $norm=$norm -replace '[\w.%+-]+@[\w.-]+\.\w+','<user>'
        $norm=$norm -replace 'https?://[^\s)]+','<url>'
        $norm=$norm -replace '\b[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\b','<guid>'
        $norm=$norm -replace '\bsite\s+.+?\s+\(<url>\)','site <name> (<url>)'
        $norm=$norm -replace '\d+','<n>'
        if($norm.Length -gt 200){ $norm=$norm.Substring(0,200) }
        $key=([string]$j.Name)+'|'+$sev+'|'+$norm
        if($group.ContainsKey($key)){ $group[$key].Count++ } else { $group[$key]=@{ Job=[string]$j.Name; Severity=$sev; Pattern=$norm; Count=1 } }
      }
    }
  }
  $rows=@($group.Values | ForEach-Object { [PSCustomObject]$_ })
  @{ ok=$true; jobCount=$jobs.Count; badSessions=$bad; detailRecords=$detail; rows=$rows } | ConvertTo-Json -Depth 5 -Compress
} catch { @{ __error__=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
    $inner = $inner -replace '__DAYS__', [string][int]$Days
    $r = Invoke-VboRemote -InnerText $inner -TimeoutSec 210
    if (-not $r.ok) { return @{ ok = $false; error = $r.error; rows = @() } }
    @{ ok = $true; jobCount = [int]$r.data.jobCount; badSessions = [int]$r.data.badSessions; detailRecords = [int]$r.data.detailRecords; rows = @($r.data.rows) }
}

# The users explicitly selected in a named job: @{ ok; error; users=@({ officeId; name }) }.
function Get-VboJobBackupUsers {
    param([Parameter(Mandatory)][string]$JobName)
    $inner = @'
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue'
try {
  Import-Module Veeam.Archiver.PowerShell -DisableNameChecking -ErrorAction Stop
  try { Connect-VBOServer -Server localhost -ErrorAction Stop | Out-Null } catch {}
  $job=@(Get-VBOJob)|Where-Object{ $_.Name -eq '__JOBNAME__' }|Select-Object -First 1
  if(-not $job){ @{ __error__='job not found: __JOBNAME__' } | ConvertTo-Json -Compress; return }
  $sel=@()
  foreach($it in @(Get-VBOBackupItem -Job $job)){
    $u=$null; foreach($p in 'User','Object'){ if($it.PSObject.Properties[$p] -and $it.$p){ $u=$it.$p; break } }
    if(-not $u){ continue }
    $oid=''; foreach($p in 'OfficeId','Id','ObjectId'){ if($u.PSObject.Properties[$p] -and $u.$p){ $oid=[string]$u.$p; break } }
    $nm='';  foreach($p in 'DisplayName','Name'){ if($u.PSObject.Properties[$p] -and $u.$p){ $nm=[string]$u.$p; break } }
    $sel+=@{ officeId=$oid; name=$nm }
  }
  @{ ok=$true; users=$sel } | ConvertTo-Json -Depth 5 -Compress
} catch { @{ __error__=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
    $inner = $inner -replace '__JOBNAME__', ($JobName -replace "'", "''")
    $r = Invoke-VboRemote -InnerText $inner -TimeoutSec 120
    if (-not $r.ok) { return @{ ok = $false; error = $r.error; users = @() } }
    @{ ok = $true; users = @($r.data.users) }
}

# Remove selected users (by Entra OfficeId) from a job. PREVIEW unless -Apply. Existing restore points kept.
# Returns @{ ok; error; jobName; selBefore; selAfter; targetCount; targets; applied; results }.
function Remove-VboJobBackupUsers {
    param([Parameter(Mandatory)][string]$JobName, [Parameter(Mandatory)][string[]]$OfficeIds, [switch]$Apply)
    $idsLiteral = '@(' + ((@($OfficeIds) | Where-Object { $_ } | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ')'
    $inner = @'
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue'
try {
  Import-Module Veeam.Archiver.PowerShell -DisableNameChecking -ErrorAction Stop
  try { Connect-VBOServer -Server localhost -ErrorAction Stop | Out-Null } catch {}
  $apply = (__APPLY__ -eq 1)
  $wanted = __IDS__
  $set=@{}; foreach($x in @($wanted)){ $set[[string]$x]=$true }
  $job=@(Get-VBOJob)|Where-Object{ $_.Name -eq '__JOBNAME__' }|Select-Object -First 1
  if(-not $job){ @{ __error__='job not found: __JOBNAME__' } | ConvertTo-Json -Compress; return }
  $items=@(Get-VBOBackupItem -Job $job)
  $targets=@()
  foreach($it in $items){
    $u=$null; foreach($p in 'User','Object'){ if($it.PSObject.Properties[$p] -and $it.$p){ $u=$it.$p; break } }
    if(-not $u){ continue }
    $oid=''; foreach($p in 'OfficeId','Id','ObjectId'){ if($u.PSObject.Properties[$p] -and $u.$p){ $oid=[string]$u.$p; break } }
    $nm='';  foreach($p in 'DisplayName','Name'){ if($u.PSObject.Properties[$p] -and $u.$p){ $nm=[string]$u.$p; break } }
    if($oid -and $set.ContainsKey($oid)){ $targets+=[PSCustomObject]@{ item=$it; id=$oid; name=$nm } }
  }
  $results=@()
  if($apply){
    foreach($t in @($targets)){
      try { Remove-VBOBackupItem -Job $job -BackupItem $t.item -ErrorAction Stop; $results+=@{ name=$t.name; id=$t.id; status='removed'; error='' } }
      catch { $results+=@{ name=$t.name; id=$t.id; status='FAILED'; error=[string]$_.Exception.Message } }
    }
  }
  $after=@(Get-VBOBackupItem -Job $job).Count
  @{ ok=$true; jobName=[string]$job.Name; selBefore=$items.Count; selAfter=$after; targetCount=@($targets).Count; targets=@($targets|ForEach-Object{ @{ name=$_.name; id=$_.id } }); applied=$apply; results=$results } | ConvertTo-Json -Depth 5 -Compress
} catch { @{ __error__=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
    $inner = $inner -replace '__JOBNAME__', ($JobName -replace "'", "''")
    $inner = $inner -replace '__IDS__', $idsLiteral
    $inner = $inner -replace '__APPLY__', [string][int]$Apply.IsPresent
    $r = Invoke-VboRemote -InnerText $inner -TimeoutSec 150
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $d = $r.data
    @{ ok = $true; jobName = [string]$d.jobName; selBefore = [int]$d.selBefore; selAfter = [int]$d.selAfter; targetCount = [int]$d.targetCount; targets = @($d.targets); applied = [bool]$d.applied; results = @($d.results) }
}

# Add users (by Entra OfficeId) to a job. PREVIEW unless -Apply. Skips users already in the job or not found
# in the org. Returns @{ ok; error; jobName; selBefore; selAfter; targetCount; targets; skipped; applied; results }.
function Add-VboJobBackupUsers {
    param([Parameter(Mandatory)][string]$JobName, [Parameter(Mandatory)][string[]]$OfficeIds, [switch]$Apply)
    $idsLiteral = '@(' + ((@($OfficeIds) | Where-Object { $_ } | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ')'
    $inner = @'
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue'
try {
  Import-Module Veeam.Archiver.PowerShell -DisableNameChecking -ErrorAction Stop
  try { Connect-VBOServer -Server localhost -ErrorAction Stop | Out-Null } catch {}
  $apply = (__APPLY__ -eq 1)
  $wanted = __IDS__
  $job=@(Get-VBOJob)|Where-Object{ $_.Name -eq '__JOBNAME__' }|Select-Object -First 1
  if(-not $job){ @{ __error__='job not found: __JOBNAME__' } | ConvertTo-Json -Compress; return }
  $org=@(Get-VBOOrganization)|Select-Object -First 1
  # org users by OfficeId (for New-VBOBackupItem -User)
  $byId=@{}; foreach($u in @(Get-VBOOrganizationUser -Organization $org)){ $oid=[string]$u.OfficeId; if($oid){ $byId[$oid]=$u } }
  # already-in-job ids
  $before=@(Get-VBOBackupItem -Job $job)
  $inJob=@{}; foreach($it in $before){ $iu=$null; foreach($p in 'User','Object'){ if($it.PSObject.Properties[$p] -and $it.$p){ $iu=$it.$p; break } }; if($iu){ $oid=[string]$iu.OfficeId; if($oid){ $inJob[$oid]=$true } } }
  $targets=@(); $skipped=@()
  foreach($id in @($wanted)){
    $id=[string]$id
    if($inJob.ContainsKey($id)){ $skipped+=@{ id=$id; reason='already in job' }; continue }
    $ou=$byId[$id]
    if(-not $ou){ $skipped+=@{ id=$id; reason='not found in org' }; continue }
    $targets+=[PSCustomObject]@{ id=$id; name=[string]$ou.DisplayName; user=$ou }
  }
  $results=@()
  if($apply){
    foreach($t in @($targets)){
      try { $item=New-VBOBackupItem -User $t.user; Add-VBOBackupItem -Job $job -BackupItem $item -ErrorAction Stop; $results+=@{ name=$t.name; id=$t.id; status='added'; error='' } }
      catch { $results+=@{ name=$t.name; id=$t.id; status='FAILED'; error=[string]$_.Exception.Message } }
    }
  }
  $after=@(Get-VBOBackupItem -Job $job).Count
  @{ ok=$true; jobName=[string]$job.Name; selBefore=@($before).Count; selAfter=$after; targetCount=@($targets).Count; targets=@($targets|ForEach-Object{ @{ name=$_.name; id=$_.id } }); skipped=@($skipped); applied=$apply; results=$results } | ConvertTo-Json -Depth 5 -Compress
} catch { @{ __error__=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
    $inner = $inner -replace '__JOBNAME__', ($JobName -replace "'", "''")
    $inner = $inner -replace '__IDS__', $idsLiteral
    $inner = $inner -replace '__APPLY__', [string][int]$Apply.IsPresent
    $r = Invoke-VboRemote -InnerText $inner -TimeoutSec 200
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $d = $r.data
    @{ ok = $true; jobName = [string]$d.jobName; selBefore = [int]$d.selBefore; selAfter = [int]$d.selAfter; targetCount = [int]$d.targetCount; targets = @($d.targets); skipped = @($d.skipped); applied = [bool]$d.applied; results = @($d.results) }
}

# VB365 job status in the SAME shape as Get-VeeamSessions (VBR), so the existing Veeam tab + SharePoint sync +
# report derivations (Get-VeeamReportRows / Get-VeeamDailyRows / Get-VeeamJobHistory) work on VB365 unchanged.
# Returns @{ ok; error; last=@({Job;Result;LastRun}); sessions=@({Job;Result;Start;End}) }. Never throws.
function Get-VboSessions {
    param([int]$Days = 8, [switch]$EnabledOnly)
    $eo = if ($EnabledOnly) { 1 } else { 0 }
    $inner = @'
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue'
try {
  Import-Module Veeam.Archiver.PowerShell -DisableNameChecking -ErrorAction Stop
  try { Connect-VBOServer -Server localhost -ErrorAction Stop | Out-Null } catch {}
  $since=(Get-Date).AddDays(-1*__DAYS__)
  $enabledOnly = (__EO__ -eq 1)
  $last=@(); $sessions=@()
  foreach($j in @(Get-VBOJob)){
    if($enabledOnly -and -not $j.IsEnabled){ continue }
    $sess=@(); try{ $sess=@(Get-VBOJobSession -Job $j) }catch{}
    $latest=@($sess | Sort-Object CreationTime -Descending | Select-Object -First 1)
    if($latest.Count){ $s=$latest[0]; $last+=@{ Job=[string]$j.Name; Result=[string]$s.Status; LastRun=$(if($s.EndTime -and [datetime]$s.EndTime -lt [datetime]'9999-01-01'){([datetime]$s.EndTime).ToString('o')}else{''}) } }
    foreach($s in $sess){
      $end=$null; try{ if($s.EndTime -and [datetime]$s.EndTime -lt [datetime]'9999-01-01'){ $end=[datetime]$s.EndTime } }catch{}
      if($end -and $end -ge $since){ $sessions+=@{ Job=[string]$j.Name; Result=[string]$s.Status; Start=$(if($s.CreationTime){([datetime]$s.CreationTime).ToString('o')}else{''}); End=$end.ToString('o') } }
    }
  }
  @{ ok=$true; last=@($last); sessions=@($sessions) } | ConvertTo-Json -Depth 5 -Compress
} catch { @{ __error__=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
    $inner = $inner -replace '__DAYS__', [string][int]$Days
    $inner = $inner -replace '__EO__', [string][int]$eo
    $r = Invoke-VboRemote -InnerText $inner -TimeoutSec 200
    if (-not $r.ok) { return @{ ok = $false; error = $r.error; last = @(); sessions = @() } }
    @{ ok = $true; last = @($r.data.last); sessions = @($r.data.sessions) }
}

# ---- Groups (parallel to the user functions; groups key on OfficeId + carry a Type: Office365/Security/Distribution) ----

# All org groups: @{ ok; error; groups=@({ officeId; name; type; backedUp }) }.
function Get-VboOrgGroups {
    $inner = @'
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue'
try {
  Import-Module Veeam.Archiver.PowerShell -DisableNameChecking -ErrorAction Stop
  try { Connect-VBOServer -Server localhost -ErrorAction Stop | Out-Null } catch {}
  $org=@(Get-VBOOrganization)|Select-Object -First 1
  $out=@(foreach($g in @(Get-VBOOrganizationGroup -Organization $org)){ @{ officeId=[string]$g.OfficeId; name=[string]$g.DisplayName; type=[string]$g.Type; backedUp=[bool]$g.IsBackedUp } })
  @{ ok=$true; groups=$out } | ConvertTo-Json -Depth 5 -Compress
} catch { @{ __error__=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
    $r = Invoke-VboRemote -InnerText $inner -TimeoutSec 200
    if (-not $r.ok) { return @{ ok = $false; error = $r.error; groups = @() } }
    @{ ok = $true; groups = @($r.data.groups) }
}

# Groups selected in a named job: @{ ok; error; groups=@({ officeId; name }) }.
function Get-VboJobGroups {
    param([Parameter(Mandatory)][string]$JobName)
    $inner = @'
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue'
try {
  Import-Module Veeam.Archiver.PowerShell -DisableNameChecking -ErrorAction Stop
  try { Connect-VBOServer -Server localhost -ErrorAction Stop | Out-Null } catch {}
  $job=@(Get-VBOJob)|Where-Object{ $_.Name -eq '__JOBNAME__' }|Select-Object -First 1
  if(-not $job){ @{ __error__='job not found: __JOBNAME__' } | ConvertTo-Json -Compress; return }
  $sel=@()
  foreach($it in @(Get-VBOBackupItem -Job $job)){
    $g=$null; foreach($p in 'Group','Object'){ if($it.PSObject.Properties[$p] -and $it.$p){ $g=$it.$p; break } }
    if(-not $g){ continue }
    $oid=[string]$g.OfficeId; $nm=[string]$g.DisplayName
    if($oid){ $sel+=@{ officeId=$oid; name=$nm } }
  }
  @{ ok=$true; groups=$sel } | ConvertTo-Json -Depth 5 -Compress
} catch { @{ __error__=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
    $inner = $inner -replace '__JOBNAME__', ($JobName -replace "'", "''")
    $r = Invoke-VboRemote -InnerText $inner -TimeoutSec 150
    if (-not $r.ok) { return @{ ok = $false; error = $r.error; groups = @() } }
    @{ ok = $true; groups = @($r.data.groups) }
}

# Remove groups (by OfficeId) from a job. PREVIEW unless -Apply. Existing restore points retained.
function Remove-VboJobGroups {
    param([Parameter(Mandatory)][string]$JobName, [Parameter(Mandatory)][string[]]$OfficeIds, [switch]$Apply)
    $idsLiteral = '@(' + ((@($OfficeIds) | Where-Object { $_ } | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ')'
    $inner = @'
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue'
try {
  Import-Module Veeam.Archiver.PowerShell -DisableNameChecking -ErrorAction Stop
  try { Connect-VBOServer -Server localhost -ErrorAction Stop | Out-Null } catch {}
  $apply = (__APPLY__ -eq 1)
  $wanted = __IDS__
  $set=@{}; foreach($x in @($wanted)){ $set[[string]$x]=$true }
  $job=@(Get-VBOJob)|Where-Object{ $_.Name -eq '__JOBNAME__' }|Select-Object -First 1
  if(-not $job){ @{ __error__='job not found: __JOBNAME__' } | ConvertTo-Json -Compress; return }
  $items=@(Get-VBOBackupItem -Job $job)
  $targets=@()
  foreach($it in $items){
    $g=$null; foreach($p in 'Group','Object'){ if($it.PSObject.Properties[$p] -and $it.$p){ $g=$it.$p; break } }
    if(-not $g){ continue }
    $oid=[string]$g.OfficeId
    if($oid -and $set.ContainsKey($oid)){ $targets+=[PSCustomObject]@{ item=$it; id=$oid; name=[string]$g.DisplayName } }
  }
  $results=@()
  if($apply){
    foreach($t in @($targets)){
      try { Remove-VBOBackupItem -Job $job -BackupItem $t.item -ErrorAction Stop; $results+=@{ name=$t.name; id=$t.id; status='removed'; error='' } }
      catch { $results+=@{ name=$t.name; id=$t.id; status='FAILED'; error=[string]$_.Exception.Message } }
    }
  }
  $after=@(Get-VBOBackupItem -Job $job).Count
  @{ ok=$true; jobName=[string]$job.Name; selBefore=@($items).Count; selAfter=$after; targetCount=@($targets).Count; targets=@($targets|ForEach-Object{ @{ name=$_.name; id=$_.id } }); applied=$apply; results=$results } | ConvertTo-Json -Depth 5 -Compress
} catch { @{ __error__=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
    $inner = $inner -replace '__JOBNAME__', ($JobName -replace "'", "''")
    $inner = $inner -replace '__IDS__', $idsLiteral
    $inner = $inner -replace '__APPLY__', [string][int]$Apply.IsPresent
    $r = Invoke-VboRemote -InnerText $inner -TimeoutSec 200
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $d = $r.data
    @{ ok = $true; jobName = [string]$d.jobName; selBefore = [int]$d.selBefore; selAfter = [int]$d.selAfter; targetCount = [int]$d.targetCount; targets = @($d.targets); applied = [bool]$d.applied; results = @($d.results) }
}

# Add groups (by OfficeId) to a job. PREVIEW unless -Apply. Skips already-in-job / not-found.
function Add-VboJobGroups {
    param([Parameter(Mandatory)][string]$JobName, [Parameter(Mandatory)][string[]]$OfficeIds, [switch]$Apply)
    $idsLiteral = '@(' + ((@($OfficeIds) | Where-Object { $_ } | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ')'
    $inner = @'
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue'
try {
  Import-Module Veeam.Archiver.PowerShell -DisableNameChecking -ErrorAction Stop
  try { Connect-VBOServer -Server localhost -ErrorAction Stop | Out-Null } catch {}
  $apply = (__APPLY__ -eq 1)
  $wanted = __IDS__
  $job=@(Get-VBOJob)|Where-Object{ $_.Name -eq '__JOBNAME__' }|Select-Object -First 1
  if(-not $job){ @{ __error__='job not found: __JOBNAME__' } | ConvertTo-Json -Compress; return }
  $org=@(Get-VBOOrganization)|Select-Object -First 1
  $byId=@{}; foreach($g in @(Get-VBOOrganizationGroup -Organization $org)){ $oid=[string]$g.OfficeId; if($oid){ $byId[$oid]=$g } }
  $before=@(Get-VBOBackupItem -Job $job)
  $inJob=@{}; foreach($it in $before){ $ig=$null; foreach($p in 'Group','Object'){ if($it.PSObject.Properties[$p] -and $it.$p){ $ig=$it.$p; break } }; if($ig){ $oid=[string]$ig.OfficeId; if($oid){ $inJob[$oid]=$true } } }
  $targets=@(); $skipped=@()
  foreach($id in @($wanted)){
    $id=[string]$id
    if($inJob.ContainsKey($id)){ $skipped+=@{ id=$id; reason='already in job' }; continue }
    $og=$byId[$id]
    if(-not $og){ $skipped+=@{ id=$id; reason='not found in org' }; continue }
    $targets+=[PSCustomObject]@{ id=$id; name=[string]$og.DisplayName; grp=$og }
  }
  $results=@()
  if($apply){
    foreach($t in @($targets)){
      try { $item=New-VBOBackupItem -Group $t.grp; Add-VBOBackupItem -Job $job -BackupItem $item -ErrorAction Stop; $results+=@{ name=$t.name; id=$t.id; status='added'; error='' } }
      catch { $results+=@{ name=$t.name; id=$t.id; status='FAILED'; error=[string]$_.Exception.Message } }
    }
  }
  $after=@(Get-VBOBackupItem -Job $job).Count
  @{ ok=$true; jobName=[string]$job.Name; selBefore=@($before).Count; selAfter=$after; targetCount=@($targets).Count; targets=@($targets|ForEach-Object{ @{ name=$_.name; id=$_.id } }); skipped=@($skipped); applied=$apply; results=$results } | ConvertTo-Json -Depth 5 -Compress
} catch { @{ __error__=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
    $inner = $inner -replace '__JOBNAME__', ($JobName -replace "'", "''")
    $inner = $inner -replace '__IDS__', $idsLiteral
    $inner = $inner -replace '__APPLY__', [string][int]$Apply.IsPresent
    $r = Invoke-VboRemote -InnerText $inner -TimeoutSec 200
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $d = $r.data
    @{ ok = $true; jobName = [string]$d.jobName; selBefore = [int]$d.selBefore; selAfter = [int]$d.selAfter; targetCount = [int]$d.targetCount; targets = @($d.targets); skipped = @($d.skipped); applied = [bool]$d.applied; results = @($d.results) }
}
