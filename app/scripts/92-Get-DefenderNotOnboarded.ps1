<#
.SYNOPSIS Intune-managed devices that are NOT onboarded in Defender for Endpoint.
.DESCRIPTION Cross-references Intune managed devices (Graph) against Defender machines (MDE). The join key is
    the Entra/Azure AD device ID (azureADDeviceId in Intune == aadDeviceId in Defender) - NOT the device name,
    which is unreliable. Lists managed devices whose Entra ID isn't an Onboarded MDE machine, plus any that
    have no Entra device ID (so they can't be correlated at all). Defaults to Windows; -OS macOS or -OS All to
    widen. Needs both the Intune Graph scopes and WindowsDefenderATP Machine.Read.All.
.CATEGORY Defender
.ROLE Admin
.RUNEXAMPLE -OS Windows
#>
[CmdletBinding()]
param([ValidateSet('Windows','macOS','All')][string]$OS = 'Windows')

. (Join-Path $PSScriptRoot '..\lib\Graph.ps1')
. (Join-Path $PSScriptRoot '..\lib\Defender.ps1')
if (-not (Test-DefenderConfigured)) { Write-Error 'Defender add-on is not configured (data\defender.config.json + the shared Graph app needs WindowsDefenderATP Machine.Read.All).'; return }

# Defender side: set of Entra device IDs that ARE onboarded MDE machines.
$onboarded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($m in @(Invoke-Mde '/api/machines')) {
    if ("$($m.onboardingStatus)" -eq 'Onboarded' -and $m.aadDeviceId) { [void]$onboarded.Add([string]$m.aadDeviceId) }
}

# Intune side: managed devices (optionally filtered by OS).
$intune = @(Invoke-Graph '/deviceManagement/managedDevices?$select=deviceName,azureADDeviceId,operatingSystem,complianceState,lastSyncDateTime&$top=999')
if ($OS -ne 'All') { $intune = @($intune | Where-Object { "$($_.operatingSystem)" -eq $OS }) }

$empty = '00000000-0000-0000-0000-000000000000'
$rows = New-Object System.Collections.Generic.List[object]
foreach ($d in $intune) {
    $aad = [string]$d.azureADDeviceId
    $reason = $null
    if (-not $aad -or $aad -eq $empty) { $reason = 'No Entra device ID (cannot correlate)' }
    elseif (-not $onboarded.Contains($aad)) { $reason = 'Not onboarded in Defender' }
    if ($reason) {
        $rows.Add([pscustomobject]@{
            DeviceName      = [string]$d.deviceName
            OS              = [string]$d.operatingSystem
            Compliance      = [string]$d.complianceState
            LastSync        = Format-MdeDate $d.lastSyncDateTime
            AzureAdDeviceId = $aad
            Reason          = $reason
        })
    }
}

if (-not $rows.Count) { [pscustomobject]@{ DeviceName="(all $OS managed devices are onboarded in Defender)"; OS=''; Compliance=''; LastSync=''; AzureAdDeviceId=''; Reason='' }; return }
$rows | Sort-Object Reason, DeviceName
