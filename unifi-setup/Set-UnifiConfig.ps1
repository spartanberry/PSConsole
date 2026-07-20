<#
.SYNOPSIS
    Adds/updates one UniFi console in the PSConsole UniFi (read-only) add-on. Stores that console's Network
    Integration API key and, optionally, a separate UniFi Protect API key (for the camera tile). Run once per
    console (and again with -ProtectKey to add the Protect key).

.DESCRIPTION
    Maintains data\unifi.config.json as a list of consoles, each { name, baseUrl, apiKey, protectApiKey }, with
    each key DPAPI-encrypted at LocalMachine scope (same scheme as the Graph configs, so the PSConsole service
    account can decrypt it). The UniFi scripts iterate every configured console and every site on it.

    Network key: Settings -> Control Plane -> Integrations -> Create API Key (Network v9.0+, 2025).
    Protect key: UniFi Protect -> Settings -> Control Plane / Integrations -> Create API Key. Protect uses a
    SEPARATE key from Network - hence -ProtectKey. Add the console with its Network key FIRST, then re-run with
    -ProtectKey to attach the Protect key (baseUrl + Network key are preserved).

    MUST be run ON the PSConsole host (LocalMachine DPAPI only decrypts on the machine that encrypted it).
    For a UniFi OS console the URL is https://<host> (port 443, no :8443). Keys are prompted as a SecureString
    so they never land in your shell history. By default it TESTS the key first.

.EXAMPLE
    .\Set-UnifiConfig.ps1 -Name Site2 -BaseUrl https://10.10.1.1
    # paste that console's NETWORK API key when prompted; repeat per console

.EXAMPLE
    .\Set-UnifiConfig.ps1 -Name Site2 -ProtectKey
    # paste that console's PROTECT API key; tests it lists cameras, then stores it alongside the Network key

.EXAMPLE
    .\Set-UnifiConfig.ps1 -Name Site1 -ProtectKey -ProtectUrl https://10.0.20.11
    # Protect lives on a SEPARATE host (e.g. a UNVR): -ProtectUrl points the Protect API at it while the
    # Network baseUrl/key stay as-is. The Protect API key is generated in Protect ON that UNVR.

.EXAMPLE
    .\Set-UnifiConfig.ps1 -Name Site2 -Remove      # remove a console from the config
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,             # friendly label for this console/location, e.g. Site2
    [string]$BaseUrl,                                # required when first adding a console; e.g. https://10.10.1.1
    [switch]$ProtectKey,                             # store/update this console's UniFi Protect API key (separate key)
    [string]$ProtectUrl,                             # base URL where Protect lives IF it's a separate host (e.g. a UNVR). Defaults to the Network baseUrl.
    [switch]$Remove,
    [switch]$SkipTest,
    [string]$OutFile = (Join-Path $PSScriptRoot '..\data\unifi.config.json')
)

$OutFile = [IO.Path]::GetFullPath($OutFile)

# Load existing consoles into a rebuildable list, remembering this -Name's current entry so its other fields
# (baseUrl / the OTHER key) survive an update of just one key.
$consoles = New-Object System.Collections.Generic.List[object]
$prev = $null
if (Test-Path $OutFile) {
    try {
        $existing = Get-Content $OutFile -Raw | ConvertFrom-Json
        foreach ($c in @($existing.consoles)) {
            if ([string]$c.name -eq $Name) { $prev = $c } else { $consoles.Add($c) }
        }
    } catch { Write-Warning "Couldn't parse existing $OutFile - starting fresh." }
}

if ($Remove) {
    if (-not $prev) { throw "Nothing to remove ('$Name' wasn't configured)." }
    [pscustomobject]@{ enabled = $true; consoles = $consoles } | ConvertTo-Json -Depth 6 | Set-Content -Path $OutFile -Encoding UTF8
    Write-Host "Removed console '$Name'. Remaining: $($consoles.Count)." -ForegroundColor Green
    return
}

$isProtect = [bool]$ProtectKey
$protectBase = $null
if ($isProtect) {
    if (-not $prev) { throw "Add console '$Name' with its Network key first (.\Set-UnifiConfig.ps1 -Name $Name -BaseUrl https://<host>), then re-run with -ProtectKey." }
    $BaseUrl = [string]$prev.baseUrl                       # keep the Network base URL untouched
    # Protect may live on a SEPARATE host (e.g. a UNVR): use -ProtectUrl, else a stored protectBaseUrl, else the Network base.
    $protectBase = if ($ProtectUrl) { ([string]$ProtectUrl).TrimEnd('/') }
                   elseif ($prev.PSObject.Properties.Name -contains 'protectBaseUrl' -and $prev.protectBaseUrl) { [string]$prev.protectBaseUrl }
                   else { $BaseUrl }
} else {
    if (-not $BaseUrl -and $prev) { $BaseUrl = [string]$prev.baseUrl }
    if (-not $BaseUrl) { throw '-BaseUrl is required when adding a new console.' }
    $BaseUrl = ([string]$BaseUrl).TrimEnd('/')
}
$testUrl = if ($isProtect) { $protectBase } else { $BaseUrl }

$prompt = if ($isProtect) { "Paste the UniFi PROTECT API key for '$Name'" } else { "Paste the UniFi Network API key for '$Name'" }
$sec = Read-Host -AsSecureString $prompt
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if ([string]::IsNullOrWhiteSpace($key)) { throw 'No API key entered.' }

