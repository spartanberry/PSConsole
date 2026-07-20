<#
.SYNOPSIS Remove groups from a Group Backup Job that don't belong - deleted groups, and (optionally) content-less
    Security/Distribution groups. PREVIEW by default; -Apply removes.
.DESCRIPTION -Scope Stale (default) removes only groups that no longer exist in the org (deleted M365 groups + old
    on-prem/synced AD groups) - they can't be backed up and cause "group not found" warnings. -Scope All also
    removes valid Security and Distribution groups (they have no mailbox/site/Teams content), leaving an
    Office365-only job. Existing restore points are retained. PREVIEW unless -Apply.
.CATEGORY Veeam
.ROLE Admin
.RUNEXAMPLE -JobName "Group Backup Job" -Scope Stale
.RUNEXAMPLE -JobName "Group Backup Job" -Scope All -Apply
#>
[CmdletBinding()]
param([string]$JobName = 'Group Backup Job', [ValidateSet('Stale','All')][string]$Scope = 'Stale', [switch]$Apply)

. (Join-Path $PSScriptRoot '..\lib\Veeam.ps1')
. (Join-Path $PSScriptRoot '..\lib\Vbo.ps1')
if (-not (Test-VeeamConfigured)) { Write-Error 'Veeam/VB365 add-on is not configured (data\veeam.config.json).'; return }

$job = Get-VboJobGroups -JobName $JobName
if (-not $job.ok) { Write-Error "VB365 query failed: $($job.error)"; return }
$org = Get-VboOrgGroups
if (-not $org.ok) { Write-Error "VB365 query failed: $($org.error)"; return }
$orgType = @{}; foreach ($g in @($org.groups)) { if ($g.officeId) { $orgType[[string]$g.officeId] = [string]$g.type } }

$targets = New-Object System.Collections.Generic.List[object]
foreach ($jg in @($job.groups)) {
    $id = [string]$jg.officeId
    if (-not $orgType.ContainsKey($id)) { $targets.Add([pscustomobject]@{ id = $id; name = [string]$jg.name; reason = 'Deleted (no longer exists)' }); continue }
    if ($Scope -eq 'All' -and $orgType[$id] -ne 'Office365') { $targets.Add([pscustomobject]@{ id = $id; name = [string]$jg.name; reason = "Non-Office365 ($($orgType[$id]))" }) }
}

if (-not $targets.Count) { [pscustomobject]@{ Action = 'nothing to remove'; Group = "(no $Scope groups to remove from '$JobName')"; Reason = '' }; return }

if (-not $Apply) {
    $targets | Sort-Object reason, name | ForEach-Object { [pscustomobject]@{ Action = 'WOULD REMOVE'; Group = $_.name; Reason = $_.reason } }
    [pscustomobject]@{ Action = "re-run with -Apply to remove these $($targets.Count) ($Scope)"; Group = ''; Reason = '' }
    return
}

$rm = Remove-VboJobGroups -JobName $JobName -OfficeIds @($targets | ForEach-Object { $_.id }) -Apply
if (-not $rm.ok) { Write-Error "VB365 removal failed: $($rm.error)"; return }
$reasonById = @{}; foreach ($t in $targets) { $reasonById[[string]$t.id] = $t.reason }
@($rm.results) | ForEach-Object { [pscustomobject]@{ Action = $_.status; Group = $_.name; Reason = $reasonById[[string]$_.id]; Error = $_.error } }
[pscustomobject]@{ Action = "job groups: $($rm.selBefore) -> $($rm.selAfter)"; Group = ''; Reason = ''; Error = '' }
