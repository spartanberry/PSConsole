<#
.SYNOPSIS
    Adds/updates one UniFi console in the PSConsole UniFi (read-only) add-on, using that console's local
    Network Integration API key. Run it once per console.

.DESCRIPTION
    Maintains data\unifi.config.json as a list of consoles, each { name, baseUrl, apiKey }, with the API key
    DPAPI-encrypted at LocalMachine scope (same scheme as the Graph configs, so the PSConsole service account
    can decrypt it). The UniFi scripts iterate every configured console and every site on it.

    Create the API key IN the Network app on each console: Settings -> Control Plane -> Integrations ->
    Create API Key (needs Network v9.0+, 2025). Each console needs its own key.

    MUST be run ON the PSConsole host (LocalMachine DPAPI only decrypts on the machine that encrypted it).
    For a UniFi OS console the URL is https://<host> (port 443, no :8443). The key is prompted as a
    SecureString so it never lands in your shell history. By default it TESTS the key (lists sites) first.

.EXAMPLE
    .\Set-UnifiConfig.ps1 -Name Site2 -BaseUrl https://10.10.1.1
    # paste that console's API key when prompted; repeat with -Name/-BaseUrl for each of the 3 consoles

.EXAMPLE
    .\Set-UnifiConfig.ps1 -Name Site2 -Remove      # remove a console from the config
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,             # friendly label for this console/location, e.g. Site2
    [string]$BaseUrl,                                # required unless -Remove; e.g. https://10.10.1.1
    [switch]$Remove,
    [switch]$SkipTest,
    [string]$OutFile = (Join-Path $PSScriptRoot '..\data\unifi.config.json')
)

$OutFile = [IO.Path]::GetFullPath($OutFile)

# Load existing consoles (if any) into a rebuildable list, minus any entry with this -Name.
$consoles = New-Object System.Collections.Generic.List[object]
if (Test-Path $OutFile) {
    try {
        $existing = Get-Content $OutFile -Raw | ConvertFrom-Json
        foreach ($c in @($existing.consoles)) { if ([string]$c.name -ne $Name) { $consoles.Add($c) } }
    } catch { Write-Warning "Couldn't parse existing $OutFile - starting fresh." }
}

if ($Remove) {
    if (-not $consoles.Count) { throw "Nothing to remove (or '$Name' wasn't configured)." }
    [pscustomobject]@{ enabled = $true; consoles = $consoles } | ConvertTo-Json -Depth 6 | Set-Content -Path $OutFile -Encoding UTF8
    Write-Host "Removed console '$Name'. Remaining: $($consoles.Count)." -ForegroundColor Green
    return
}

if (-not $BaseUrl) { throw '-BaseUrl is required when adding a console.' }
$BaseUrl = ([string]$BaseUrl).TrimEnd('/')

$sec = Read-Host -AsSecureString "Paste the UniFi Network API key for '$Name'"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if ([string]::IsNullOrWhiteSpace($key)) { throw 'No API key entered.' }

if (-not $SkipTest) {
    # UniFi OS negotiates TLS that Windows PowerShell 5.1 can't handshake, so the test call runs under
    # PowerShell 7. The key goes to the child over STDIN (never the command line).
    Write-Host "Testing the API key against $BaseUrl (via PowerShell 7) ..." -ForegroundColor Cyan
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { foreach ($c in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "$env:ProgramW6432\PowerShell\7\pwsh.exe")) { if (Test-Path $c) { $pwsh = $c; break } } }
    if (-not $pwsh) { throw 'PowerShell 7 (pwsh.exe) is required to reach UniFi OS (WinPS 5.1 cannot TLS-handshake it) but was not found. Install PowerShell 7, or re-run with -SkipTest.' }
    $testInner = @'
$ErrorActionPreference = 'Stop'
$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
try {
    $hdr = @{ 'X-API-KEY' = $in.key; 'Accept' = 'application/json' }
    $sites = Invoke-RestMethod -Method Get -Uri "$(($in.baseUrl).TrimEnd('/'))/proxy/network/integration/v1/sites" -Headers $hdr -SkipCertificateCheck -TimeoutSec 25
    @{ ok = $true; sites = @(@($sites.data) | ForEach-Object { $_.name }) } | ConvertTo-Json -Depth 5
} catch { @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json }
'@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($testInner))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwsh
    $psi.Arguments = "-NoProfile -NonInteractive -EncodedCommand $enc"
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $proc.StandardInput.WriteLine((@{ baseUrl = $BaseUrl; key = $key } | ConvertTo-Json -Compress))
    $proc.StandardInput.Close()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(40000)) { try { $proc.Kill() } catch {}; throw 'API test timed out.' }
    $out = $outTask.Result; $err = $errTask.Result
    $res = $null; try { $res = $out | ConvertFrom-Json } catch {}
    if (-not $res)      { throw "API test failed for '$Name': $($err.Trim()) $($out.Trim())" }
    if (-not $res.ok)   { throw "API test failed for '$Name': $($res.error). Check the URL and that the key is a Network Integration key from THIS console." }
    $names = @($res.sites)
    Write-Host ("Key OK - '{0}' has {1} site(s): {2}" -f $Name, $names.Count, ($names -join ', ')) -ForegroundColor Green
}

try { Add-Type -AssemblyName System.Security } catch {}   # 5.1 needs this; pwsh 7 already has the type
$enc = [Convert]::ToBase64String(
    [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($key), $null, 'LocalMachine'))
$key = $null

$consoles.Add([pscustomobject]@{ name = $Name; baseUrl = $BaseUrl; apiKey = $enc })
[pscustomobject]@{ enabled = $true; consoles = $consoles } | ConvertTo-Json -Depth 6 | Set-Content -Path $OutFile -Encoding UTF8

Write-Host "Wrote $OutFile ($($consoles.Count) console(s) configured)." -ForegroundColor Green
Write-Host "The 'UniFi' category appears on the Run page for admins once at least one console is configured." -ForegroundColor Cyan
