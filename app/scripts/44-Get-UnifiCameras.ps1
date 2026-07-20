<#
.SYNOPSIS  UniFi Protect cameras across all configured consoles: name, model and connection state (up/down). Read-only via the UniFi Protect Integration API (same API key).
.RUNEXAMPLE  (no parameters)
.CATEGORY  UniFi
.NOTES     Needs data\unifi.config.json AND the UniFi Protect Integration API enabled on each console (Protect > Settings > Control Plane / Integrations). Until it is, this reports 'UNREACHABLE'. No writes. Shells the HTTPS calls to PowerShell 7 - Windows PowerShell 5.1 cannot TLS-handshake UniFi OS.
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

# Protect Integration API: GET /proxy/protect/integration/v1/cameras with the X-API-KEY. If Protect's
# Integration API is not enabled, UniFi OS serves its web-app HTML (200) instead of JSON - detected here
# and reported as UNREACHABLE per console (so the tile can say "not enabled" rather than show false data).
$inner = @'
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -LiteralPath $env:UNIFI_CFG -Raw | ConvertFrom-Json
$consoles = @($cfg.consoles | Where-Object { $_.baseUrl })
$rows = New-Object System.Collections.Generic.List[object]
foreach ($con in $consoles) {
    $cname = [string]$con.name
    if (-not $con.protectApiKey) {
        $rows.Add([PSCustomObject]@{ Console = $cname; Camera = ''; Model = ''; State = 'UNREACHABLE'; Note = 'No Protect API key configured - run unifi-setup\Set-UnifiConfig.ps1 -Name ' + $cname + ' -ProtectKey' })
        continue
    }
    try {
        $key  = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($con.protectApiKey), $null, 'LocalMachine'))
        $hdr  = @{ 'X-API-KEY' = $key; 'Accept' = 'application/json' }
        # Protect may live on a separate host (e.g. a UNVR): use protectBaseUrl when set, else the Network baseUrl.
        $pbase = if ($con.protectBaseUrl) { [string]$con.protectBaseUrl } else { [string]$con.baseUrl }
        $uri  = "$($pbase.TrimEnd('/'))/proxy/protect/integration/v1/cameras"
        $resp = Invoke-WebRequest -Method Get -Uri $uri -Headers $hdr -SkipCertificateCheck -TimeoutSec 30
        $ct   = [string]$resp.Headers['Content-Type']
        $body = [string]$resp.Content
        if ($ct -notlike '*json*' -or $body.TrimStart().StartsWith('<')) {
            $rows.Add([PSCustomObject]@{ Console = $cname; Camera = ''; Model = ''; State = 'UNREACHABLE'; Note = 'Protect Integration API not enabled/reachable on this console.' })
            continue
        }
        $cams = @($body | ConvertFrom-Json)
        if (-not $cams.Count) { $rows.Add([PSCustomObject]@{ Console = $cname; Camera = '(no cameras)'; Model = ''; State = ''; Note = '' }); continue }
        foreach ($c in $cams) {
            $state = if ($c.state) { [string]$c.state } elseif ($null -ne $c.isConnected) { if ($c.isConnected) { 'CONNECTED' } else { 'DISCONNECTED' } } else { '' }
            $model = if ($c.modelKey) { [string]$c.modelKey } elseif ($c.type) { [string]$c.type } else { [string]$c.model }
            $rows.Add([PSCustomObject]@{ Console = $cname; Camera = [string]$c.name; Model = $model; State = $state.ToUpper(); Note = '' })
        }
    }
    catch {
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        $rows.Add([PSCustomObject]@{ Console = $cname; Camera = ''; Model = ''; State = 'UNREACHABLE'; Note = "Query failed (http $code): $($_.Exception.Message)" })
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
if (-not $proc.WaitForExit(90000)) { try { $proc.Kill() } catch {}; throw 'UniFi Protect query timed out (90s).' }
$out = $outTask.Result; $err = $errTask.Result
if (-not ($out.Trim()) -and $err) { throw "UniFi Protect (pwsh 7) error: $err" }

$parsed = $out | ConvertFrom-Json
@($parsed.rows)
