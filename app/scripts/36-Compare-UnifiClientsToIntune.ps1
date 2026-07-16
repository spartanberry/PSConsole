<#
.SYNOPSIS  Cross-references ACTIVE UniFi clients against Intune-managed devices. -Show Unmanaged lists active clients NOT enrolled in Intune (shadow/BYOD/IoT); -Show Managed lists the ones that ARE; -Show All (default) lists every active client with an InIntune flag. Read-only (UniFi API key + Graph app-only).
.RUNEXAMPLE  -Show Unmanaged -OS Windows
.CATEGORY  UniFi
.NOTES     Needs data\unifi.config.json AND data\graph.config.json (Graph app perm DeviceManagementManagedDevices.Read.All). No writes. UniFi HTTPS is shelled to PowerShell 7 (WinPS 5.1 can't handshake UniFi OS); Graph runs in-process. Match key = hostname==Intune deviceName OR client MAC==Intune wiFiMacAddress. Devices with randomized MACs / generic names (e.g. "iPhone") may not match; named Windows computers are the reliable signal. -OS filters on OS: Intune's OS for managed clients; for unmanaged clients only UniFi's Windows fingerprint (os_name 18) is reliable enough to label (others left blank), so '-OS Windows' is the useful way to cut phone/IoT noise.
.ROLE      Admin
#>
[CmdletBinding()]
param([ValidateSet('All','Managed','Unmanaged')][string]$Show = 'All', [string]$OS)

function Get-UnifiCfgPath { if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'unifi.config.json' } else { Join-Path $PSScriptRoot '..\..\data\unifi.config.json' } }
$cfgPath = Get-UnifiCfgPath
if (-not (Test-Path $cfgPath)) { throw "UniFi not configured: $cfgPath (run unifi-setup\Set-UnifiConfig.ps1)" }

# ---------- 1) Active UniFi clients (via PowerShell 7 - WinPS 5.1 can't TLS-handshake UniFi OS) ----------
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
        $api  = "$(([string]$con.baseUrl).TrimEnd('/'))/proxy/network/api"
        $sites = Invoke-RestMethod -Method Get -Uri "$api/self/sites" -Headers $hdr -SkipCertificateCheck -TimeoutSec 25
        foreach ($s in @($sites.data)) {
            $skey = [string]$s.name; $sdesc = if ($s.desc) { [string]$s.desc } else { $skey }
            $sta = Invoke-RestMethod -Method Get -Uri "$api/s/$skey/stat/sta" -Headers $hdr -SkipCertificateCheck -TimeoutSec 30
            foreach ($cl in @($sta.data)) {
                $rows.Add([PSCustomObject]@{
                    Console = $cname; Site = $sdesc
                    Name = [string]$cl.name; Hostname = [string]$cl.hostname; Mac = [string]$cl.mac
                    Ip = [string]$cl.ip; Type = if ($cl.is_wired) { 'Wired' } else { 'WiFi' }
                    OsName = [string]$cl.os_name   # UniFi numeric fingerprint id (18 = Windows, ground-truthed vs Intune)
                })
            }
        }
    }
    catch {
        $rows.Add([PSCustomObject]@{ Console = $cname; Site = '(error)'; Name = "Could not query: $($_.Exception.Message)"; Hostname = ''; Mac = ''; Ip = ''; Type = ''; OsName = '' })
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
$outTask = $proc.StandardOutput.ReadToEndAsync(); $errTask = $proc.StandardError.ReadToEndAsync()
if (-not $proc.WaitForExit(90000)) { try { $proc.Kill() } catch {}; throw 'UniFi query timed out (90s).' }
$out = $outTask.Result; $err = $errTask.Result
if (-not ($out.Trim()) -and $err) { throw "UniFi (pwsh 7) error: $err" }
$clients = @(($out | ConvertFrom-Json).rows)

# ---------- 2) Intune managed devices (Graph app-only; works natively under WinPS 5.1) ----------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Get-GraphToken {
    $p = if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'graph.config.json' } else { Join-Path $PSScriptRoot '..\..\data\graph.config.json' }
    if (-not (Test-Path $p)) { throw "Graph config not found at $p. Run graph-setup\Set-GraphCredential.ps1 on the server first." }
    $cfg = Get-Content $p -Raw | ConvertFrom-Json
    Add-Type -AssemblyName System.Security
    $secret = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($cfg.secret), $null, 'LocalMachine'))
    (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($cfg.tenantId)/oauth2/v2.0/token" -Body @{ client_id = $cfg.clientId; scope = 'https://graph.microsoft.com/.default'; client_secret = $secret; grant_type = 'client_credentials' }).access_token
}
function Invoke-Graph { param([string]$Uri)
    if (-not $script:tok) { $script:tok = Get-GraphToken }
    if ($Uri -notmatch '^https?://') { $Uri = 'https://graph.microsoft.com/v1.0' + $Uri }
    $h = @{ Authorization = "Bearer $script:tok" }
    $out = New-Object System.Collections.Generic.List[object]
    do { $r = Invoke-RestMethod -Method Get -Uri $Uri -Headers $h; foreach ($i in $r.value) { $out.Add($i) }; $Uri = $r.'@odata.nextLink' } while ($Uri)
    $out
}
function Get-NameKey { param([string]$s) if ([string]::IsNullOrWhiteSpace($s)) { return '' } $s.Trim().ToLowerInvariant() }
function Get-MacKey  { param([string]$s) if ([string]::IsNullOrWhiteSpace($s)) { return '' } $m = ($s -replace '[^0-9A-Fa-f]', '').ToUpperInvariant(); if ($m.Length -eq 12) { $m } else { '' } }

