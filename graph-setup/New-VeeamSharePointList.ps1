<#
.SYNOPSIS
    Create the SharePoint list (with ALL required columns) for the Veeam remediation add-on, so you don't
    have to build columns by hand. Idempotent. Run ON the PSConsole server.

.DESCRIPTION
    Uses the app-only PSConsole-Graph-Write app to create the list named in data\sharepoint.config.json with
    the exact columns PSConsole expects (VeeamResult, LastRun, SuccessCount/WarningCount/FailedCount,
    LastSynced, RemStatus, FixNote, RemediatedBy, RemediatedAt; Title is built-in and holds the job name).
    Safe to re-run: if a list with that name already exists it is left as-is.

    ORDER: run Set-SharePointConfig.ps1 FIRST (writes the config), then this.

    PREREQUISITES (see docs\ADMIN-GUIDE 8d):
      - PSConsole-Graph-Write has Sites.Selected granted + admin consent.
      - The app has been granted WRITE (or Manage) access to the target site.
    NOTE: creating a list can require the Manage role in some tenants. If you get "access denied", grant the
    app Manage for the creation, then dial it back to Write for the ongoing daily sync.

.EXAMPLE
    .\Set-SharePointConfig.ps1 -SiteHostname contoso.sharepoint.com -SitePath /sites/ITOps -ListName "Veeam Backup Status"
    .\New-VeeamSharePointList.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\app\lib\GraphWrite.ps1')
. (Join-Path $PSScriptRoot '..\app\lib\SharePoint.ps1')
if (-not $env:PSCONSOLE_DATA) { $env:PSCONSOLE_DATA = (Resolve-Path (Join-Path $PSScriptRoot '..\data')).Path }

if (-not (Test-SharePointConfigured)) {
    throw 'data\sharepoint.config.json is missing or disabled - run Set-SharePointConfig.ps1 first.'
}

$res = New-SPVeeamList
if ($res.ok) {
    Write-Host "OK - $($res.note) (listId=$($res.listId))." -ForegroundColor Green
    $added = @($res.columnsAdded)
    if ($added.Count) { Write-Host "Added columns: $($added -join ', ')" -ForegroundColor Green }
    else { Write-Host "All required columns already present - nothing to add." -ForegroundColor DarkGray }
    Write-Host "Next: Restart-Service PSConsole, then open Veeam > Remediation and click 'Sync now'." -ForegroundColor DarkGray
}
else {
    Write-Warning "List creation failed: $($res.error)"
    Write-Host "If this is an access error, confirm Sites.Selected consent + the app's site grant (Write/Manage). See ADMIN-GUIDE 8d." -ForegroundColor DarkGray
    exit 1
}
