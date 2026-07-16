<#
.SYNOPSIS
    Grant PSConsole's service account the READ-ONLY access it needs on a Hyper-V host.
    Run ON each host (HYPERV01 and HYPERV02), elevated, in Windows PowerShell 5.1.

.DESCRIPTION
    Hyper-V has NO read-only role. Its own provider (root\virtualization\v2) applies PER-VM
    authorization: a non-admin sees the host object and ZERO VMs, with no error. Seeing VMs there
    would require "Hyper-V Administrators", which is FULL VM control including delete - unacceptable
    for a web app's service account. So PSConsole never reads that provider. It gets the same picture
    from two genuinely read-only sources instead:

      VM list / state / owner node  <- root\MSCluster        (cluster "Read" role)
      vCPU / CPU% / RAM / pressure  <- performance counters  (Performance Monitor Users)

    This script grants the per-host half:
      1. BUILTIN\Performance Monitor Users  - lets Get-Counter read Hyper-V perf counters remotely.
                                              No VM control, no shell, no WMI. This is what supplies
                                              all VM resource usage.
      2. WinRM "WMI Provider" plugin ACE    - THE gate that silently blocks everything else. Default is
                                              O:NSG:BAD:P(A;;GA;;;BA)(A;;GA;;;IU)(A;;GA;;;RM): only
                                              Administrators / Interactive / Remote Management Users may
                                              reach WMI over WinRM, and it rejects the caller BEFORE any
                                              namespace ACL is consulted. Needed for root\MSCluster.
                                              NOT done via the "Remote Management Users" group, because
                                              the microsoft.powershell plugin grants that same group GA -
                                              which would hand the service account a REMOTE SHELL here.
      3. root\MSCluster namespace ACL       - Enable + Remote Enable (read) on the cluster namespace.
      4. WinRM RootSDDL                     - Read+Execute on the WinRM service itself.

    The CLUSTER half is separate and cluster-wide, so it is done ONCE from either node, not by this
    script:
        Grant-ClusterAccess -User <account> -ReadOnly      (revoke: Remove-ClusterAccess -User <account>)

    Nothing here can start, stop, create, delete or migrate a VM, or open a shell on the host.

.EXAMPLE
    .\Set-HyperVReadAccess.ps1 -WhatIf     # show what would change
    .\Set-HyperVReadAccess.ps1             # grant
    .\Set-HyperVReadAccess.ps1 -Remove     # revoke everything this granted

.NOTES
    Uses Get-WmiObject/Invoke-WmiMethod - Windows PowerShell 5.1 only, not pwsh.
    A WinRM restart is required for the plugin ACE to take effect; the script does it for you.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Account = 'example\zpsconsole',
    [string[]]$Namespace = @('root\MSCluster'),
    [switch]$Remove,
    [switch]$SkipWinRM
)
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -ge 6) { throw "Run this in Windows PowerShell 5.1, not PowerShell $($PSVersionTable.PSVersion)." }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this elevated (Administrator).'
}

$ntAccount = New-Object System.Security.Principal.NTAccount($Account)
$sid    = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
$sidObj = New-Object System.Security.Principal.SecurityIdentifier($sid)
$short  = ($Account -split '\\')[-1]
$domain = if ($Account -match '\\') { ($Account -split '\\')[0] } else { $env:USERDOMAIN }

Write-Host "Account : $Account"  -ForegroundColor Cyan
Write-Host "SID     : $sid"      -ForegroundColor Cyan
Write-Host "Host    : $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "Mode    : $(if($Remove){'REVOKE'}else{'GRANT'})" -ForegroundColor Cyan
Write-Host ''

# ---------- 1. Performance Monitor Users (this is what delivers VM resource usage) ----------
Write-Host '--- BUILTIN\Performance Monitor Users ---' -ForegroundColor Yellow
try {
    $grp = [ADSI]"WinNT://./Performance Monitor Users,group"
    $members = @($grp.Invoke('Members') | ForEach-Object { ([ADSI]$_).InvokeGet('Name') })
    $isMember = $members -contains $short
    if ($Remove) {
        if (-not $isMember) { Write-Host '  not a member - nothing to revoke' -ForegroundColor DarkGray }
        elseif ($PSCmdlet.ShouldProcess('Performance Monitor Users', "remove $Account")) {
            $grp.Remove("WinNT://$domain/$short,user"); Write-Host '  REMOVED' -ForegroundColor Green
        }
    }
    elseif ($isMember) { Write-Host '  already a member - no change' -ForegroundColor DarkGray }
    elseif ($PSCmdlet.ShouldProcess('Performance Monitor Users', "add $Account")) {
        $grp.Add("WinNT://$domain/$short,user"); Write-Host '  ADDED (perf counters only - no VM control, no shell)' -ForegroundColor Green
    }
} catch { Write-Warning "  failed: $($_.Exception.Message)" }