$byName = @{}; $byMac = @{}
foreach ($d in (Invoke-Graph "/deviceManagement/managedDevices?`$select=deviceName,operatingSystem,wiFiMacAddress")) {
    $rec = [PSCustomObject]@{ Name = [string]$d.deviceName; OS = [string]$d.operatingSystem }
    $nk = Get-NameKey $d.deviceName; if ($nk -and -not $byName.ContainsKey($nk)) { $byName[$nk] = $rec }
    $mk = Get-MacKey  $d.wiFiMacAddress; if ($mk -and -not $byMac.ContainsKey($mk)) { $byMac[$mk] = $rec }
}

# ---------- 3) Join + filter ----------
$out = foreach ($c in $clients) {
    if ($c.Site -eq '(error)') { continue }   # surface UniFi errors regardless of filter below
    $match = $null; $how = ''
    $nk = Get-NameKey $c.Hostname; if (-not $nk) { $nk = Get-NameKey $c.Name }
    if ($nk -and $byName.ContainsKey($nk)) { $match = $byName[$nk]; $how = 'Name' }
    if (-not $match) { $mk = Get-MacKey $c.Mac; if ($mk -and $byMac.ContainsKey($mk)) { $match = $byMac[$mk]; $how = 'MAC' } }
    $disp = if ($c.Hostname) { $c.Hostname } elseif ($c.Name) { $c.Name } else { $c.Mac }
    # Resolved OS: Intune's OS if managed (authoritative); else UniFi's Windows fingerprint (os_name 18) only -
    # other UniFi fingerprint ids are too ambiguous (iOS/Android/macOS overlap) to label reliably.
    $osv = if ($match) { $match.OS } elseif ($c.OsName -eq '18') { 'Windows' } else { '' }
    [PSCustomObject]@{
        Console = $c.Console; Site = $c.Site; Client = $disp; MAC = $c.Mac; IP = $c.Ip; Type = $c.Type; OS = $osv
        InIntune = [bool]$match; MatchedBy = $how; IntuneName = $(if ($match) { $match.Name } else { '' }); IntuneOS = $(if ($match) { $match.OS } else { '' })
    }
}
$out = @($out)
switch ($Show) {
    'Managed'   { $out = @($out | Where-Object InIntune) }
    'Unmanaged' { $out = @($out | Where-Object { -not $_.InIntune }) }
}
if ($OS) { $out = @($out | Where-Object { $_.OS -like "*$OS*" }) }
# UniFi error rows (if any) always shown
$errs = @($clients | Where-Object { $_.Site -eq '(error)' } | ForEach-Object { [PSCustomObject]@{ Console = $_.Console; Site = '(error)'; Client = $_.Name; MAC = ''; IP = ''; Type = ''; OS = ''; InIntune = $false; MatchedBy = ''; IntuneName = ''; IntuneOS = '' } })
@($errs) + @($out | Sort-Object Console, @{Expression = 'InIntune'; Descending = $true }, Client)
