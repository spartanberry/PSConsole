<#
.SYNOPSIS
    Veeam backup status - last result per job plus success/warning/failure counts over the window.

.DESCRIPTION
    Read-only Veeam report. It appears on the Run page and in Scheduled reports (so it can be emailed on
    a daily/weekly schedule). Requires the Veeam add-on (data\veeam.config.json) and is hidden until that
    is configured. One row per job: Job, Last result, Last run, and Success/Warning/Failed/Total counts
    over the last N days. No backup is ever started or changed.

.CATEGORY Veeam
.ROLE Admin

.PARAMETER Days
    History window in days for the counts (default 7). The Veeam page uses 7/30/60/90; any positive value works.
#>
param([int]$Days = 7)

# Reuse the add-on's data layer (self-contained; resolves its own config path).
. (Join-Path $PSScriptRoot '..\lib\Veeam.ps1')

if (-not (Test-VeeamConfigured)) { Write-Error 'Veeam add-on is not configured (run graph-setup\Set-VeeamConfig.ps1 on the server).'; return }
if ($Days -lt 1) { $Days = 7 }

$sr = Get-VeeamSessions -Days $Days
if (-not $sr.ok) { Write-Error "Veeam query failed: $($sr.error)"; return }

Get-VeeamReportRows -SessionResult $sr
