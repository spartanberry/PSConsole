# ExchangeOnline.ps1 - app-only (certificate) Exchange Online connection for the onboarding steps
# Graph cannot do: adding members to mail-enabled security groups and distribution lists via
# Add-DistributionGroupMember. Config in data\exo.config.json: { appId, organization, certThumbprint }.
#
# The certificate's PRIVATE KEY must live in a cert store the PSConsole service account can read
# (LocalMachine\My with read granted to the service account, or the service account's CurrentUser\My).
# There is no secret to store - app-only EXO auth is certificate-based.

function Get-ExoConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'exo.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\exo.config.json' }
}
function Test-ExoConfigured { Test-Path (Get-ExoConfigPath) }

function Connect-Exo {
    if ($script:ExoConnected) { return $true }
    $cfgPath = Get-ExoConfigPath
    if (-not (Test-Path $cfgPath)) { throw "EXO config not found at $cfgPath. Run graph-setup\Set-ExoConfig.ps1 on this server." }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    # -CommandName limits the REST-backed cmdlets pulled down, so connect is faster/lighter.
    Connect-ExchangeOnline -AppId $cfg.appId -Organization $cfg.organization -CertificateThumbprint $cfg.certThumbprint `
        -ShowBanner:$false -CommandName Add-DistributionGroupMember,Get-DistributionGroupMember -ErrorAction Stop | Out-Null
    $script:ExoConnected = $true
    $true
}

function Disconnect-Exo {
    if ($script:ExoConnected) {
        try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}
        $script:ExoConnected = $false
    }
}

# Add a user (by UPN / primary SMTP) to a mail-enabled security group or distribution list. Idempotent.
function Add-ExoGroupMember {
    param([string]$GroupName,[string]$UserUpn)
    try {
        Add-DistributionGroupMember -Identity $GroupName -Member $UserUpn -BypassSecurityGroupManagerCheck -ErrorAction Stop
        return @{ ok=$true }
    } catch {
        $m = "$($_.Exception.Message)"
        if ($m -match 'already a member') { return @{ ok=$true; note='already a member' } }
        return @{ ok=$false; error=$m }
    }
}
