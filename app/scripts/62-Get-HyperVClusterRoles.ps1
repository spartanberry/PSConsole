<#
.SYNOPSIS  Clustered roles (VMs and cluster groups) with their owner node and state.
.RUNEXAMPLE  ProblemsOnly=true
.CATEGORY  Hyper-V
.NOTES     Pure CIM against root\MSCluster - no FailoverClusters module needed on this host.
           Shows VM-to-node placement cluster-wide from a single query, plus any resource that is
           not Online. -ProblemsOnly is the one to schedule/alert on.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param(
    [switch]$ProblemsOnly
)
$cfgPath = if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'hyperv.config.json' }
           else { Join-Path $PSScriptRoot '..\..\data\hyperv.config.json' }
if (-not (Test-Path $cfgPath)) { throw "Hyper-V config not found at $cfgPath." }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$hosts = @($cfg.hosts | Where-Object { $_ })
if (-not $cfg.cluster) { throw 'No cluster configured in hyperv.config.json (standalone hosts - use the VM inventory instead).' }

# CAREFUL: these two enums collide. For a GROUP, 2 = Failed. For a RESOURCE, 2 = Online. Using one
# map for both would report every healthy resource as Failed (or every failed group as Online).
function Convert-GroupState {
    param([int]$Value)
    switch ($Value) { 0 { 'Online' } 1 { 'Offline' } 2 { 'Failed' } 3 { 'PartialOnline' } 4 { 'Pending' } default { "Unknown($Value)" } }
}
function Convert-ResourceState {
    param([int]$Value)
    switch ($Value) { 0 { 'Inherited' } 1 { 'Initializing' } 2 { 'Online' } 3 { 'Offline' } 4 { 'Failed' } default { "Unknown($Value)" } }
}

$groups = $null; $resources = @(); $errs = New-Object System.Collections.Generic.List[string]
foreach ($h in $hosts) {
    try {
        $groups    = @(Get-CimInstance -ComputerName $h -Namespace root\MSCluster -ErrorAction Stop `
                        -Query 'SELECT Name,State,OwnerNode,GroupType FROM MSCluster_ResourceGroup')
        $resources = @(Get-CimInstance -ComputerName $h -Namespace root\MSCluster -ErrorAction Stop `
                        -Query 'SELECT Name,State,Type,OwnerNode,OwnerGroup FROM MSCluster_Resource')
        break
    }
    catch { $errs.Add("${h}: $($_.Exception.Message)") }
}
if (-not $groups) { throw "Could not reach the cluster via any configured host. $($errs -join ' | ')" }

$rows = New-Object System.Collections.Generic.List[object]
foreach ($g in $groups) {
    $state = Convert-GroupState ([int]$g.State)
    $mine  = @($resources | Where-Object { [string]$_.OwnerGroup -eq [string]$g.Name })
    # Roll the group's non-Online resources up into a note, so a "PartialOnline" role says WHY.
    $bad = @($mine | Where-Object { [int]$_.State -ne 2 } |
             ForEach-Object { "$($_.Name)=$(Convert-ResourceState ([int]$_.State))" })
    $rows.Add([PSCustomObject]@{
        Role      = [string]$g.Name
        Type      = if ([int]$g.GroupType -eq 111) { 'VirtualMachine' } else { "Cluster($($g.GroupType))" }
        OwnerNode = [string]$g.OwnerNode
        State     = $state
        Resources = $mine.Count
        Problems  = ($bad -join ', ')
    })
}

# .ToArray(): wrapping a List[object] in @() throws "Argument types do not match" under WinPS 5.1.
$out = $rows.ToArray()
if ($ProblemsOnly) {
    # An EMPTY group reporting Offline is the normal resting state - "Available Storage" sits Offline
    # whenever no disks are unassigned. Alerting on that would fire forever and train people to
    # ignore this report, so an Offline group with zero resources is not a problem. An offline group
    # that actually holds resources still is.
    $out = @($out | Where-Object {
        ($_.State -ne 'Online' -and -not ($_.State -eq 'Offline' -and $_.Resources -eq 0)) -or $_.Problems
    })
}
$out | Sort-Object @{ Expression = { $_.Type -ne 'VirtualMachine' } }, OwnerNode, Role