if (-not $SkipTest) {
    # UniFi OS negotiates TLS that Windows PowerShell 5.1 can't handshake, so the test call runs under
    # PowerShell 7. The key goes to the child over STDIN (never the command line).
    $target = if ($isProtect) { 'Protect cameras' } else { 'Network sites' }
    Write-Host "Testing the $target API key against $testUrl (via PowerShell 7) ..." -ForegroundColor Cyan
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "$env:ProgramW6432\PowerShell\7\pwsh.exe")) { if (Test-Path $c) { $pwsh = $c; break } } }
    if (-not $pwsh) { throw 'PowerShell 7 (pwsh.exe) is required to reach UniFi OS (WinPS 5.1 cannot TLS-handshake it) but was not found. Install PowerShell 7, or re-run with -SkipTest.' }
    if ($isProtect) {
        # Protect returns the UniFi OS web-app HTML (200) instead of JSON when the Protect Integration API
        # isn't enabled or the key isn't a Protect key - detect that explicitly so the message is useful.
        $testInner = @'
$ErrorActionPreference = 'Stop'
$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
try {
    $hdr = @{ 'X-API-KEY' = $in.key; 'Accept' = 'application/json' }
    $resp = Invoke-WebRequest -Method Get -Uri "$(($in.baseUrl).TrimEnd('/'))/proxy/protect/integration/v1/cameras" -Headers $hdr -SkipCertificateCheck -TimeoutSec 25
    $ct = [string]$resp.Headers['Content-Type']; $body = [string]$resp.Content
    if ($ct -notlike '*json*' -or $body.TrimStart().StartsWith('<')) { @{ ok = $false; error = 'Protect returned its web page, not JSON - the Protect Integration API is not enabled or this is not a Protect key.' } | ConvertTo-Json; return }
    $cams = @($body | ConvertFrom-Json)
    @{ ok = $true; count = $cams.Count; names = @(@($cams) | ForEach-Object { [string]$_.name }) } | ConvertTo-Json -Depth 5
} catch { @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json }
'@
    } else {
        $testInner = @'
$ErrorActionPreference = 'Stop'
$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
try {
    $hdr = @{ 'X-API-KEY' = $in.key; 'Accept' = 'application/json' }
    $sites = Invoke-RestMethod -Method Get -Uri "$(($in.baseUrl).TrimEnd('/'))/proxy/network/integration/v1/sites" -Headers $hdr -SkipCertificateCheck -TimeoutSec 25
    @{ ok = $true; sites = @(@($sites.data) | ForEach-Object { $_.name }) } | ConvertTo-Json -Depth 5
} catch { @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json }
'@
    }
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($testInner))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwsh
    $psi.Arguments = "-NoProfile -NonInteractive -EncodedCommand $enc"
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $proc.StandardInput.WriteLine((@{ baseUrl = $testUrl; key = $key } | ConvertTo-Json -Compress))
    $proc.StandardInput.Close()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(40000)) { try { $proc.Kill() } catch {}; throw 'API test timed out.' }
    $out = $outTask.Result; $err = $errTask.Result
    $res = $null; try { $res = $out | ConvertFrom-Json } catch {}
    if (-not $res)    { throw "API test failed for '$Name': $($err.Trim()) $($out.Trim())" }
    if (-not $res.ok) { throw "API test failed for '$Name': $($res.error)" }
    if ($isProtect) {
        Write-Host ("Protect key OK - '{0}' has {1} camera(s): {2}" -f $Name, $res.count, (@($res.names) -join ', ')) -ForegroundColor Green
    } else {
        $names = @($res.sites)
        Write-Host ("Network key OK - '{0}' has {1} site(s): {2}" -f $Name, $names.Count, ($names -join ', ')) -ForegroundColor Green
    }
}

try { Add-Type -AssemblyName System.Security } catch {}   # 5.1 needs this; pwsh 7 already has the type
$encKey = [Convert]::ToBase64String(
    [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($key), $null, 'LocalMachine'))
$key = $null

# Rebuild this console's entry, preserving whichever fields we are NOT setting on this run.
if ($isProtect) {
    $entry = [pscustomobject]@{ name = $Name; baseUrl = $BaseUrl; apiKey = [string]$prev.apiKey; protectApiKey = $encKey; protectBaseUrl = $protectBase }
} else {
    $keepProtect    = if ($prev -and $prev.PSObject.Properties.Name -contains 'protectApiKey')  { [string]$prev.protectApiKey }  else { $null }
    $keepProtectUrl = if ($prev -and $prev.PSObject.Properties.Name -contains 'protectBaseUrl') { [string]$prev.protectBaseUrl } else { $null }
    $entry = [pscustomobject]@{ name = $Name; baseUrl = $BaseUrl; apiKey = $encKey; protectApiKey = $keepProtect; protectBaseUrl = $keepProtectUrl }
}
$consoles.Add($entry)
[pscustomobject]@{ enabled = $true; consoles = $consoles } | ConvertTo-Json -Depth 6 | Set-Content -Path $OutFile -Encoding UTF8

Write-Host "Wrote $OutFile ($($consoles.Count) console(s) configured)." -ForegroundColor Green
if ($isProtect) { Write-Host "The Cameras tile on the Operations dashboard will light up on the next refresh." -ForegroundColor Cyan }
else { Write-Host "The 'UniFi' category appears on the Run page for admins once at least one console is configured. Add the Protect key with -ProtectKey for the Cameras tile." -ForegroundColor Cyan }
