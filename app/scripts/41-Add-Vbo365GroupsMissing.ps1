<#
.SYNOPSIS Office365 groups that exist in the org but are NOT in a Group Backup Job - and (with -Apply) add them.
.DESCRIPTION Only Office365 (Microsoft 365) groups are considered, because they're the group type that actually
    has content to protect (group mailbox, SharePoint site, Teams). Security and Distribution groups are ignored
    (no content). PREVIEW by default; -Apply adds the missing Office365 groups to the job.
.CATEGORY Veeam
.ROLE Admin
.RUNEXAMPLE -JobName "Group Backup Job"
.RUNEXAMPLE -JobName "Group Backup Job" -Apply
#>
[CmdletBinding()]
param([string]$JobName = 'Group Backup Job', [switch]$Apply)

. (Join-Path $PSScriptRoot '..\lib\Veeam.ps1')
. (Join-Path $PSScriptRoot '..\lib\Vbo.ps1')
if (-not (Test-VeeamConfigured)) { Write-Error 'Veeam/VB365 add-on is not configured (data\veeam.config.json).'; return }

$org = Get-VboOrgGroups
if (-not $org.ok) { Write-Error "VB365 query failed: $($org.error)"; return }
$job = Get-VboJobGroups -JobName $JobName
if (-not $job.ok) { Write-Error "VB365 query failed: $($job.error)"; return }
$jobIds = @{}; foreach ($g in @($job.groups)) { if ($g.officeId) { $jobIds[[string]$g.officeId] = $true } }

$missing = New-Object System.Collections.Generic.List[object]
foreach ($g in @($org.groups)) {
    if ("$($g.type)" -ne 'Office365') { continue }
    $id = [string]$g.officeId
    if ($jobIds.ContainsKey($id)) { continue }
    $missing.Add([pscustomobject]@{ id = $id; name = [string]$g.name })
}

if (-not $missing.Count) { [pscustomobject]@{ Action = 'nothing to add'; Group = "(all Office365 groups are already in '$JobName')" }; return }

if (-not $Apply) {
    $missing | Sort-Object name | ForEach-Object { [pscustomobject]@{ Action = 'WOULD ADD'; Group = $_.name } }
    [pscustomobject]@{ Action = "re-run with -Apply to add these $($missing.Count)"; Group = '' }
    return
}

$add = Add-VboJobGroups -JobName $JobName -OfficeIds @($missing | ForEach-Object { $_.id }) -Apply
if (-not $add.ok) { Write-Error "VB365 add failed: $($add.error)"; return }
@($add.results) | ForEach-Object { [pscustomobject]@{ Action = $_.status; Group = $_.name; Error = $_.error } }
[pscustomobject]@{ Action = "job groups: $($add.selBefore) -> $($add.selAfter)"; Group = ''; Error = '' }
