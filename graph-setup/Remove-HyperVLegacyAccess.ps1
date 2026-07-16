<#
.SYNOPSIS
    ONE-TIME CLEANUP. Remove the now-unused root\virtualization\v2 WMI ACEs that an earlier version of
    Set-HyperVReadAccess.ps1 granted to PSConsole's service account.
    Run ON each host (HYPERV01 and HYPERV02), elevated, in Windows PowerShell 5.1.

.DESCRIPTION
    The original design read VMs from the Hyper-V provider (root\virtualization\v2). That turned out to
    be a dead end: the provider applies PER-VM authorization, so a non-admin sees the host object and
    ZERO VMs - no error, just an empty list. Seeing VMs there needs "Hyper-V Administrators", which is
    full VM control including delete.

    PSConsole no longer reads that provider at all. It gets the same picture from:
        VM list / state / owner node  <- root\MSCluster        (cluster "Read" role)
        vCPU / CPU% / RAM / pressure  <- performance counters  (Performance Monitor Users)

    So the v2 ACEs grant nothing and are pure attack surface. This removes them.

    SAFETY
      * Report-only by default. Nothing changes until you pass -Apply.
      * root\MSCluster is HARD-BLOCKED from removal - it is load-bearing. Removing it blanks the
        Hyper-V tab. The script refuses even if you name it explicitly.
      * Every removal is re-read and VERIFIED afterwards. rc=0 from SetSecurityDescriptor is NOT
        trusted on its own - it has been observed returning success having stored nothing.
      * Reversible: if anything does break, re-run .\Set-HyperVReadAccess.ps1 to restore the grants
        that are actually needed.

    MUST RUN LOCALLY. A security descriptor read over REMOTE WMI comes back structurally intact but
    with empty ACE fields - it looks like "no ACEs exist" and would make this script report nothing to
    do while ACEs are sitting right there. Do not try to run this against -ComputerName.

.EXAMPLE
    .\Remove-HyperVLegacyAccess.ps1            # report what would be removed (safe, read-only)
    .\Remove-HyperVLegacyAccess.ps1 -Apply     # actually remove

.NOTES
    Uses Get-WmiObject/Invoke-WmiMethod - Windows PowerShell 5.1 only, not pwsh.
    No WinRM restart needed; namespace ACLs take effect immediately.
    This script is a one-shot. Once both hosts report "nothing to remove", it can be deleted.
#>
[CmdletBinding()]
param(
    [string]$Account = 'example\zpsconsole',
    # Roots to clean. Child namespaces are walked too, because the old script granted on leaf
    # namespaces individually rather than relying on inheritance.
    [string[]]$Root = @('root\virtualization\v2'),
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'

# Namespaces PSConsole actively depends on. Removing an ACE here breaks the Hyper-V tab, so this list
# wins over anything passed in -Root.
$PROTECTED = @('root\mscluster')

if ($PSVersionTable.PSVersion.Major -ge 6) { throw "Run this in Windows PowerShell 5.1, not PowerShell $($PSVersionTable.PSVersion)." }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this elevated (Administrator).'
}

