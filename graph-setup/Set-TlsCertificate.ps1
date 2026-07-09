<#
.SYNOPSIS
    Point PSConsole's HTTPS site at a TLS certificate. Run ON the PSConsole server, elevated
    (Run as Administrator). This is the supported way to add or replace the site certificate -
    no code editing required.

    It will, in one guided pass:
      1. (optional) import a .pfx into the machine's Personal store (LocalMachine\My),
      2. validate the certificate (private key present, not expired, hostname covered),
      3. grant the PSConsole service account read access to the private key,
      4. write the thumbprint into data\config.json (overrides the install default), and
      5. restart the service and verify the new certificate is being served.

    PSConsole reads the cert by THUMBPRINT from LocalMachine\My at startup, so a restart is
    required for a cert change to take effect - this script handles that for you.

.PARAMETER PfxPath
    Path to a .pfx/.p12 file to import (must contain the PRIVATE KEY). You'll be prompted for its
    password. Omit if the certificate is already installed in LocalMachine\My.

.PARAMETER Thumbprint
    Use a certificate ALREADY installed in LocalMachine\My, by thumbprint (spaces/colons ok).
    Omit both -PfxPath and -Thumbprint to pick one interactively from a list.

.PARAMETER Hostname
    The public hostname users browse to (e.g. psconsole.example.org). Optional but recommended:
    the script warns if the cert's SAN doesn't cover it, and verifies it via SNI after restart.

.PARAMETER ServiceAccount
    The Windows identity the PSConsole service runs as - it needs Read on the private key.
    Default: example\zpsconsole.

.PARAMETER ServiceName
    The Windows service name. Default: PSConsole.

.PARAMETER NoRestart
    Write everything but don't restart the service (change takes effect on the next restart).

.EXAMPLE
    # Import a new wildcard .pfx and make it live:
    .\Set-TlsCertificate.ps1 -PfxPath C:\temp\wildcard.pfx -Hostname psconsole.example.org

.EXAMPLE
    # Use a cert that's already installed:
    .\Set-TlsCertificate.ps1 -Thumbprint EFE4EAC95B8CBB2B46F88AC59E9C5C583D385BF4

.EXAMPLE
    # Pick interactively from the installed certs:
    .\Set-TlsCertificate.ps1
#>
[CmdletBinding()]
param(
    [string]$PfxPath,
    [string]$Thumbprint,
    [string]$Hostname,
    [string]$ServiceAccount = 'example\zpsconsole',
    [string]$ServiceName    = 'PSConsole',
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Warn($m) { Write-Host $m -ForegroundColor Yellow }

# --- must be elevated: importing keys, editing the key ACL, and restarting the service all need it
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) { throw "Run this in an ELEVATED PowerShell (Run as Administrator)." }

$dataDir = Join-Path $PSScriptRoot '..\data'
if (-not (Test-Path $dataDir)) { throw "Data dir not found: $dataDir - run this from the PSConsole graph-setup folder." }
$configPath = Join-Path $dataDir 'config.json'

# --- 1. obtain a thumbprint --------------------------------------------------------------------
if ($PfxPath) {
    if (-not (Test-Path $PfxPath)) { throw "PFX not found: $PfxPath" }
    Info "Importing $PfxPath into LocalMachine\My ..."
    $pw = Read-Host -AsSecureString "Password for the .pfx"
    $imported = Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation Cert:\LocalMachine\My -Password $pw
    $Thumbprint = $imported.Thumbprint
    Ok "Imported: $($imported.Subject)  [$Thumbprint]"
}
elseif (-not $Thumbprint) {
    # interactive picker
    $certs = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object HasPrivateKey | Sort-Object NotAfter -Descending)
    if (-not $certs.Count) { throw "No certificates with a private key found in LocalMachine\My. Use -PfxPath to import one." }
    Write-Host ""
    Info "Certificates installed in LocalMachine\My (with a private key):"
    for ($i = 0; $i -lt $certs.Count; $i++) {
        $c = $certs[$i]
        $sans = ($c.DnsNameList | ForEach-Object { $_.ToString() }) -join ', '
        "  [{0}] {1,-34} exp {2:yyyy-MM-dd}  {3}" -f ($i+1), $c.Subject, $c.NotAfter, $sans | Write-Host
    }
    Write-Host ""
    $sel = Read-Host "Pick a certificate by number (1-$($certs.Count))"
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $certs.Count) { throw "Invalid selection." }
    $Thumbprint = $certs[$idx-1].Thumbprint
}

# normalize: strip spaces/colons, upper-case
$Thumbprint = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpper()

