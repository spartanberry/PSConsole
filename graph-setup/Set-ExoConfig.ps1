<#
.SYNOPSIS
    Stores the PSConsole-EXO-Write (Exchange Online app-only) connection settings for Phase-2
    onboarding of mail-enabled security groups + distribution lists.

.DESCRIPTION
    Writes data\exo.config.json with { appId, organization, certThumbprint }. Unlike the Graph
    configs, there is NO secret - Exchange Online app-only auth is certificate-based, so only the
    thumbprint is stored. The certificate's PRIVATE KEY must be installed in a store the PSConsole
    service account can read (LocalMachine\My with read granted to the service account is typical).

    Run this ON PSCONSOLE01 after the app registration + cert + Exchange role are in place.

.EXAMPLE
    .\Set-ExoConfig.ps1 -AppId <guid> -Organization contoso.onmicrosoft.com -CertThumbprint <thumbprint>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$CertThumbprint,
    [string]$OutFile = (Join-Path $PSScriptRoot '..\data\exo.config.json')
)

$thumb = ($CertThumbprint -replace '[^0-9A-Fa-f]','').ToUpper()
# Sanity-check the cert is present + has a private key on this machine.
$cert = Get-ChildItem Cert:\LocalMachine\My, Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $thumb } | Select-Object -First 1
if (-not $cert) { Write-Warning "No certificate with thumbprint $thumb found in LocalMachine\My or CurrentUser\My. Connect will fail until it is installed here." }
elseif (-not $cert.HasPrivateKey) { Write-Warning "Certificate $thumb is present but has NO private key on this machine." }
else { Write-Host "Certificate found: $($cert.Subject) (has private key)" -ForegroundColor Green }

$OutFile = [IO.Path]::GetFullPath($OutFile)
[pscustomobject]@{ appId = $AppId; organization = $Organization; certThumbprint = $thumb } |
    ConvertTo-Json | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "Wrote $OutFile" -ForegroundColor Green
