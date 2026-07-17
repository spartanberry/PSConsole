<#
.SYNOPSIS Microsoft Defender for Endpoint device inventory (the machines behind the Defender dashboard).
.DESCRIPTION Read-only pull of /api/machines: name, OS, health, onboarding status, risk/exposure, who manages
    it, and last-seen. Optional -InactiveOnly to show only devices Defender marks Inactive.
.CATEGORY Defender
.ROLE Admin
.RUNEXAMPLE -InactiveOnly
#>
[CmdletBinding()]
param([switch]$InactiveOnly)

. (Join-Path $PSScriptRoot '..\lib\Graph.ps1')
. (Join-Path $PSScriptRoot '..\lib\Defender.ps1')
if (-not (Test-DefenderConfigured)) { Write-Error 'Defender add-on is not configured (data\defender.config.json + the shared Graph app needs WindowsDefenderATP Machine.Read.All).'; return }

$machines = @(Invoke-Mde '/api/machines')
if ($InactiveOnly) { $machines = @($machines | Where-Object { "$($_.healthStatus)" -eq 'Inactive' }) }
if (-not $machines.Count) { [pscustomobject]@{ Name='(no devices returned)'; OS=''; Health=''; Onboarding=''; Risk=''; Exposure=''; ManagedBy=''; LastSeen=''; MachineId='' }; return }

$machines |
    Sort-Object @{ e = { "$($_.computerDnsName)" } } |
    ForEach-Object {
        [pscustomobject]@{
            Name       = [string]$_.computerDnsName
            OS         = ("$($_.osPlatform) $($_.version)").Trim()
            Health     = [string]$_.healthStatus
            Onboarding = [string]$_.onboardingStatus
            Risk       = [string]$_.riskScore
            Exposure   = [string]$_.exposureLevel
            ManagedBy  = [string]$_.managedBy
            LastSeen   = Format-MdeDate $_.lastSeen
            MachineId  = [string]$_.id
        }
    }