# --- 2. validate -------------------------------------------------------------------------------
$cert = Get-Item "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction SilentlyContinue
if (-not $cert) { throw "No certificate with thumbprint $Thumbprint is in LocalMachine\My. Import it first (see -PfxPath)." }
if (-not $cert.HasPrivateKey) { throw "That certificate has NO private key - HTTPS needs the private key. Re-import the .pfx with its key." }
Ok "Selected: $($cert.Subject)  [$Thumbprint]"

$sanList = @($cert.DnsNameList | ForEach-Object { $_.ToString() })
Info ("SANs: " + ($sanList -join ', '))
if ($cert.NotAfter -lt (Get-Date)) { throw "That certificate EXPIRED on $($cert.NotAfter). Use a current one." }
if ($cert.NotAfter -lt (Get-Date).AddDays(30)) { Warn "Heads up: this certificate expires soon ($($cert.NotAfter))." }

if ($Hostname) {
    $covered = $false
    foreach ($n in $sanList) {
        if ($n -eq $Hostname) { $covered = $true; break }
        if ($n.StartsWith('*.') -and ($Hostname -like ($n -replace '^\*', '*')) -and
            (($Hostname -split '\.').Count -eq (($n -split '\.').Count))) { $covered = $true; break }
    }
    if ($covered) { Ok "Certificate covers $Hostname." }
    else { Warn "WARNING: none of the cert's SANs appear to cover '$Hostname'. Browsers may show a name-mismatch warning." }
}

# --- 3. grant the service account Read on the private key --------------------------------------
Info "Granting '$ServiceAccount' Read on the private key ..."
try {
    $keyPath = $null
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    if ($rsa -is [System.Security.Cryptography.RSACng]) {
        # CNG key file
        $keyPath = Join-Path $env:ProgramData ("Microsoft\Crypto\Keys\" + $rsa.Key.UniqueName)
    } elseif ($cert.PrivateKey) {
        # legacy CAPI key file
        $keyPath = Join-Path $env:ProgramData ("Microsoft\Crypto\RSA\MachineKeys\" + $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName)
    }
    if ($keyPath -and (Test-Path $keyPath)) {
        $acl  = Get-Acl $keyPath
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($ServiceAccount, 'Read', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -Path $keyPath -AclObject $acl
        Ok "Private-key Read granted to $ServiceAccount."
    } else {
        Warn "Could not locate the private-key file automatically. Grant it manually: certlm.msc -> the cert -> All Tasks -> Manage Private Keys -> add '$ServiceAccount' = Read."
    }
} catch {
    Warn "Automatic key-ACL grant failed ($($_.Exception.Message))."
    Warn "Grant it manually: certlm.msc -> the cert -> All Tasks -> Manage Private Keys -> add '$ServiceAccount' = Read."
}

# --- 4. write the thumbprint into config.json --------------------------------------------------
if (Test-Path $configPath) { $cfg = Get-Content $configPath -Raw | ConvertFrom-Json }
else { $cfg = [pscustomobject]@{} }
$cfg | Add-Member -NotePropertyName certThumbprint -NotePropertyValue $Thumbprint -Force
($cfg | ConvertTo-Json -Depth 10) | Set-Content -Path $configPath -Encoding UTF8
Ok "Wrote certThumbprint to $configPath"

# --- 5. restart + verify -----------------------------------------------------------------------
if ($NoRestart) {
    Warn "Skipping restart (-NoRestart). The new certificate takes effect next time '$ServiceName' restarts."
    return
}
Info "Restarting service '$ServiceName' ..."
Restart-Service -Name $ServiceName -Force
Start-Sleep -Seconds 6

# read back what the site is actually serving on 443
try {
    $verifyName = if ($Hostname) { $Hostname } else { 'localhost' }
    $tcp = [System.Net.Sockets.TcpClient]::new(); $tcp.Connect('localhost', 443)
    $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, ({ $true } -as [System.Net.Security.RemoteCertificateValidationCallback]))
    $ssl.AuthenticateAsClient($verifyName)
    $served = $ssl.RemoteCertificate.GetCertHashString()
    $ssl.Dispose(); $tcp.Close()
    if ($served -eq $Thumbprint) {
        Ok  "Verified: the site is now serving $($cert.Subject) [$served]."
        if ($Hostname) { Ok "Browse to: https://$Hostname" }
    } else {
        Warn "Service is up but is serving a DIFFERENT cert ($served). Check for another certThumbprint source or a bind error in the service log."
    }
} catch {
    Warn "Service restarted but the TLS check failed: $($_.Exception.Message)"
    Warn "Most common cause: '$ServiceAccount' can't read the private key. Re-check step 3 (Manage Private Keys)."
}
