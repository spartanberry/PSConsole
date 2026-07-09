<#
.SYNOPSIS
    First-run setup for a new PSConsole install. Fills in the pieces that don't ship in the package:
    the local admin login, directory (LDAP/AD) auth + role groups, and the user-provisioning basics.

    Run this ONCE on the server, from the folder this script lives in, after unzipping PSConsole.
    It writes data\users.json, data\config.json and data\provision.json (backing up any that exist).
    It does NOT touch the certificate, cloud apps, or the Windows service - those have their own
    guided helpers, listed at the end.

.DESCRIPTION
    Nothing here is secret at rest except the admin password, which is stored only as a PBKDF2 hash
    (never in plain text) - the same scheme the app uses. Directory passwords are never stored; AD
    login validates against your domain controller at sign-in time.

.PARAMETER DataDir
    Where to write the config. Default: the data\ folder next to this script.

.PARAMETER Force
    Overwrite existing data files without prompting (a timestamped .bak is still made first).

.EXAMPLE
    .\Setup-PSConsole.ps1
#>
[CmdletBinding()]
param(
    [string]$DataDir = (Join-Path $PSScriptRoot 'data'),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Warn($m) { Write-Host $m -ForegroundColor Yellow }
function Head($m) { Write-Host "`n=== $m ===" -ForegroundColor White }

# --- input helpers -----------------------------------------------------------------------------
function Ask([string]$Prompt, [string]$Default = '') {
    $sfx = if ($Default -ne '') { " [$Default]" } else { '' }
    $v = Read-Host ("  " + $Prompt + $sfx)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default } else { return $v.Trim() }
}
function AskBool([string]$Prompt, [bool]$Default) {
    $d = if ($Default) { 'Y/n' } else { 'y/N' }
    $v = Read-Host ("  " + $Prompt + " ($d)")
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return ($v.Trim() -match '^(y|yes|true|1)$')
}
function AskList([string]$Prompt, [string]$Default = '') {
    $v = Ask $Prompt $Default
    if ([string]::IsNullOrWhiteSpace($v)) { return @() }
    return @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
function Read-Plain([string]$Prompt) {
    $sec  = Read-Host -AsSecureString ("  " + $Prompt)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# PBKDF2 hash - identical to the app's Auth.ps1 (120k iterations, SHA-256, 16-byte salt, 32-byte key).
function New-PasswordHash([string]$Password) {
    $salt = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $kdf  = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 120000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $hash = $kdf.GetBytes(32)
    "{0}:{1}:{2}" -f 120000, [Convert]::ToBase64String($salt), [Convert]::ToBase64String($hash)
}

function Save-File([string]$Path, [string]$Json) {
    if (Test-Path $Path) {
        if (-not $Force) {
            if (-not (AskBool "  $([IO.Path]::GetFileName($Path)) exists - overwrite?" $false)) { Warn "  skipped $Path"; return $false }
        }
        $bak = "$Path.bak-" + (Get-Date -Format 'yyyyMMddHHmmss')
        Copy-Item -LiteralPath $Path -Destination $bak -Force
        Warn "  backed up existing -> $([IO.Path]::GetFileName($bak))"
    }
    Set-Content -Path $Path -Value $Json -Encoding UTF8
    Ok "  wrote $Path"
    return $true
}

# --- start -------------------------------------------------------------------------------------
Info "`nPSConsole first-run setup"
Info "Config folder: $DataDir"
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null; Ok "created $DataDir" }

# 1) Local admin account ------------------------------------------------------------------------
Head "1. Local admin account"
Write-Host "  A built-in login so you can reach the app before AD auth is configured."
$adminUser = Ask 'Admin username' 'admin'
$pw = $null
while ($true) {
    $p1 = Read-Plain 'Password'
    $p2 = Read-Plain 'Confirm password'
    if ($p1 -ne $p2)      { Warn '  passwords do not match - try again'; continue }
    if ($p1.Length -lt 8) { Warn '  use at least 8 characters - try again'; continue }
    $pw = $p1; break
}
$userObj = [ordered]@{ username = $adminUser; type = 'local'; role = 'admin'; hash = (New-PasswordHash $pw) }
$pw = $null; $p1 = $null; $p2 = $null
# users.json is a top-level ARRAY - wrap explicitly (WinPS 5.1 unrolls a piped single-element array).
$usersJson = "[`r`n" + ($userObj | ConvertTo-Json -Depth 8) + "`r`n]"
Save-File (Join-Path $DataDir 'users.json') $usersJson | Out-Null

# 2) Directory (AD/LDAP) auth + role groups -----------------------------------------------------
Head "2. Directory login and roles"
Write-Host "  Optional now - you can leave AD off and configure it later in the app under Config."
$ldapEnabled = AskBool 'Enable AD/LDAP login now?' $false
$ldapServer  = Ask 'AD domain FQDN (LDAP server), e.g. example.org' 'example.org'
$ldapPort    = [int](Ask 'LDAP port' '636')
$ldapSsl     = AskBool 'Use LDAPS (SSL)?' $true
Write-Host "  Roles map to AD groups (by group name/CN). Admin = full access; HelpDesk = run + decommission."
$adminGroups = AskList 'Admin AD group name(s), comma-separated' 'PSConsole-Admin'
$hdGroups    = AskList 'HelpDesk AD group name(s), comma-separated' ''
$certThumb   = Ask 'TLS cert thumbprint (blank = set later with Set-TlsCertificate.ps1)' ''
$config = [ordered]@{
    ldapEnabled    = $ldapEnabled
    ldapServer     = $ldapServer
    ldapPort       = $ldapPort
    ldapUseSsl     = $ldapSsl
    ldapBaseDn     = ''
    certThumbprint = $certThumb
    roleMap        = [ordered]@{ admin = $adminGroups; helpdesk = $hdGroups }
    logoFile       = $null
}
Save-File (Join-Path $DataDir 'config.json') ($config | ConvertTo-Json -Depth 8) | Out-Null

# 3) User provisioning basics -------------------------------------------------------------------
Head "3. User provisioning basics"
Write-Host "  Left OFF until you've set up AD create-delegation and your department map (do that in the"
Write-Host "  app under Config > Department mapping). This just seeds the domain-wide values."
$upn        = Ask 'UPN / email suffix for new users, e.g. example.com' 'example.com'
$disabledOu = Ask 'Disabled Accounts OU (full DN)' 'OU=Disabled Accounts,DC=example,DC=org'
$prov = [ordered]@{
    enabled                 = $false
    upnSuffix               = $upn
    supervisorGroup         = 'Supervisors'
    supervisorGroups        = @('Supervisors')
    licenseSkuId            = ''
    usageLocation           = 'US'
    onboardingAutoRun       = $false
    disabledOu              = $disabledOu
    baseGroups              = @()
    onCallGroup             = ''
    onCallExceptDepartments = @()
    departments             = @()
}
Save-File (Join-Path $DataDir 'provision.json') ($prov | ConvertTo-Json -Depth 8) | Out-Null

# --- done + what's next ------------------------------------------------------------------------
Head "Setup complete"
Ok "  Local admin '$adminUser' created; core config written."
Write-Host ""
Info "Next steps (each has its own guided helper):"
Write-Host "  * TLS certificate .......... graph-setup\Set-TlsCertificate.ps1   (HTTPS cert + service restart)"
Write-Host "  * Email notifications ...... graph-setup\Set-SmtpConfig.ps1        (create/decommission emails)"
Write-Host "  * Cloud read (Entra) ....... graph-setup\Set-GraphCredential.ps1   (dashboards / Entra scripts)"
Write-Host "  * Cloud write (onboarding) . graph-setup\Set-GraphWriteCredential.ps1"
Write-Host "  * Exchange Online .......... graph-setup\Set-ExoConfig.ps1         (mail-enabled groups)"
Write-Host "  * Register the Windows service (WinSW) and grant it 'Log on as a service' + private-key read."
Write-Host "  * Finish department mapping in the app: Config > Department mapping, then flip provisioning on."
Write-Host ""
Info "Start it: register/start the PSConsole service (or run app\Start-PSConsole.ps1), browse https://<host>, sign in as '$adminUser'."
