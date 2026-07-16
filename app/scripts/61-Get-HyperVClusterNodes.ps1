<#
.SYNOPSIS  Failover cluster nodes, their state, and how many VM roles each currently owns.
.RUNEXAMPLE  (no parameters)
.CATEGORY  Hyper-V
.NOTES     Pure CIM against root\MSCluster - no FailoverClusters module needed on this host.
           Queries whichever configured host answers first: cluster data is cluster-wide, so asking
           a surviving node is exactly what you want when a node is down.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param()
$cfgPath = if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'hyperv.config.json' }
           else { Join-Path $PSScriptRoot '..\..\data\hyperv.config.json' }
if (-not (Test-Path $cfgPath)) { throw "Hyper-V config not found at $cfgPath." }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$hosts = @($cfg.hosts | Where-Object { $_ })
if (-not $cfg.cluster) { throw 'No cluster configured in hyperv.config.json (standalone hosts - use the VM inventory instead).' }

# MSCluster_Node.State. NOTE this enum is NOT the same as MSCluster_Resource.State, where 2 means
# Online - here 2 means Paused. Never share one mapping across the cluster classes.
function Convert-NodeState {
    param([int]$Value)
    switch ($Value) { 0 { 'Up' } 1 { 'Down' } 2 { 'Paused' } 3 { 'Joining' } default { "Unknown($Value)" } }
}

$nodes = $null; $groups = @(); $used = ''; $errs = New-Object System.Collections.Generic.List[string]
foreach ($h in $hosts) {
    try {
        $nodes  = @(Get-CimInstance -ComputerName $h -Namespace root\MSCluster -ErrorAction Stop `
                     -Query 'SELECT Name,State,NodeWeight,DynamicWeight FROM MSCluster_Node')
        $groups = @(Get-CimInstance -ComputerName $h -Namespace root\MSCluster -ErrorAction Stop `
                     -Query 'SELECT Name,State,OwnerNode,GroupType FROM MSCluster_ResourceGroup')
        $used = $h
        break
    }
    catch { $errs.Add("${h}: $($_.Exception.Message)") }
}
if (-not $nodes) { throw "Could not reach the cluster via any configured host. $($errs -join ' | ')" }

# GroupType 111 = VirtualMachine. Counting only those keeps "roles owned" meaningful - the cluster's
# own groups (Cluster Group, Available Storage) are not workload.
$vmCount = @{}
foreach ($g in $groups) { if ([int]$g.GroupType -eq 111 -and $g.OwnerNode) { $n = [string]$g.OwnerNode; $vmCount[$n] = 1 + [int]$vmCount[$n] } }

$nodes | ForEach-Object {
    [PSCustomObject]@{
        Cluster       = [string]$cfg.cluster
        Node          = [string]$_.Name
        State         = Convert-NodeState ([int]$_.State)
        VMRolesOwned  = [int]$vmCount[[string]$_.Name]
        NodeWeight    = [int]$_.NodeWeight
        DynamicWeight = [int]$_.DynamicWeight
        QueriedVia    = $used
    }
} | Sort-Object Node
