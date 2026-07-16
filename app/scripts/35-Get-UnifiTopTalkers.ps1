<#
.SYNOPSIS  UniFi top talkers across all configured consoles/sites: the clients using the most data THIS SESSION (download / upload / total GB), highest first. Read-only via the UniFi controller API (API key). Defaults to top 20 per console.
.RUNEXAMPLE  -Top 20
.CATEGORY  UniFi
.NOTES     Needs data\unifi.config.json (run unifi-setup\Set-UnifiConfig.ps1 once per console). No writes. Shells the HTTPS calls to PowerShell 7 - Windows PowerShell 5.1 cannot TLS-handshake UniFi OS. Byte counters are for the client's CURRENT session (UniFi doesn't retain historical per-client totals without DPI, which this API doesn't expose).
.ROLE      Admin
#>
[CmdletBinding()]
param([int]$Top = 20)
if ($Top -lt 1) { $Top = 1 }; if ($Top -gt 200) { $Top = 200 }

function Get-UnifiCfgPath { if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'unifi.config.json' } else { Join-Path $PSScriptRoot '..\..\data\unifi.config.json' } }
$cfgPath = Get-UnifiCfgPath
if (-not (Test-Path $cfgPath)) { throw "UniFi not configured: $cfgPath (run unifi-setup\Set-UnifiConfig.ps1)" }

$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "$env:ProgramW6432\PowerShell\7\pwsh.exe")) { if (Test-Path $c) { $pwsh = $c; break } } }
if (-not $pwsh) { throw 'PowerShell 7 (pwsh.exe) is required for the UniFi add-on but was not found. Install PowerShell 7.' }

# Uses the controller's /proxy/network/api/s/<site>/stat/sta (active clients) - the Integration API v1
# client list has no byte counters. Wired clients store bytes in wired-tx/rx_bytes, wireless in tx/rx_bytes;
# we sum whichever are present. Name falls back name -> hostname -> MAC. Sites from /self/sites.
$inner = @'
$ErrorActionPreference = 'Stop'
$top = [int]$env:UNIFI_TOP
$cfg = Get-Content -LiteralPath $env:UNIFI_CFG -Raw | ConvertFrom-Json
$consoles = @($cfg.consoles | Where-Object { $_.baseUrl -and $_.apiKey })
$rows = New-Object System.Collections.Generic.List[object]
foreach ($con in $consoles) {
    $cname = [string]$con.name
    try {
        $key  = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($con.apiKey), $null, 'LocalMachine'))
        $hdr  = @{ 'X-API-KEY' = $key; 'Accept' = 'application/json' }
        $api  = "$(([string]$con.baseUrl).TrimEnd('/'))/proxy/network/api"
        $sites = Invoke-RestMethod -Method Get -Uri "$api/self/sites" -Headers $hdr -SkipCertificateCheck -TimeoutSec 25
        foreach ($s in @($sites.data)) {
            $skey = [string]$s.name; $sdesc = if ($s.desc) { [string]$s.desc } else { $skey }
            $sta = Invoke-RestMethod -Method Get -Uri "$api/s/$skey/stat/sta" -Headers $hdr -SkipCertificateCheck -TimeoutSec 30
            $clients = foreach ($cl in @($sta.data)) {
                $down = 0.0; $up = 0.0
                if ($cl.'wired-rx_bytes') { $down += [double]$cl.'wired-rx_bytes' }
                if ($cl.'wired-tx_bytes') { $up   += [double]$cl.'wired-tx_bytes' }
                if ($cl.rx_bytes)         { $down += [double]$cl.rx_bytes }
                if ($cl.tx_bytes)         { $up   += [double]$cl.tx_bytes }
                $nm = if ($cl.name) { [string]$cl.name } elseif ($cl.hostname) { [string]$cl.hostname } else { [string]$cl.mac }
                [PSCustomObject]@{
                    Console = $cname; Site = $sdesc; Client = $nm
                    Type = if ($cl.is_wired) { 'Wired' } else { 'WiFi' }
                    IP = [string]$cl.ip
                    DownGB = [math]::Round($down / 1GB, 2); UpGB = [math]::Round($up / 1GB, 2)
                    TotalGB = [math]::Round(($down + $up) / 1GB, 2)
                }
            }
            foreach ($r in (@($clients) | Sort-Object TotalGB -Descending | Select-Object -First $top)) { $rows.Add($r) }
        }
    }
    catch {
        $rows.Add([PSCustomObject]@{ Console = $cname; Site = '(error)'; Client = "Could not query: $($_.Exception.Message)"; Type = ''; IP = ''; DownGB = 0; UpGB = 0; TotalGB = 0 })
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
$psi.EnvironmentVariables['UNIFI_TOP'] = "$Top"

$proc = [Diagnostics.Process]::Start($psi)
$outTask = $proc.StandardOutput.ReadToEndAsync()
$errTask = $proc.StandardError.ReadToEndAsync()
if (-not $proc.WaitForExit(90000)) { try { $proc.Kill() } catch {}; throw 'UniFi query timed out (90s).' }
$out = $outTask.Result; $err = $errTask.Result
if (-not ($out.Trim()) -and $err) { throw "UniFi (pwsh 7) error: $err" }

$parsed = $out | ConvertFrom-Json
@($parsed.rows)
