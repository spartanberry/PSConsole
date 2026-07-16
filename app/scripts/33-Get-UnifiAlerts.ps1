<#
.SYNOPSIS  Active UniFi alarms across all configured consoles/sites (WAN transitions, device disconnects, adoption issues, etc). Read-only via the UniFi controller API (API key). A clean network returns no rows.
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

# Active alarms come from the controller's /proxy/network/api/s/<site>/rest/alarm?archived=false (the
# Integration API v1 doesn't expose alarms). Sites from /self/sites. Alarm fields are the standard UniFi
# shape (time/datetime, key, msg, subsystem); a healthy site simply returns count=0 (no rows).
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
            $al = Invoke-RestMethod -Method Get -Uri "$api/s/$skey/rest/alarm?archived=false" -Headers $hdr -SkipCertificateCheck -TimeoutSec 30
            foreach ($a in @($al.data)) {
                $when = if ($a.datetime) { [string]$a.datetime } elseif ($a.time) { ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$a.time)).UtcDateTime.ToString('u') } else { '' }
                $msg  = if ($a.msg) { [string]$a.msg } else { [string]$a.catname }
                $rows.Add([PSCustomObject]@{
                    Console = $cname; Site = $sdesc; Time = $when
                    Type = [string]$a.key; Subsystem = [string]$a.subsystem; Message = $msg
                })
            }
        }
    }
    catch {
        $rows.Add([PSCustomObject]@{ Console = $cname; Site = '(error)'; Time = ''; Type = 'query-failed'; Subsystem = ''; Message = "Could not query: $($_.Exception.Message)" })
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
