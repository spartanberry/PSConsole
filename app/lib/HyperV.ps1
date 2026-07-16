# HyperV.ps1 - add-on gate + helpers for the Hyper-V / failover-cluster read-only integration.
# Mirrors the Unifi/Veeam/Intune add-on pattern: the whole feature stays dormant (hidden scripts,
# hidden nav tab, 403 on the route) until data\hyperv.config.json exists and is enabled.
#
# Unlike Veeam/UniFi/Intune there is NO secret here. Hyper-V and the cluster are read over CIM using
# the service account's own Windows identity (integrated auth), so nothing needs DPAPI-encrypting.
# That access is NOT granted by default - run graph-setup\Set-HyperVReadAccess.ps1 on each host once.

function Get-HyperVConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'hyperv.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\hyperv.config.json' }
}
function Get-HyperVConfig {
    $p = Get-HyperVConfigPath
    if (-not (Test-Path $p)) { return $null }
    try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null }
}
function Test-HyperVConfigured {
    $c = Get-HyperVConfig
    if (-not $c -or -not $c.enabled) { return $false }
    return (@($c.hosts).Count -gt 0)
}
# The Hyper-V hosts to query. Callers should tolerate one host being down - a dead node must degrade
# the report, not fail it.
function Get-HyperVHostList {
    $c = Get-HyperVConfig
    if (-not $c) { return @() }
    @($c.hosts | Where-Object { $_ })
}
# Cluster name (optional). Blank = standalone hosts, so cluster-scoped reports should say so rather
# than erroring.
function Get-HyperVClusterName {
    $c = Get-HyperVConfig
    if (-not $c) { return '' }
    [string]$c.cluster
}

# ---- VM migration (the ONLY write path in this add-on) --------------------------------------------
# Ships DORMANT: migrationEnabled must be set true in data\hyperv.config.json. Same guard rail as user
# provisioning - the code can exist, deployed and reviewable, without being able to touch anything.
function Test-HyperVMigrationEnabled {
    $c = Get-HyperVConfig
    [bool]($c -and $c.enabled -and $c.migrationEnabled)
}

