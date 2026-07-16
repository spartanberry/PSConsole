<#
.SYNOPSIS  Virtual machines with live CPU / memory usage, owner node and state.
.RUNEXAMPLE  State=Online
.CATEGORY  Hyper-V
.NOTES     Deliberately does NOT use the Hyper-V provider (root\virtualization\v2). That provider
           applies PER-VM authorization: a non-admin caller gets the host object and ZERO VMs, with no
           error - and Hyper-V has no read-only role, so reading it would require Hyper-V Administrators
           (full VM control incl. delete). Instead this joins two read-only sources:
             - root\MSCluster  (cluster Read role)          -> VM list, state, owner node
             - performance counters (Performance Monitor Users) -> vCPU, CPU%, RAM, memory pressure
           Neither can start, stop, modify, delete or migrate a VM.
           Cluster is the source of truth for the VM LIST because it includes powered-off VMs; perf
           counters only exist for VMs that are actually running.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param(
    [string]$State,   # optional filter on the cluster role state, e.g. Online
    [string]$VMName   # optional substring match
)
$cfgPath = if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'hyperv.config.json' }
           else { Join-Path $PSScriptRoot '..\..\data\hyperv.config.json' }
if (-not (Test-Path $cfgPath)) { throw "Hyper-V config not found at $cfgPath." }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$hosts = @($cfg.hosts | Where-Object { $_ })
if (-not $hosts.Count) { throw 'No Hyper-V hosts configured in hyperv.config.json.' }

function Convert-GroupState {
    # GROUP states. NOT the same enum as MSCluster_Resource, where 2 = Online.
    param([int]$Value)
    switch ($Value) { 0 { 'Online' } 1 { 'Offline' } 2 { 'Failed' } 3 { 'PartialOnline' } 4 { 'Pending' } default { "Unknown($Value)" } }
}

# ---- 1. VM list + state + owner, from the cluster (any surviving node answers for the whole cluster).
$groups = $null; $errs = New-Object System.Collections.Generic.List[string]
foreach ($h in $hosts) {
    try { $groups = @(Get-CimInstance -ComputerName $h -Namespace root\MSCluster -ErrorAction Stop `
                        -Query 'SELECT Name,State,OwnerNode,GroupType FROM MSCluster_ResourceGroup')
          break }
    catch { $errs.Add("${h}: $($_.Exception.Message)") }
}
if (-not $groups) { throw "Could not read the cluster via any configured host. $($errs -join ' | ')" }
$vmRoles = @($groups | Where-Object { [int]$_.GroupType -eq 111 })

# ---- 2. Live usage per host, from performance counters.
# Perf instance names are LOWERCASE ("PSCONSOLE01"), while the cluster reports the real casing
# ("PSCONSOLE01"), so every lookup key is lowercased.
$usage   = @{}
$perfErr = @{}
foreach ($h in $hosts) {
    try {
        $c = Get-Counter -ComputerName $h -ErrorAction Stop -Counter @(
            '\Hyper-V Dynamic Memory VM(*)\Physical Memory'
            '\Hyper-V Dynamic Memory VM(*)\Current Pressure'
            '\Hyper-V Hypervisor Virtual Processor(*)\% Total Run Time'
        )
        foreach ($s in $c.CounterSamples) {
            $inst = [string]$s.InstanceName
            if (-not $inst -or $inst -match '^_total') { continue }
            $path = [string]$s.Path
            if ($path -match 'hypervisor virtual processor') {
                # Instance is "vmname:Hv VP 0" - the VP rows give both the vCPU COUNT and the load.
                if ($inst -notmatch ':') { continue }
                $vm = ($inst -split ':')[0].ToLower()
                if (-not $usage.ContainsKey($vm)) { $usage[$vm] = @{ Host=$h; Cpu=New-Object System.Collections.Generic.List[double] } }
                $usage[$vm].Cpu.Add([double]$s.CookedValue)
            }
            else {
                $vm = $inst.ToLower()
                if (-not $usage.ContainsKey($vm)) { $usage[$vm] = @{ Host=$h; Cpu=New-Object System.Collections.Generic.List[double] } }
                $usage[$vm].Host = $h
                if ($path -match 'physical memory')   { $usage[$vm].MemMB    = [double]$s.CookedValue }
                if ($path -match 'current pressure')  { $usage[$vm].Pressure = [double]$s.CookedValue }
            }
        }
    }
    catch { $perfErr[$h] = $_.Exception.Message }
}

# ---- 3. Join. Cluster drives the rows; perf enriches the running ones.
$rows = New-Object System.Collections.Generic.List[object]
foreach ($g in $vmRoles) {
    $name = [string]$g.Name
    $u    = $usage[$name.ToLower()]
    $node = [string]$g.OwnerNode
    $note = ''
    if (-not $u -and $perfErr.ContainsKey($node)) { $note = "usage unavailable: $($perfErr[$node])" }
    $rows.Add([PSCustomObject]@{
        VM         = $name
        Node       = $node
        State      = Convert-GroupState ([int]$g.State)
        vCPU       = if ($u) { $u.Cpu.Count } else { $null }
        CpuPct     = if ($u -and $u.Cpu.Count) { [math]::Round((($u.Cpu | Measure-Object -Average).Average), 1) } else { $null }
        MemoryGB   = if ($u -and $u.MemMB) { [math]::Round($u.MemMB / 1024, 1) } else { $null }
        PressurePct= if ($u -and $null -ne $u.Pressure) { [int]$u.Pressure } else { $null }
        Note       = $note
    })
}
# Surface a host whose counters failed even if its VMs still listed from the cluster.
foreach ($h in $perfErr.Keys) {
    if (-not @($rows | Where-Object { $_.Node -eq $h }).Count) {
        $rows.Add([PSCustomObject]@{ VM=''; Node=$h; State=''; vCPU=$null; CpuPct=$null; MemoryGB=$null; PressurePct=$null; Note="usage unavailable: $($perfErr[$h])" })
    }
}

# .ToArray(): @() around a List[object] throws "Argument types do not match" under WinPS 5.1.
$out = $rows.ToArray()
if ($State)  { $out = @($out | Where-Object { $_.State -eq $State }) }
if ($VMName) { $out = @($out | Where-Object { $_.VM -like "*$VMName*" }) }
$out | Sort-Object Node, VM
