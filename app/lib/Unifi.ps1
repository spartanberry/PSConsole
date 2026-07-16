# Unifi.ps1 - UniFi Network (UniFi OS) read-only add-on config + gate. Mirrors the Veeam/Intune add-on
# pattern: the "UniFi" Run-page category and its scripts stay hidden and non-runnable until
# data\unifi.config.json exists and is enabled. The catalog scripts (30-3x) each do their OWN self-contained
# login (they run in isolated runspaces with no module functions), so this lib is only the config gate.
function Get-UnifiConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'unifi.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\unifi.config.json' }
}
function Get-UnifiConfig {
    $p = Get-UnifiConfigPath
    if (-not (Test-Path $p)) { return $null }
    try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null }
}
function Test-UnifiConfigured {
    $c = Get-UnifiConfig
    if (-not $c -or -not $c.enabled) { return $false }
    # New shape: one or more consoles, each with its own baseUrl + DPAPI api key.
    return (@($c.consoles | Where-Object { $_.baseUrl -and $_.apiKey }).Count -gt 0)
}