# ---------- 2. WinRM "WMI Provider" plugin ACE (the gate that blocks WMI-over-WinRM) ----------
Write-Host ''
Write-Host '--- WinRM "WMI Provider" plugin ---' -ForegroundColor Yellow
$pluginChanged = $false
try {
    $mask = 0xA0000000   # GENERIC_READ | GENERIC_EXECUTE. Deliberately not GENERIC_ALL.
    foreach ($res in (Get-ChildItem 'WSMan:\localhost\Plugin\WMI Provider\Resources' -ErrorAction Stop)) {
        $uri     = (Get-Item "$($res.PSPath)\ResourceUri").Value
        $secNode = Get-ChildItem "$($res.PSPath)\Security" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $secNode) { Write-Host "  (no Security node, RootSDDL applies): $uri" -ForegroundColor DarkGray; continue }
        $sddlItem = Get-ChildItem $secNode.PSPath | Where-Object Name -eq 'Sddl'
        $csd = New-Object System.Security.AccessControl.CommonSecurityDescriptor($false, $false, $sddlItem.Value)
        $has = @($csd.DiscretionaryAcl | Where-Object { $_.SecurityIdentifier -eq $sidObj }).Count -gt 0
        if ($Remove) {
            if (-not $has) { continue }
            $csd.DiscretionaryAcl.RemoveAccessSpecific([System.Security.AccessControl.AccessControlType]::Allow, $sidObj, $mask, 'None', 'None')
        }
        elseif ($has) { Write-Host "  already granted: $uri" -ForegroundColor DarkGray; continue }
        else { $csd.DiscretionaryAcl.AddAccess([System.Security.AccessControl.AccessControlType]::Allow, $sidObj, $mask, 'None', 'None') }
        if ($PSCmdlet.ShouldProcess($uri, "$(if($Remove){'remove'}else{'grant'}) WinRM Read+Execute for $Account")) {
            Set-Item "$($secNode.PSPath)\Sddl" -Value ($csd.GetSddlForm('All')) -Force
            $pluginChanged = $true
            Write-Host "  $(if($Remove){'REVOKED'}else{'GRANTED'}): $uri" -ForegroundColor Green
        }
    }
} catch { Write-Warning "  failed: $($_.Exception.Message)" }

# ---------- 3. WMI namespace ACLs ----------
# 0x1 = WBEM_ENABLE ("Enable Account"), 0x20 = WBEM_REMOTE_ENABLE ("Remote Enable"). Read-only pair.
$READ_MASK = 0x1 -bor 0x20
foreach ($ns in $Namespace) {
    Write-Host ''
    Write-Host "--- namespace $ns ---" -ForegroundColor Yellow
    # __SystemSecurity is a SINGLETON: address it by path and use Invoke-WmiMethod. Get-WmiObject
    # -Class __SystemSecurity returns a bare ManagementObject with no methods.
    # -WhatIf:$false because Invoke-WmiMethod honours -WhatIf itself and would SKIP this READ.
    $invokeParams = @{ Namespace = $ns; Path = '__systemsecurity=@'; ErrorAction = 'Stop' }
    try { $res = Invoke-WmiMethod @invokeParams -Name GetSecurityDescriptor -WhatIf:$false }
    catch { Write-Warning "  cannot open $ns : $($_.Exception.Message)"; continue }
    if ($res.ReturnValue -ne 0) { Write-Warning "  GetSecurityDescriptor failed (rc=$($res.ReturnValue))"; continue }
    $sd = $res.Descriptor
    $existing = @($sd.DACL | Where-Object { $_.Trustee.SIDString -eq $sid })

    if ($Remove) {
        if (-not $existing.Count) { Write-Host '  no ACE - nothing to revoke' -ForegroundColor DarkGray; continue }
        # Where-Object re-wraps each ACE in a PSObject; assigning that back throws a cast error.
        $keep = @($sd.DACL | Where-Object { $_.Trustee.SIDString -ne $sid } | ForEach-Object { $_.psobject.immediateBaseObject })
        $sd.DACL = [System.Management.ManagementBaseObject[]]$keep
        if ($PSCmdlet.ShouldProcess($ns, "remove ACE for $Account")) {
            $rc = (Invoke-WmiMethod @invokeParams -Name SetSecurityDescriptor -ArgumentList $sd -Confirm:$false).ReturnValue
            if ($rc -ne 0) { Write-Warning "  failed (rc=$rc)"; continue }
            $chk = Invoke-WmiMethod @invokeParams -Name GetSecurityDescriptor -WhatIf:$false
            if (-not @($chk.Descriptor.DACL | Where-Object { $_.Trustee.SIDString -eq $sid }).Count) { Write-Host '  REVOKED + VERIFIED' -ForegroundColor Green }
            else { Write-Warning '  rc=0 but the ACE is STILL present on re-read' }
        }
        continue
    }

    if ($existing | Where-Object { ($_.AccessMask -band $READ_MASK) -eq $READ_MASK -and $_.AceType -eq 0 }) {
        Write-Host '  already granted - no change' -ForegroundColor DarkGray; continue
    }
    # .psobject.immediateBaseObject is ESSENTIAL: CreateInstance() returns a PSObject wrapper, and
    # appending that to $sd.DACL makes SetSecurityDescriptor return rc=0 having stored the UNCHANGED
    # descriptor - a grant that reports success and does nothing.
    $trustee = ([WMIClass]'\\.\root\cimv2:Win32_Trustee').CreateInstance()
    $trustee.SIDString = $sid
    $ace = ([WMIClass]'\\.\root\cimv2:Win32_ACE').CreateInstance()
    $ace.Trustee    = $trustee.psobject.immediateBaseObject
    $ace.AccessMask = $READ_MASK
    $ace.AceType    = 0
    $ace.AceFlags   = 2      # CONTAINER_INHERIT_ACE
    $sd.DACL += $ace.psobject.immediateBaseObject
    if ($PSCmdlet.ShouldProcess($ns, "grant Enable+RemoteEnable (read) to $Account")) {
        $rc = (Invoke-WmiMethod @invokeParams -Name SetSecurityDescriptor -ArgumentList $sd -Confirm:$false).ReturnValue
        if ($rc -ne 0) { Write-Warning "  failed (rc=$rc)"; continue }
        # Never trust rc=0 here - re-read and prove it.
        $chk = Invoke-WmiMethod @invokeParams -Name GetSecurityDescriptor -WhatIf:$false
        if (@($chk.Descriptor.DACL | Where-Object { $_.Trustee.SIDString -eq $sid -and ($_.AccessMask -band $READ_MASK) -eq $READ_MASK }).Count) {
            Write-Host '  GRANTED + VERIFIED Enable Account + Remote Enable (read-only)' -ForegroundColor Green
        } else { Write-Warning '  rc=0 but the ACE is NOT present on re-read - grant did NOT apply' }
    }
}

