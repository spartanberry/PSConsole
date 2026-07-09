<#
.SYNOPSIS
    Write data\smtp.config.json so PSConsole can email create/decommission notifications.
    Run ON PSCONSOLE01 (the password, if any, is DPAPI-encrypted with LocalMachine scope and only
    decrypts on this machine).

.EXAMPLE
    # Anonymous internal relay (most common):
    .\Set-SmtpConfig.ps1 -Server smtp.example.org -Port 25 -From psconsole@example.com -To it@example.com

.EXAMPLE
    # Authenticated + TLS, multiple recipients:
    .\Set-SmtpConfig.ps1 -Server smtp.office365.com -Port 587 -UseSsl `
        -From psconsole@example.com -To it@example.com,helpdesk@example.com -Username psconsole@example.com
    # (prompts securely for the password)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Server,
    [int]$Port = 25,
    [switch]$UseSsl,
    [Parameter(Mandatory)][string]$From,
    [Parameter(Mandatory)][string[]]$To,          # general/fallback notification recipients
    [string[]]$CreateTo,                          # recipients for "user created" (falls back to -To)
    [string[]]$DecommissionTo,                    # recipients for "user decommissioned" (falls back to -To)
    [string]$Username,
    [switch]$Disabled           # write the config but leave notifications off
)
$ErrorActionPreference = 'Stop'
$dataDir = Join-Path $PSScriptRoot '..\data'
if (-not (Test-Path $dataDir)) { throw "Data dir not found: $dataDir" }
$path = Join-Path $dataDir 'smtp.config.json'

$secret = ''
if ($Username) {
    $sec  = Read-Host -AsSecureString "SMTP password for $Username"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($plain) {
        Add-Type -AssemblyName System.Security
        $secret = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($plain), $null, 'LocalMachine'))
    }
}

$cfg = [ordered]@{
    enabled  = (-not $Disabled)
    server   = $Server
    port     = $Port
    useSsl   = [bool]$UseSsl
    from           = $From
    to             = @($To)
    createTo       = @($CreateTo)
    decommissionTo = @($DecommissionTo)
    username       = [string]$Username
    secret         = $secret
}
$cfg | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8
Write-Host "Wrote $path (enabled=$($cfg.enabled), server=$($Server):$Port, ssl=$([bool]$UseSsl), to=$($To -join ', '))" -ForegroundColor Green
Write-Host "Restart the PSConsole service is NOT required - config is read per send." -ForegroundColor DarkGray
