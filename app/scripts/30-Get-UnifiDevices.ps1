<#
.SYNOPSIS  UniFi devices across all configured consoles/sites (APs / switches / gateways): name, model, IP, online state, firmware and whether an upgrade is available. Read-only via the Network Integration API (API key).
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

# WinPS 5.1's TLS stack can't negotiate with UniFi OS, so the actual HTTPS runs under PowerShell 7. The
# child reads the config itself and DPAPI-decrypts each console's API key (LocalMachine blobs decrypt in
# pwsh 7 too), so no plaintext secret is ever passed between processes. It prints one JSON object {rows:[...]}.
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
            $offset = 0; $limit = 200; $total = 0; $got = 0
            do {
                $page  = Invoke-RestMethod -Method Get -Uri "$intg/sites/$sid/devices?offset=$offset&limit=$limit" -Headers $hdr -SkipCertificateCheck -TimeoutSec 30
                $total = [int]$page.totalCount
                $batch = @($page.data)
                foreach ($d in $batch) {
                    $rows.Add([PSCustomObject]@{
                        Console = $cname; Site = $sname; Name = [string]$d.name; Model = [string]$d.model
                        IP = [string]$d.ipAddress; State = [string]$d.state; Firmware = [string]$d.firmwareVersion
                        UpgradeAvail = [bool]$d.firmwareUpdatable; MAC = [string]$d.macAddress
                    })
                }
                $got += $batch.Count; $offset += $limit
            } while ($got -lt $total -and $batch.Count -gt 0)
        }
    }
    catch {
        $rows.Add([PSCustomObject]@{ Console = $cname; Site = '(error)'; Name = "Could not query: $($_.Exception.Message)"; Model = ''; IP = ''; State = ''; Firmware = ''; UpgradeAvail = $false; MAC = '' })
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
$psi.EnvironmentVariables['UNIFI_CFG'] = $cfgPath          # pass the config PATH (not the secret) to the child

$proc = [Diagnostics.Process]::Start($psi)
$outTask = $proc.StandardOutput.ReadToEndAsync()
$errTask = $proc.StandardError.ReadToEndAsync()
if (-not $proc.WaitForExit(90000)) { try { $proc.Kill() } catch {}; throw 'UniFi query timed out (90s).' }
$out = $outTask.Result; $err = $errTask.Result
if (-not ($out.Trim()) -and $err) { throw "UniFi (pwsh 7) error: $err" }

$parsed = $out | ConvertFrom-Json
@($parsed.rows)