# ---------- 4. WinRM RootSDDL ----------
if (-not $SkipWinRM) {
    Write-Host ''
    Write-Host '--- WinRM RootSDDL ---' -ForegroundColor Yellow
    $path = 'WSMan:\localhost\Service\RootSDDL'
    $cur  = (Get-Item $path).Value
    $csd  = New-Object System.Security.AccessControl.CommonSecurityDescriptor($false, $false, $cur)
    $mask = 0xA0000000
    $has  = @($csd.DiscretionaryAcl | Where-Object { $_.SecurityIdentifier -eq $sidObj -and $_.AceType -eq 'AccessAllowed' }).Count -gt 0
    if ($Remove -and $has) {
        $csd.DiscretionaryAcl.RemoveAccessSpecific([System.Security.AccessControl.AccessControlType]::Allow, $sidObj, $mask, 'None', 'None')
        if ($PSCmdlet.ShouldProcess($path, "remove WinRM ACE for $Account")) { Set-Item $path -Value ($csd.GetSddlForm('All')) -Force; $pluginChanged = $true; Write-Host '  REVOKED' -ForegroundColor Green }
    }
    elseif ($Remove) { Write-Host '  no ACE - nothing to revoke' -ForegroundColor DarkGray }
    elseif ($has)    { Write-Host '  already granted - no change' -ForegroundColor DarkGray }
    else {
        $csd.DiscretionaryAcl.AddAccess([System.Security.AccessControl.AccessControlType]::Allow, $sidObj, $mask, 'None', 'None')
        if ($PSCmdlet.ShouldProcess($path, "grant WinRM Read+Execute to $Account")) { Set-Item $path -Value ($csd.GetSddlForm('All')) -Force; $pluginChanged = $true; Write-Host '  GRANTED' -ForegroundColor Green }
    }
}

if ($pluginChanged -and $PSCmdlet.ShouldProcess('WinRM', 'restart to apply plugin/SDDL changes')) {
    Write-Host ''
    Write-Host 'Restarting WinRM to apply the plugin/SDDL change ...' -ForegroundColor Cyan
    Restart-Service WinRM -Force
    Write-Host "WinRM: $((Get-Service WinRM).Status)" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Per-host grants done. Remember the CLUSTER half (run ONCE from either node):' -ForegroundColor Cyan
Write-Host "    Grant-ClusterAccess -User '$Account' -ReadOnly" -ForegroundColor Cyan
Write-Host "    (revoke: Remove-ClusterAccess -User '$Account')" -ForegroundColor Cyan
Write-Host 'Then load the Hyper-V tab in PSConsole - it runs as the service account.' -ForegroundColor Cyan
