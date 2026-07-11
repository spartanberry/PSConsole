<#
.SYNOPSIS
    Idempotent setup of a gMSA-run scheduled task that triggers Entra Connect (ADSync)
    delta syncs on the Domain Controller / Entra Connect server.

.DESCRIPTION
    Creates a group Managed Service Account (gMSA) with NO stored password (AD-managed,
    auto-rotated, retrievable only by this host), grants it the ability to trigger ADSync
    (local ADSyncOperators group), deploys a small runner, and registers a scheduled task
    that runs as the gMSA on a repeating interval. Because the gMSA has no stored password,
    this survives the CIS L2 hardening setting "Network access: Do not allow storage of
    passwords and credentials for network authentication" (DisableDomainCreds=1) that
    otherwise breaks "run whether logged on or not" tasks with
    "a specified logon session does not exist".

    Safe to re-run: every step checks state first.

.MANUAL STEP (REQUIRED - cannot be scripted safely on a DC)
    The gMSA needs the "Log on as a batch job" user right. On this DC that right is
    controlled by GPO, and the *** CIS Domain Controller L2 *** GPO explicitly sets it to
    Administrators ONLY (SeBatchLogonRight = *S-1-5-32-544). GPO user-rights are REPLACE,
    not merge, and CIS L2 out-ranks the Default Domain Controllers Policy, so the grant MUST
    go into the CIS L2 GPO (or a GPO linked with higher precedence), NOT the Default Domain
    Controllers Policy.

      GPMC -> edit "CIS Domain Controller L2"
        -> Computer Configuration -> Policies -> Windows Settings -> Security Settings
        -> Local Policies -> User Rights Assignment -> "Log on as a batch job"
        -> ADD  <NETBIOS>\gmsa-adsync$  (keep the existing Administrators entry)
      then on the DC:  gpupdate /force

    Run THIS script FIRST (it creates the gMSA object the GPO picker needs to resolve),
    then do the GPO grant, then test with Start-ScheduledTask.

.NOTES
    Run ON THE DC (the Entra Connect server), elevated, as Domain Admin.
#>
[CmdletBinding()]
param(
    [string]$AccountName     = 'gmsa-adsync',
    # DNSHostName must be UNIQUE to the gMSA (drives its auto-created HOST/ SPNs). Do NOT use the
    # DC's own FQDN or you create a duplicate SPN -> Install fails "provided context did not match
    # the target". Use the account's own name.
    [string]$DnsHostName     = "$AccountName.$env:USERDNSDOMAIN",        # e.g. gmsa-adsync.example.org
    [int]   $IntervalMinutes = 5,                                        # 5 = effectively "automatic after Phase 1"
    [string]$RunnerDir       = 'C:\Scripts',
    [string]$TaskName        = 'ADSync-DeltaSync'
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$netbios   = (Get-ADDomain).NetBIOSName
$memberRef = "$netbios\$AccountName`$"               # e.g. example\gmsa-adsync$
$thisHost  = "$env:COMPUTERNAME`$"                   # this DC's computer account, e.g. DC01$

Write-Host "=== gMSA ADSync task setup on $env:COMPUTERNAME ($memberRef) ===" -ForegroundColor Cyan

# --- 1. KDS root key (forest-wide, one-time) -----------------------------------
if (-not (Get-KdsRootKey)) {
    Write-Host '[KDS ] No root key found - creating one (backdated so it is usable now).'
    Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10)) | Out-Null
} else {
    Write-Host '[KDS ] Root key already present.'
}

# --- 2. Create / ensure the gMSA ----------------------------------------------
$gmsa = Get-ADServiceAccount -Filter "Name -eq '$AccountName'" -ErrorAction SilentlyContinue
if (-not $gmsa) {
    Write-Host "[gMSA] Creating $AccountName (DNSHostName $DnsHostName) ..."
    New-ADServiceAccount -Name $AccountName -DNSHostName $DnsHostName `
        -PrincipalsAllowedToRetrieveManagedPassword $thisHost `
        -Description 'Runs ADSync delta sync scheduled task on the Connect server'
} else {
    Write-Host "[gMSA] $AccountName exists - ensuring DNSHostName + password-retrieval principal are correct."
    Set-ADServiceAccount -Identity $AccountName -DNSHostName $DnsHostName `
        -PrincipalsAllowedToRetrieveManagedPassword $thisHost
}

# --- 3. Install + verify on this host -----------------------------------------
Install-ADServiceAccount -Identity $AccountName
if (-not (Test-ADServiceAccount -Identity $AccountName)) {
    throw "Test-ADServiceAccount returned False. KDS key may not have replicated yet, or this host is not in PrincipalsAllowedToRetrieveManagedPassword. Stopping."
}
Write-Host '[gMSA] Test-ADServiceAccount = True.'

# --- 4. ADSyncOperators membership (lets it TRIGGER a sync) --------------------
$inGroup = Get-LocalGroupMember -Group 'ADSyncOperators' -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like "*\$AccountName`$" }
if (-not $inGroup) {
    Write-Host "[sync] Adding $memberRef to local ADSyncOperators."
    Add-LocalGroupMember -Group 'ADSyncOperators' -Member $memberRef
} else {
    Write-Host '[sync] Already a member of ADSyncOperators.'
}

# --- 5. Deploy the runner script ----------------------------------------------
# NOTE: keep $RunnerDir writable by admins only - the task runs this elevated as the gMSA.
if (-not (Test-Path $RunnerDir)) { New-Item -ItemType Directory -Path $RunnerDir | Out-Null }
$runnerPath = Join-Path $RunnerDir 'Invoke-AdSyncDelta.ps1'
@'
try {
    Import-Module ADSync -ErrorAction Stop
    Start-ADSyncSyncCycle -PolicyType Delta -ErrorAction Stop | Out-Null
    exit 0
} catch {
    # A sync already running is not an error for our purposes.
    if ($_.Exception.Message -match 'in progress|busy|already') { exit 0 }
    Write-Error $_.Exception.Message
    exit 1
}
'@ | Set-Content -Path $runnerPath -Encoding UTF8
Write-Host "[task] Runner written to $runnerPath"

# --- 6. Register (or replace) the scheduled task ------------------------------
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "[task] Removing existing '$TaskName' to re-register cleanly."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runnerPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$principal = New-ScheduledTaskPrincipal -UserId $memberRef -LogonType Password -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings | Out-Null
Write-Host "[task] Registered '$TaskName' as $memberRef every $IntervalMinutes min (no stored password)."

Write-Host ""
Write-Host "DONE - account + task created." -ForegroundColor Green
Write-Host "NEXT (manual): grant '$memberRef' the 'Log on as a batch job' right in the" -ForegroundColor Yellow
Write-Host "               CIS Domain Controller L2 GPO (keep Administrators), then gpupdate /force." -ForegroundColor Yellow
Write-Host "THEN test:     Start-ScheduledTask -TaskName '$TaskName'  ->  Get-ScheduledTaskInfo -TaskName '$TaskName' (LastTaskResult 0 = success)" -ForegroundColor Yellow
