<#
.SYNOPSIS  UniFi WAN (internet) traffic per day across all configured consoles/sites: download / upload / total GB for each of the last N days. Read-only via the UniFi controller reporting API (API key). Defaults to 7 days.
.RUNEXAMPLE  -Days 7
.CATEGORY  UniFi
.NOTES     Needs data\unifi.config.json (run unifi-setup\Set-UnifiConfig.ps1 once per console). No writes. Shells the HTTPS calls to PowerShell 7 - Windows PowerShell 5.1 cannot TLS-handshake UniFi OS. Per-app/website breakdown is NOT available via this API (see Get-UnifiTopTalkers for per-client volume).
.ROLE      Admin
#>
[CmdletBinding()]
param([int]$Days = 7)
if ($Days -lt 1) { $Days = 1 }; if ($Days -gt 90) { $Days = 90 }

function Get-UnifiCfgPath { if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'unifi.config.json' } else { Join-Path $PSScriptRoot '..\..\data\unifi.config.json' } }
$cfgPath = Get-UnifiCfgPath
if (-not (Test-Path $cfgPath)) { throw "UniFi not configured: $cfgPath (run unifi-setup\Set-UnifiConfig.ps1)" }

$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "$env:ProgramW6432\PowerShell\7\pwsh.exe")) { if (Test-Path $c) { $pwsh = $c; break } } }
if (-not $pwsh) { throw 'PowerShell 7 (pwsh.exe) is required for the UniFi add-on but was not found. Install PowerShell 7.' }

# Uses the controller's own /proxy/network/api/s/<site>/stat/report/daily.site (the Integration API v1
# doesn't expose traffic reports). wan-tx_bytes = upload, wan-rx_bytes = download. Sites from /self/sites.
$inner = @'
$ErrorActionPreference = 'Stop'
$days = [int]$env:UNIFI_DAYS
$cfg = Get-Content -LiteralPath $env:UNIFI_CFG -Raw | ConvertFrom-Json
$consoles = @($cfg.consoles | Where-Object { $_.baseUrl -and $_.apiKey })
$rows = New-Object System.Collections.Generic.List[object]
$end = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$start = $end - ([int64]$days * 86400000)
foreach ($con in $consoles) {
    $cname = [string]$con.name
    try {
        $key  = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($con.apiKey), $null, 'LocalMachine'))
        $hdr  = @{ 'X-API-KEY' = $key; 'Accept' = 'application/json' }
        $api  = "$(([string]$con.baseUrl).TrimEnd('/'))/proxy/network/api"
        $sites = Invoke-RestMethod -Method Get -Uri "$api/self/sites" -Headers $hdr -SkipCertificateCheck -TimeoutSec 25
        foreach ($s in @($sites.data)) {
            $skey = [string]$s.name; $sdesc = if ($s.desc) { [string]$s.desc } else { $skey }
            $body = @{ attrs = @('time','wan-tx_bytes','wan-rx_bytes'); start = $start; end = $end } | ConvertTo-Json
            $rep = Invoke-RestMethod -Method Post -Uri "$api/s/$skey/stat/report/daily.site" -Headers $hdr -Body $body -ContentType 'application/json' -SkipCertificateCheck -TimeoutSec 30
            foreach ($d in (@($rep.data) | Sort-Object time)) {
                $down = [double]$d.'wan-rx_bytes'; $up = [double]$d.'wan-tx_bytes'
                $rows.Add([PSCustomObject]@{
                    Console = $cname; Site = $sdesc
                    Date = ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$d.time)).LocalDateTime.ToString('yyyy-MM-dd')
                    DownGB = [math]::Round($down / 1GB, 2); UpGB = [math]::Round($up / 1GB, 2)
                    TotalGB = [math]::Round(($down + $up) / 1GB, 2)
                })
            }
        }
    }
    catch {
        $rows.Add([PSCustomObject]@{ Console = $cname; Site = '(error)'; Date = "Could not query: $($_.Exception.Message)"; DownGB = 0; UpGB = 0; TotalGB = 0 })
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
$psi.EnvironmentVariables['UNIFI_DAYS'] = "$Days"

$proc = [Diagnostics.Process]::Start($psi)
$outTask = $proc.StandardOutput.ReadToEndAsync()
$errTask = $proc.StandardError.ReadToEndAsync()
if (-not $proc.WaitForExit(90000)) { try { $proc.Kill() } catch {}; throw 'UniFi query timed out (90s).' }
$out = $outTask.Result; $err = $errTask.Result
if (-not ($out.Trim()) -and $err) { throw "UniFi (pwsh 7) error: $err" }

$parsed = $out | ConvertFrom-Json
@($parsed.rows)
