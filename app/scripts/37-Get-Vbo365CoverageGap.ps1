<#
.SYNOPSIS Licensed Microsoft 365 users who are NOT protected by any Veeam Backup for M365 job (coverage gap).
.DESCRIPTION Cross-references VB365's org users (IsBackedUp flag) against Microsoft Graph license status, and
    lists LICENSED, Member users that no VB365 job is backing up - i.e. real active people whose data is
    unprotected. Excludes guests, unlicensed accounts, and service/shared mailboxes (they're expected to be
    unprotected). Read-only. Appears in Scheduled reports, so it can be emailed on a schedule as an alert.
.CATEGORY Veeam
.ROLE Admin
.RUNEXAMPLE (no parameters)
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\lib\Veeam.ps1')
. (Join-Path $PSScriptRoot '..\lib\Vbo.ps1')
. (Join-Path $PSScriptRoot '..\lib\Graph.ps1')
if (-not (Test-VeeamConfigured)) { Write-Error 'Veeam/VB365 add-on is not configured (data\veeam.config.json).'; return }

$r = Get-VboOrgUsers
if (-not $r.ok) { Write-Error "VB365 query failed: $($r.error)"; return }

$gmap = @{}
foreach ($g in @(Invoke-Graph '/users?$select=id,assignedLicenses,accountEnabled,userType&$top=999')) {
    $gmap[[string]$g.id] = @{ lic = @($g.assignedLicenses).Count; enabled = [bool]$g.accountEnabled; utype = [string]$g.userType }
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($u in @($r.users)) {
    if ($u.backedUp) { continue }
    $oid = [string]$u.officeId
    if (-not $gmap.ContainsKey($oid)) { continue }     # not in Graph = deleted, not a coverage gap
    $g = $gmap[$oid]
    if ($g.lic -gt 0 -and $g.utype -eq 'Member') {
        $rows.Add([pscustomobject]@{ User = $u.name; VB365Type = $u.type; Enabled = $g.enabled; Licenses = $g.lic })
    }
}

if (-not $rows.Count) { [pscustomobject]@{ User = '(all licensed users are protected by a VB365 job)'; VB365Type = ''; Enabled = ''; Licenses = '' }; return }
$rows | Sort-Object @{ e = { -not $_.Enabled } }, User
