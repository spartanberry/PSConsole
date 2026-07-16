<#
.SYNOPSIS  UniFi connected clients across all configured consoles/sites: name, MAC, wired/wireless, when they connected and which device they're connected to. Read-only via the Network Integration API (API key).
.RUNEXAMPLE  (no parameters)
.CATEGORY  UniFi
.NOTES     Needs data\unifi.config.json (run unifi-setup\Set-UnifiConfig.ps1 once per console). No writes. Shells the HTTPS calls to PowerShell 7 - Windows PowerShell 5.1 cannot TLS-handshake UniFi OS.
.ROLE      Admin
#>
[CmdletBinding()]
param()

function Get-UnifiCfgPath { if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'unifi.config.json' } else { Join-Path $PSScriptRoot '..\..\data\unifi.config.json' } }
$cfgPath = Get-UnifiCfgPath
if (-not (Test-Path $cfgPath)) { throw "UniFi not configured: $cfgPath (run unifi-setup\Set-UnifiConfig.ps1)" }

$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "$env:ProgramW6432\PowerShell\7\pwsh.exe")) { if (Test-Path $c) { $pwsh = $c; break } } }
if (-not $pwsh) { throw 'PowerShell 7 (pwsh.exe) is required for the UniFi add-on but was not found. Install PowerShell 7.' }

$inner = @'
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -LiteralPath $env:UNIFI_CFG -Raw | ConvertFrom-Json
$consoles = @($cfg.consoles | Where-Object { $_.baseUrl -and $_.apiKey })
$rows = New-Object System.Collections.Generic.List[object]
foreach ($con in $consoles) {
    $cname = [string]$con.name
    try {
        $key  = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($con.apiKey), $null, 'LocalMachine'))
        $hdr  = @{ 'X-API-KEY' = $key; 'Accept' = 'application/json' }
        $intg = "$(([string]$con.baseUrl).TrimEnd('/'))/proxy/network/integration/v1"
        $sites = Invoke-RestMethod -Method Get -Uri "$intg/sites" -Headers $hdr -SkipCertificateCheck -TimeoutSec 25
        foreach ($s in @($sites.data)) {
            $sid = [string]$s.id; $sname = [string]$s.name
            # Build an id -> name map of this site's devices so we can show what each client uplinks to.
            $devMap = @{}
            $doff = 0; $dtot = 0
            do {
                $dp = Invoke-RestMethod -Method Get -Uri "$intg/sites/$sid/devices?offset=$doff&limit=200" -Headers $hdr -SkipCertificateCheck -TimeoutSec 30
                $dtot = [int]$dp.totalCount; $db = @($dp.data)
                foreach ($d in $db) { if ($d.id) { $devMap[[string]$d.id] = [string]$d.name } }
                $doff += 200
            } while (($devMap.Count -lt $dtot) -and $db.Count -gt 0)
            # Clients (paged).
            $offset = 0; $total = 0; $got = 0
            do {
                $page  = Invoke-RestMethod -Method Get -Uri "$intg/sites/$sid/clients?offset=$offset&limit=200" -Headers $hdr -SkipCertificateCheck -TimeoutSec 30
                $total = [int]$page.totalCount; $batch = @($page.data)
                foreach ($cl in $batch) {
                    $uid = [string]$cl.uplinkDeviceId
                    $up  = if ($uid -and $devMap.ContainsKey($uid)) { $devMap[$uid] } elseif ($uid) { $uid } else { '' }
                    $nm  = [string]$cl.name; $mac = [string]$cl.macAddress
                    if ($nm -eq $mac) { $nm = '(unnamed)' }
                    $rows.Add([PSCustomObject]@{
                        Console = $cname; Site = $sname; Name = $nm; MAC = $mac
                        Type = [string]$cl.type; ConnectedSince = [string]$cl.connectedAt; ConnectedTo = $up
                    })
                }
                $got += $batch.Count; $offset += 200
            } while ($got -lt $total -and $batch.Count -gt 0)
        }
    }
    catch {
        $rows.Add([PSCustomObject]@{ Console = $cname; Site = '(error)'; Name = "Could not query: $($_.Exception.Message)"; MAC = ''; Type = ''; ConnectedSince = ''; ConnectedTo = '' })
    }
}
@{ rows = $rows.ToArray() } | ConvertTo-Json -Depth 6
'@

$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $pwsh
$psi.Arguments = "-NoProfile -NonInteractive -EncodedCommand $enc"
$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.EnvironmentVariables['UNIFI_CFG'] = $cfgPath

$proc = [Diagnostics.Process]::Start($psi)
$outTask = $proc.StandardOutput.ReadToEndAsync()
$errTask = $proc.StandardError.ReadToEndAsync()
if (-not $proc.WaitForExit(90000)) { try { $proc.Kill() } catch {}; throw 'UniFi query timed out (90s).' }
$out = $outTask.Result; $err = $errTask.Result
if (-not ($out.Trim()) -and $err) { throw "UniFi (pwsh 7) error: $err" }

$parsed = $out | ConvertFrom-Json
@($parsed.rows)
