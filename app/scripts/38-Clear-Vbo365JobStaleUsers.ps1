<#
.SYNOPSIS Remove stale users from a Veeam Backup for M365 job - deleted accounts, or offboarded (unlicensed +
    disabled) regular users. PREVIEW by default; pass -Apply to actually remove.
.DESCRIPTION Walks the named job's selected users and flags two safe-to-remove kinds: (1) DELETED from Entra
    (no longer exist), and (2) UNLICENSED AND DISABLED regular users (VB365 Type=User + Graph userType=Member)
    - i.e. offboarded people. Shared/resource/public mailboxes and service accounts are never targeted.
    Removing a user from the job stops future backup attempts but KEEPS existing restore points (retention).
    Runs the removal under the veeam.config account (which needs the VB365 Administrator/Operator role).
.CATEGORY Veeam
.ROLE Admin
.RUNEXAMPLE -JobName "User Backup Job"
.RUNEXAMPLE -JobName "User Backup Job" -Apply
#>
[CmdletBinding()]
param([string]$JobName = 'User Backup Job', [switch]$Apply)

. (Join-Path $PSScriptRoot '..\lib\Veeam.ps1')
. (Join-Path $PSScriptRoot '..\lib\Vbo.ps1')
. (Join-Path $PSScriptRoot '..\lib\Graph.ps1')
if (-not (Test-VeeamConfigured)) { Write-Error 'Veeam/VB365 add-on is not configured (data\veeam.config.json).'; return }

$ju = Get-VboJobBackupUsers -JobName $JobName
if (-not $ju.ok) { Write-Error "VB365 query failed: $($ju.error)"; return }

# VB365 org-user type map (to exclude shared/resource/public mailboxes from the 'regular user' rule).
$ou = Get-VboOrgUsers
$orgType = @{}
if ($ou.ok) { foreach ($u in @($ou.users)) { if ($u.officeId) { $orgType[[string]$u.officeId] = [string]$u.type } } }

$gmap = @{}
foreach ($g in @(Invoke-Graph '/users?$select=id,assignedLicenses,accountEnabled,userType&$top=999')) {
    $gmap[[string]$g.id] = @{ lic = @($g.assignedLicenses).Count; enabled = [bool]$g.accountEnabled; utype = [string]$g.userType }
}

$targets = New-Object System.Collections.Generic.List[object]
foreach ($j in @($ju.users)) {
    $oid = [string]$j.officeId
    if (-not $oid) { continue }
    $vbType = [string]$orgType[$oid]
    if (-not $gmap.ContainsKey($oid)) {
        $targets.Add([pscustomobject]@{ User = $j.name; Reason = 'Deleted from Entra'; Id = $oid }); continue
    }
    $g = $gmap[$oid]
    if ($g.lic -eq 0 -and (-not $g.enabled) -and $g.utype -eq 'Member' -and $vbType -eq 'User') {
        $targets.Add([pscustomobject]@{ User = $j.name; Reason = 'Unlicensed + disabled'; Id = $oid })
    }
}

if (-not $targets.Count) { [pscustomobject]@{ Action = 'nothing to clean'; User = "(no stale users in '$JobName')"; Reason = '' }; return }

if (-not $Apply) {
    $targets | Sort-Object Reason, User | ForEach-Object { [pscustomobject]@{ Action = 'WOULD REMOVE'; User = $_.User; Reason = $_.Reason } }
    [pscustomobject]@{ Action = "re-run with -Apply to remove these $($targets.Count)"; User = ''; Reason = '' }
    return
}

$rm = Remove-VboJobBackupUsers -JobName $JobName -OfficeIds @($targets | ForEach-Object { $_.Id }) -Apply
if (-not $rm.ok) { Write-Error "VB365 removal failed: $($rm.error)"; return }
$reasonById = @{}; foreach ($t in $targets) { $reasonById[[string]$t.Id] = $t.Reason }
@($rm.results) | ForEach-Object { [pscustomobject]@{ Action = $_.status; User = $_.name; Reason = $reasonById[[string]$_.id]; Error = $_.error } }
[pscustomobject]@{ Action = "selected users: $($rm.selBefore) -> $($rm.selAfter)"; User = ''; Reason = ''; Error = '' }