try { $sid = (New-Object System.Security.Principal.NTAccount($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value }
catch { throw "Cannot resolve '$Account' to a SID: $($_.Exception.Message)" }

Write-Host "Account : $Account" -ForegroundColor Cyan
Write-Host "SID     : $sid"     -ForegroundColor Cyan
Write-Host "Host    : $env:COMPUTERNAME (must be the Hyper-V host itself)" -ForegroundColor Cyan
Write-Host "Mode    : $(if($Apply){'APPLY - ACEs will be removed'}else{'REPORT ONLY - nothing will change'})" -ForegroundColor $(if ($Apply) { 'Yellow' } else { 'Green' })
Write-Host ''

# Walk a namespace tree. A missing root is normal and not an error - e.g. this box may never have had
# the Hyper-V role, or a previous run already cleaned it.
function Get-NamespaceTree {
    param([string]$Ns)
    $out = New-Object System.Collections.ArrayList
    try { $null = Get-WmiObject -Namespace $Ns -Class __Namespace -ErrorAction Stop }
    catch { Write-Host "  namespace not present, skipping: $Ns" -ForegroundColor DarkGray; return @() }
    $null = $out.Add($Ns)
    foreach ($child in (Get-WmiObject -Namespace $Ns -Class __Namespace -ErrorAction SilentlyContinue)) {
        foreach ($sub in (Get-NamespaceTree -Ns "$Ns\$($child.Name)")) { $null = $out.Add($sub) }
    }
    ,$out.ToArray()
}

$targets = New-Object System.Collections.ArrayList
foreach ($r in $Root) {
    if ($PROTECTED -contains $r.ToLower()) {
        Write-Warning "REFUSING to touch $r - PSConsole reads VM list/state/owner from it. Skipped."
        continue
    }
    foreach ($ns in (Get-NamespaceTree -Ns $r)) {
        if ($PROTECTED -contains $ns.ToLower()) { continue }
        $null = $targets.Add($ns)
    }
}

if (-not $targets.Count) {
    Write-Host ''
    Write-Host 'No candidate namespaces on this host - nothing to do.' -ForegroundColor Green
    return
}

$found = 0; $removed = 0; $failed = 0
foreach ($ns in $targets.ToArray()) {
    Write-Host ''
    Write-Host "--- $ns ---" -ForegroundColor Yellow

    # __SystemSecurity is a SINGLETON: address it by path. Get-WmiObject -Class __SystemSecurity returns
    # a bare ManagementObject with no GetSecurityDescriptor method.
    $p = @{ Namespace = $ns; Path = '__systemsecurity=@'; ErrorAction = 'Stop' }
    try { $res = Invoke-WmiMethod @p -Name GetSecurityDescriptor }
    catch { Write-Warning "  cannot open: $($_.Exception.Message)"; $failed++; continue }
    if ($res.ReturnValue -ne 0) { Write-Warning "  GetSecurityDescriptor failed (rc=$($res.ReturnValue))"; $failed++; continue }

    $sd  = $res.Descriptor
    $ace = @($sd.DACL | Where-Object { $_.Trustee.SIDString -eq $sid })
    if (-not $ace.Count) { Write-Host '  no ACE for this account - nothing to remove' -ForegroundColor DarkGray; continue }

    $found += $ace.Count
    foreach ($a in $ace) { Write-Host ("  FOUND ACE  mask=0x{0:X}  type={1}  flags={2}" -f $a.AccessMask, $a.AceType, $a.AceFlags) -ForegroundColor Magenta }
    if (-not $Apply) { Write-Host '  would remove (re-run with -Apply)' -ForegroundColor Cyan; continue }

    # Where-Object re-wraps each ACE in a PSObject; assigning those back throws a cast error, so unwrap
    # to the base objects and cast the array explicitly.
    $keep = @($sd.DACL | Where-Object { $_.Trustee.SIDString -ne $sid } | ForEach-Object { $_.psobject.immediateBaseObject })
    $sd.DACL = [System.Management.ManagementBaseObject[]]$keep

    $rc = (Invoke-WmiMethod @p -Name SetSecurityDescriptor -ArgumentList $sd -Confirm:$false).ReturnValue
    if ($rc -ne 0) { Write-Warning "  removal failed (rc=$rc)"; $failed++; continue }

    # Never trust rc=0 - prove it by re-reading.
    $chk = Invoke-WmiMethod @p -Name GetSecurityDescriptor
    if (@($chk.Descriptor.DACL | Where-Object { $_.Trustee.SIDString -eq $sid }).Count) {
        Write-Warning '  rc=0 but the ACE is STILL present on re-read - NOT removed'
        $failed++
    } else {
        Write-Host '  REMOVED + VERIFIED' -ForegroundColor Green
        $removed++
    }
}

Write-Host ''
Write-Host ('=' * 70) -ForegroundColor Cyan
if (-not $Apply) {
    Write-Host "REPORT ONLY. $found ACE(s) found across $($targets.Count) namespace(s). Nothing was changed." -ForegroundColor Cyan
    if ($found) { Write-Host 'Re-run with -Apply to remove them.' -ForegroundColor Cyan }
} else {
    Write-Host "Namespaces scanned: $($targets.Count)   ACEs found: $found   removed: $removed   failed: $failed" -ForegroundColor Cyan
}
Write-Host ''
Write-Host 'Untouched on purpose (all still required):' -ForegroundColor Cyan
Write-Host '  root\MSCluster ACE ....... VM list / state / owner node' -ForegroundColor DarkGray
Write-Host '  Performance Monitor Users  vCPU / CPU% / RAM / pressure' -ForegroundColor DarkGray
Write-Host '  WinRM WMI Provider ACE ... reaches root\MSCluster over WinRM' -ForegroundColor DarkGray
Write-Host '  WinRM RootSDDL ACE ....... ditto' -ForegroundColor DarkGray
Write-Host '  Cluster Read role ........ Grant-ClusterAccess (cluster-wide)' -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Now reload the Hyper-V tab in PSConsole. All 7 VMs should still list with usage.' -ForegroundColor Cyan
Write-Host 'If anything went dark, re-run .\Set-HyperVReadAccess.ps1 on this host to restore.' -ForegroundColor Cyan
