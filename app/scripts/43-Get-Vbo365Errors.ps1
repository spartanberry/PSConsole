<#
.SYNOPSIS Grouped errors & warnings across all Veeam Backup for M365 jobs, collapsed by normalized message.
.DESCRIPTION Walks every VB365 job's Warning/Failed sessions in the last N days, reads each per-item log record,
    and GROUPS them by a normalized message (emails -> <user>, URLs -> <url>, GUIDs -> <guid>, numbers -> <n>) so
    thousands of per-object lines collapse into a handful of patterns with counts - the fast way to see what needs
    cleanup. Read-only. Runs on the VB365 server under the veeam.config account. Default window is 7 days.
.CATEGORY Veeam
.ROLE Admin
.RUNEXAMPLE -Days 7
.RUNEXAMPLE -Days 2
#>
[CmdletBinding()]
param([int]$Days = 7)

. (Join-Path $PSScriptRoot '..\lib\Veeam.ps1')
. (Join-Path $PSScriptRoot '..\lib\Vbo.ps1')
if (-not (Test-VeeamConfigured)) { Write-Error 'Veeam/VB365 add-on is not configured (data\veeam.config.json).'; return }

$r = Get-VboJobErrors -Days $Days
if (-not $r.ok) { Write-Error "VB365 error query failed: $($r.error)"; return }
if (-not @($r.rows).Count) { [pscustomobject]@{ Job = "(no Warning/Failed sessions in the last $Days days)"; Severity = ''; Count = ''; Pattern = '' }; return }

@($r.rows) |
    Sort-Object @{ e = { [int]$_.Count }; Descending = $true }, Severity |
    ForEach-Object {
        $p = [string]$_.Pattern
        if ($p.Length -gt 150) { $p = $p.Substring(0, 150) + '...' }
        [pscustomobject]@{ Job = [string]$_.Job; Severity = [string]$_.Severity; Count = [int]$_.Count; Pattern = $p }
    }