# Live VM roles + their current owner, straight from the cluster. Used to VALIDATE a migration request
# against reality rather than trusting whatever the browser posted.
function Get-HyperVVmRoles {
    $errs = New-Object System.Collections.Generic.List[string]
    foreach ($h in (Get-HyperVHostList)) {
        try {
            $g = @(Get-CimInstance -ComputerName $h -Namespace root\MSCluster -ErrorAction Stop `
                     -Query 'SELECT Name,State,OwnerNode,GroupType FROM MSCluster_ResourceGroup')
            return @($g | Where-Object { [int]$_.GroupType -eq 111 } | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.Name; OwnerNode = [string]$_.OwnerNode; State = [int]$_.State }
            })
        } catch { $errs.Add("${h}: $($_.Exception.Message)") }
    }
    throw "Could not read cluster roles. $($errs -join ' | ')"
}
function Get-HyperVClusterNodeNames {
    foreach ($h in (Get-HyperVHostList)) {
        try { return @(Get-CimInstance -ComputerName $h -Namespace root\MSCluster -ErrorAction Stop -Query 'SELECT Name FROM MSCluster_Node' | ForEach-Object { [string]$_.Name }) }
        catch { }
    }
    @()
}

# List every VM checkpoint across the hosts, AS THE OPERATOR. Checkpoints live in the Hyper-V provider
# (root\virtualization\v2), which only "Hyper-V Administrators" can read - and that role is full VM
# control including delete, which the read-only service account must never have. So this reads them on
# demand under the operator's OWN credentials instead: no standing access, nothing privileged stored.
#
# Queries EVERY host (each sees only its own VMs, so all must be asked and the results aggregated),
# tolerating a dead/unreachable host. Dates and sizes are formatted ON THE HOST and returned as strings
# and longs - a raw DateTime would hit the WinPS 5.1 ConvertTo-Json /Date(ms)/ trap in the JSON response.
function Get-HyperVCheckpoints {
    param(
        [Parameter(Mandatory)][string]$OperatorUser,
        [Parameter(Mandatory)][string]$OperatorPassword
    )
    $sec  = ConvertTo-SecureString $OperatorPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($OperatorUser, $sec)
    $all  = New-Object System.Collections.Generic.List[object]
    $errs = New-Object System.Collections.Generic.List[string]
    foreach ($h in (Get-HyperVHostList)) {
        try {
            $r = Invoke-Command -ComputerName $h -Credential $cred -ErrorAction Stop -ScriptBlock {
                Import-Module Hyper-V -ErrorAction Stop
                $out = New-Object System.Collections.Generic.List[object]
                foreach ($s in (Get-VM | Get-VMSnapshot -ErrorAction SilentlyContinue)) {
                    # Best-effort footprint: the differencing-disk (.avhdx) size(s) for this checkpoint.
                    # Not a perfect "reclaimable space" figure (chained checkpoints share ancestry), but a
                    # true, directional signal of which old checkpoint is eating disk. Blank if unreadable.
                    $size = 0; $sizeOk = $true
                    try {
                        foreach ($d in (Get-VMHardDiskDrive -VMSnapshot $s -ErrorAction Stop)) {
                            if ($d.Path -and (Test-Path $d.Path)) { $size += (Get-Item $d.Path -ErrorAction Stop).Length }
                        }
                    } catch { $sizeOk = $false }
                    $age = [int]([math]::Floor(((Get-Date) - $s.CreationTime).TotalDays))
                    $out.Add([pscustomobject]@{
                        VM        = [string]$s.VMName
                        Id        = [string]$s.Id      # stable GUID - removal targets THIS, not the name (names can collide)
                        Name      = [string]$s.Name
                        Created   = $s.CreationTime.ToString('MM/dd/yyyy h:mm tt')
                        AgeDays   = $age
                        SizeBytes = [long]$size
                        SizeKnown = $sizeOk
                        Type      = [string]$s.SnapshotType
                    })
                }
                $out.ToArray()
            }
            foreach ($item in @($r)) { $all.Add($item) }
        }
        catch { $errs.Add("${h}: $($_.Exception.Message)") }
    }
    # All hosts failed (typically bad credentials) -> a real failure. Some failed -> partial, still useful.
    if ($all.Count -eq 0 -and $errs.Count -gt 0) { return @{ ok = $false; data = @(); error = ($errs -join ' | ') } }
    @{ ok = $true; data = $all.ToArray(); error = ($errs -join ' | ') }
}

# Delete ONE checkpoint, AS THE OPERATOR. Read-only service account can't do this (needs Hyper-V rights),
# so the operator's own credentials are used - same model as migration. Targets the checkpoint by its
# GUID Id, never by name: snapshot names can collide, and an Id can only ever match the one intended
# checkpoint. VM name + Id are passed as ARGUMENTS, never interpolated into the scriptblock.
#
# A clustered VM runs on exactly one node, so we ask each host until we find the VM: 'vmHere' false ->
# wrong node, keep looking; 'vmHere' true but the snapshot gone -> already removed, stop and say so.
function Remove-HyperVCheckpoint {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$CheckpointId,
        [Parameter(Mandatory)][string]$OperatorUser,
        [Parameter(Mandatory)][string]$OperatorPassword
    )
    $sec  = ConvertTo-SecureString $OperatorPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($OperatorUser, $sec)
    $lastErr = ''
    foreach ($h in (Get-HyperVHostList)) {
        try {
            $r = Invoke-Command -ComputerName $h -Credential $cred -ErrorAction Stop `
                    -ArgumentList $VMName, $CheckpointId -ScriptBlock {
                param($vm, $id)
                Import-Module Hyper-V -ErrorAction Stop
                $v = Get-VM -Name $vm -ErrorAction SilentlyContinue
                if (-not $v) { return [pscustomobject]@{ vmHere = $false; found = $false; name = '' } }
                $snap = $v | Get-VMSnapshot -ErrorAction SilentlyContinue | Where-Object { [string]$_.Id -eq $id }
                if (-not $snap) { return [pscustomobject]@{ vmHere = $true; found = $false; name = '' } }
                $name = [string]$snap.Name
                $snap | Remove-VMSnapshot -Confirm:$false -ErrorAction Stop
                [pscustomobject]@{ vmHere = $true; found = $true; name = $name }
            }
            if ($r.vmHere) {
                if ($r.found) { return @{ ok = $true; name = [string]$r.name; via = $h; error = '' } }
                return @{ ok = $false; name = ''; via = $h; error = "That checkpoint no longer exists on '$VMName' - it may have already been removed. Re-list to refresh." }
            }
        }
        catch { $lastErr = $_.Exception.Message }
    }
    $err = if ($lastErr) { $lastErr } else { "VM '$VMName' was not found on any Hyper-V host." }
    @{ ok = $false; name = ''; via = ''; error = $err }
}

# Move a clustered VM to another node, AS THE OPERATOR. The service account is deliberately read-only
# and cannot do this - the caller supplies their own credentials per request, so every migration is
# performed and attributable as a real person.
#
# Runs Move-ClusterVirtualMachineRole ON a cluster node via PS remoting: the FailoverClusters module
# lives there, not on this host, and an admin operator passes the microsoft.powershell plugin ACL.
# VM/node names are passed as ARGUMENTS, never interpolated into the scriptblock, so a crafted name
# cannot become code on the host.
function Invoke-HyperVMigration {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$TargetNode,
        [Parameter(Mandatory)][string]$OperatorUser,
        [Parameter(Mandatory)][string]$OperatorPassword,
        [ValidateSet('Live', 'Quick')][string]$MigrationType = 'Live'
    )
    $sec  = ConvertTo-SecureString $OperatorPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($OperatorUser, $sec)
    $lastErr = 'no cluster node was reachable'
    foreach ($h in (Get-HyperVHostList)) {
        try {
            $r = Invoke-Command -ComputerName $h -Credential $cred -ErrorAction Stop `
                    -ArgumentList $VMName, $TargetNode, $MigrationType -ScriptBlock {
                param($vm, $node, $type)
                Import-Module FailoverClusters -ErrorAction Stop
                $g = Move-ClusterVirtualMachineRole -Name $vm -Node $node -MigrationType $type -ErrorAction Stop
                [pscustomobject]@{ Owner = [string]$g.OwnerNode; State = [string]$g.State }
            }
            return @{ ok = $true; owner = [string]$r.Owner; state = [string]$r.State; via = $h; error = '' }
        }
        catch { $lastErr = $_.Exception.Message }
    }
    @{ ok = $false; owner = ''; state = ''; via = ''; error = $lastErr }
}
