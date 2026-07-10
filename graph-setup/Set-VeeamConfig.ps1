<#
.SYNOPSIS
    Configure the optional Veeam backup-reporting add-on (admin-only). Writes data\veeam.config.json.
    Run ON the PSConsole server.

.DESCRIPTION
    PSConsole queries Veeam Backup & Replication read-only over PowerShell remoting into the Veeam
    server, so this host does NOT need the Veeam console installed. The account used must be able to
    WinRM into the Veeam server and read VBR (e.g. a Veeam "Backup Viewer" / "Restore Operator" role).

    - Omit -Username to use the PSConsole service account's own identity for the remoting connection.
    - Provide -Username to store a dedicated credential; you'll be prompted for the password, which is
      DPAPI-encrypted at LocalMachine scope (same scheme as the other secrets, machine-bound).

.PARAMETER Server
    The Veeam Backup & Replication server hostname (FQDN), e.g. backupserver.example.org.

.PARAMETER Username
    Optional DOMAIN\user (or user@domain) to connect as. Omit to use the service account.

.PARAMETER UseSsl
    Use HTTPS (5986) for WinRM instead of HTTP (5985).

.PARAMETER UseCredSsp
    Authenticate WinRM with CredSSP so the query credential is delegated onward from the Veeam server.
    Only needed in the rare case where the Veeam query itself makes a further hop to a DIFFERENT machine;
    the normal add-on connects to the Veeam server's own (localhost) services and does NOT need it.
    NOTE: CredSSP does NOT fix "Failed to connect to Identity service" - that is a certificate-trust
    prompt; run Set-VeeamTrust.ps1 for it. Requires CredSSP enabled on this host
    (Enable-WSManCredSSP -Role Client -DelegateComputer <veeam>) and on the Veeam server
    (Enable-WSManCredSSP -Role Server). See ADMIN-GUIDE.

.PARAMETER Disabled
    Write the config but leave the add-on off (nav item hidden, no queries run).

.EXAMPLE
    .\Set-VeeamConfig.ps1 -Server backupserver.example.org -Username DOMAIN\svc-veeamread
    # paste the password when prompted

.EXAMPLE
    .\Set-VeeamConfig.ps1 -Server backupserver.example.org      # use the service account identity
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Server,
    [string]$Username,
    [switch]$UseSsl,
    [switch]$UseCredSsp,
    [switch]$Disabled,
    [string]$OutFile = (Join-Path $PSScriptRoot '..\data\veeam.config.json')
)
$ErrorActionPreference = 'Stop'

$secret = ''
if ($Username) {
    $sec  = Read-Host -AsSecureString "Password for $Username"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($plain) {
        Add-Type -AssemblyName System.Security
        $secret = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($plain), $null, 'LocalMachine'))
    }
    $plain = $null
}

$OutFile = [IO.Path]::GetFullPath($OutFile)
[pscustomobject]@{
    enabled    = (-not $Disabled)
    server     = $Server
    useSsl     = [bool]$UseSsl
    useCredSsp = [bool]$UseCredSsp
    username   = [string]$Username
    secret     = $secret
} | ConvertTo-Json | Set-Content -Path $OutFile -Encoding UTF8

Write-Host "Wrote $OutFile (enabled=$(-not $Disabled), server=$Server, ssl=$([bool]$UseSsl), account=$(if ($Username) { $Username } else { 'service account' }))" -ForegroundColor Green
Write-Host "Restart the PSConsole service to pick up nav changes: Restart-Service PSConsole" -ForegroundColor DarkGray
