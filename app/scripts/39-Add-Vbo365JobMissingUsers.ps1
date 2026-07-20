<#
.SYNOPSIS Licensed M365 users who are NOT in a Veeam Backup for M365 job - and (with -Apply) add them to it.
.DESCRIPTION Finds licensed, enabled, Member users (real people) who are missing from the named job's user
    selection, so nobody licensed is left out of that job. PREVIEW by default (just lists them); pass -Apply to
    add them. Service/device/functional accounts are skipped via the shared exclusion list (Config > VB365
    backup-coverage alert > "Exclude these accounts"). Existing members are left untouched. Adding a user starts
    protecting them on the next run; it never removes anything.
.CATEGORY Veeam
.ROLE Admin
.RUNEXAMPLE -JobName "User Backup Job"
.RUNEXAMPLE -JobName "User Backup Job" -Apply
#>
[CmdletBinding()]
param([string]$JobName = 'User Backup Job', [switch]$Apply)

. (Join-Path $PSScriptRoot '..\lib\Store.ps1')
. (Join-Path $PSScriptRoot '..\lib\Veeam.ps1')
. (Join-Path $PSScriptRoot '..\lib\Vbo.ps1')
. (Join-Path $PSScriptRoot '..\lib\Graph.ps1')
if (-not (Test-VeeamConfigured)) { Write-Error 'Veeam/VB365 add-on is not configured (data\veeam.config.json).'; return }

# Shared service-account exclusion list (managed under the VB365 coverage-alert Config card).
$exclude = @()
try { $c = Get-Store config; if ($c -and $c.vboCoverageAlert -and $c.vboCoverageAlert.exclude) { $exclude = @($c.vboCoverageAlert.exclude) } } catch {}

$job = Get-VboJobBackupUsers -JobName $JobName
if (-not $job.ok) { Write-Error "VB365 query failed: $($job.error)"; return }
$jobIds = @{}; foreach ($u in @($job.users)) { if ($u.officeId) { $jobIds[[string]$u.officeId] = $true } }

$missing = New-Object System.Collections.Generic.List[object]
foreach ($g in @(Invoke-Graph '/users?$select=id,displayName,accountEnabled,userType,assignedLicenses&$top=999')) {
    if ("$($g.userType)" -ne 'Member' -or -not $g.accountEnabled -or @($g.assignedLicenses).Count -eq 0) { continue }
    $id = [string]$g.id
    if ($jobIds.ContainsKey($id)) { continue }                       # already in the job
    if ($exclude -contains [string]$g.displayName) { continue }        # excluded service/device account
    $missing.Add([pscustomobject]@{ id = $id; name = [string]$g.displayName })
}

if (-not $missing.Count) { [pscustomobject]@{ Action = 'nothing to add'; User = "(all licensed users are already in '$JobName')"; Error = '' }; return }

if (-not $Apply) {
    $missing | Sort-Object name | ForEach-Object { [pscustomobject]@{ Action = 'WOULD ADD'; User = $_.name; Error = '' } }
    [pscustomobject]@{ Action = "re-run with -Apply to add these $($missing.Count)"; User = ''; Error = '' }
    return
}

$add = Add-VboJobBackupUsers -JobName $JobName -OfficeIds @($missing | ForEach-Object { $_.id }) -Apply
if (-not $add.ok) { Write-Error "VB365 add failed: $($add.error)"; return }
@($add.results) | ForEach-Object { [pscustomobject]@{ Action = $_.status; User = $_.name; Error = $_.error } }
[pscustomobject]@{ Action = "selected users: $($add.selBefore) -> $($add.selAfter)"; User = ''; Error = '' }
