<#
.SYNOPSIS
    Enable (or disable) the optional Intune reporting add-on (admin-only). Writes data\intune.config.json.
    Run ON the PSConsole server.

.DESCRIPTION
    The Intune reports are read-only Microsoft Graph queries that reuse the SAME app registration as the
    Entra reports (data\graph.config.json) - there is no separate credential to store here. This file is
    just the on/off gate: when enabled, the Intune category appears (admin-only) in the Run-scripts page
    and the scheduled-reports dropdown; when absent or disabled, those scripts are hidden and cannot run.

    PREREQUISITE: the existing Graph app must have these APPLICATION permissions granted + admin consent:
      DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All,
      DeviceManagementServiceConfig.Read.All
    (No secret/clientId change is needed - client-credentials tokens use scope=.default, so newly
    consented permissions apply automatically.)

.PARAMETER Disabled
    Write the config but leave the add-on off (Intune scripts hidden, non-runnable).

.EXAMPLE
    .\Set-IntuneConfig.ps1               # enable the Intune add-on

.EXAMPLE
    .\Set-IntuneConfig.ps1 -Disabled     # ship/keep it dormant
#>
[CmdletBinding()]
param(
    [switch]$Disabled,
    [string]$OutFile = (Join-Path $PSScriptRoot '..\data\intune.config.json')
)
$ErrorActionPreference = 'Stop'

$OutFile = [IO.Path]::GetFullPath($OutFile)
[pscustomobject]@{ enabled = (-not $Disabled) } | ConvertTo-Json | Set-Content -Path $OutFile -Encoding UTF8

Write-Host "Wrote $OutFile (enabled=$(-not $Disabled))" -ForegroundColor Green
Write-Host "Restart the PSConsole service to pick up the change: Restart-Service PSConsole" -ForegroundColor DarkGray
