<#
.SYNOPSIS
    Stores the PSConsole (Graph READ) app-registration credentials used by the Entra reports and
    the dashboard - the read-only app.

.DESCRIPTION
    Writes data\graph.config.json with the tenant id, client id, and the client secret DPAPI-encrypted
    at LocalMachine scope, so the PSConsole service account can decrypt it. This is the READ app
    (User.Read.All, Group.Read.All, Directory.Read.All, AuditLog.Read.All); the WRITE app used for
    onboarding has its own helper (Set-GraphWriteCredential.ps1).

    MUST be run ON the PSConsole server (the machine that will decrypt it) - LocalMachine-scoped DPAPI
    ciphertext only decrypts on the machine that encrypted it. The secret is prompted for as a
    SecureString so it never lands in shell history.

.EXAMPLE
    .\Set-GraphCredential.ps1 -TenantId <guid> -ClientId <guid>
    # then paste the client secret VALUE when prompted
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [string]$OutFile = (Join-Path $PSScriptRoot '..\data\graph.config.json')
)

$sec = Read-Host -AsSecureString "Paste the PSConsole (Graph read) client secret VALUE"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if ([string]::IsNullOrWhiteSpace($plain)) { throw 'No secret entered.' }

Add-Type -AssemblyName System.Security
$enc = [Convert]::ToBase64String(
    [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($plain), $null, 'LocalMachine'))

$OutFile = [IO.Path]::GetFullPath($OutFile)
[pscustomobject]@{ tenantId = $TenantId; clientId = $ClientId; secret = $enc } |
    ConvertTo-Json | Set-Content -Path $OutFile -Encoding UTF8

$plain = $null
Write-Host "Wrote $OutFile" -ForegroundColor Green
Write-Host "Verifying decrypt round-trips on this machine..." -ForegroundColor Cyan
$chk = Get-Content $OutFile -Raw | ConvertFrom-Json
$ok = [Text.Encoding]::UTF8.GetString(
    [Security.Cryptography.ProtectedData]::Unprotect(
        [Convert]::FromBase64String($chk.secret), $null, 'LocalMachine')).Length -gt 0
Write-Host ("Decrypt check: {0}" -f $(if ($ok) { 'OK' } else { 'FAILED' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
