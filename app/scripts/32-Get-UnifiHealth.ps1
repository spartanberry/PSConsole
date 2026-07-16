<#
.SYNOPSIS  UniFi subsystem health across all configured consoles/sites (WAN / WWW / WLAN / LAN / VPN): status plus AP counts, adopted/disconnected devices and active user/guest counts. Read-only via the UniFi controller API (API key).
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

# The Integration API (v1) doesn't expose subsystem health, so this uses the controller's own
# /proxy/network/api/s/<site>/stat/health (the API key authorizes it too). Sites come from
# /proxy/network/api/self/sites (internal name = the key, desc = the display name).
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
        $api  = "$(([string]$con.baseUrl).TrimEnd('/'))/proxy/network/api"
        $sites = Invoke-RestMethod -Method Get -Uri "$api/self/sites" -Headers $hdr -SkipCertificateCheck -TimeoutSec 25
        foreach ($s in @($sites.data)) {
            $skey = [string]$s.name; $sdesc = if ($s.desc) { [string]$s.desc } else { $skey }
            $h = Invoke-RestMethod -Method Get -Uri "$api/s/$skey/stat/health" -Headers $hdr -SkipCertificateCheck -TimeoutSec 30
            foreach ($sub in @($h.data)) {
                # VPN subsystem is skipped: this network uses SD-WAN, so VPN always reports a benign
                # "error"/zero state that would only be noise on the health page.
                if (([string]$sub.subsystem).ToLower() -eq 'vpn') { continue }
                $rows.Add([PSCustomObject]@{
                    Console = $cname; Site = $sdesc; Subsystem = ([string]$sub.subsystem).ToUpper()
                    Status = [string]$sub.status; Users = [int]$sub.num_user; Guests = [int]$sub.num_guest
                    APs = [int]$sub.num_ap; Adopted = [int]$sub.num_adopted; Disconnected = [int]$sub.num_disconnected
                })
            }
        }
    }
    catch {
        $rows.Add([PSCustomObject]@{ Console = $cname; Site = '(error)'; Subsystem = "Could not query: $($_.Exception.Message)"; Status = ''; Users = 0; Guests = 0; APs = 0; Adopted = 0; Disconnected = 0 })
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
