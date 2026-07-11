<#
.SYNOPSIS
    Configure the optional Veeam -> SharePoint remediation-tracking add-on (admin-only).
    Writes data\sharepoint.config.json. Run ON the PSConsole server.

.DESCRIPTION
    PSConsole syncs Veeam job status into a SharePoint list once a day and provides a remediation editor
    (flip a failed job to Remediated + record the fix). Auth REUSES the app-only PSConsole-Graph-Write app
    (graph-setup\Set-GraphWriteCredential.ps1) - there is no separate credential to store here.

    PREREQUISITES (one-time, see docs\ADMIN-GUIDE for the exact steps):
      1. Grant the PSConsole-Graph-Write app the APPLICATION permission Sites.Selected + admin consent.
      2. Create the SharePoint list with the required columns (Title/Job, VeeamResult, LastRun,
         SuccessCount, WarningCount, FailedCount, LastSynced, RemStatus, FixNote, RemediatedBy, RemediatedAt).
      3. Grant the app WRITE access to just that site (Graph POST /sites/{id}/permissions, or PnP
         Grant-PnPAzureADAppSitePermission). Sites.Selected means the app can touch only sites it's granted.

.PARAMETER SiteHostname
    The SharePoint hostname, e.g. contoso.sharepoint.com.

.PARAMETER SitePath
    The server-relative site path, e.g. /sites/ITOps.

.PARAMETER ListName
    Display name of the target list (default "Veeam Backup Status").

.PARAMETER Disabled
    Write the config but leave the add-on off (nav hidden, no sync runs).

.EXAMPLE
    .\Set-SharePointConfig.ps1 -SiteHostname contoso.sharepoint.com -SitePath /sites/ITOps -ListName "Veeam Backup Status"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SiteHostname,
    [Parameter(Mandatory)][string]$SitePath,
    [string]$ListName = 'Veeam Backup Status',
    [switch]$Disabled,
    [string]$OutFile = (Join-Path $PSScriptRoot '..\data\sharepoint.config.json')
)
$ErrorActionPreference = 'Stop'

$OutFile = [IO.Path]::GetFullPath($OutFile)
[pscustomobject]@{
    enabled      = (-not $Disabled)
    siteHostname = ($SiteHostname -replace '^https?://','').Trim('/')
    sitePath     = '/' + $SitePath.Trim('/')
    listName     = $ListName
} | ConvertTo-Json | Set-Content -Path $OutFile -Encoding UTF8

Write-Host "Wrote $OutFile (enabled=$(-not $Disabled), site=$SiteHostname$SitePath, list='$ListName')" -ForegroundColor Green
Write-Host "Restart the PSConsole service to pick up the change: Restart-Service PSConsole" -ForegroundColor DarkGray
