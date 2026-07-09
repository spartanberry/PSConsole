<#
.SYNOPSIS  360-degree lookup for a single Entra user: status, type, licenses, MFA, last sign-in, manager.
.NOTES     Graph app perms: User.Read.All, Directory.Read.All, AuditLog.Read.All. Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$UserPrincipalName)
#region Graph bootstrap (app-only client-credentials; reads data\graph.config.json)
# zpsconsole has NO cloud rights; auth is via an Entra app registration, not this account.
# The client secret is read from a DPAPI-encrypted config file, never from a parameter.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Get-GraphToken {
    $cfgPath = if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'graph.config.json' }
               else { Join-Path $PSScriptRoot '..\..\data\graph.config.json' }
    if (-not (Test-Path $cfgPath)) { throw "Graph config not found at $cfgPath. Run graph-setup\Set-GraphCredentials.ps1 on the server first." }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    Add-Type -AssemblyName System.Security
    $secret = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($cfg.secret),$null,'LocalMachine'))
    $body = @{ client_id=$cfg.clientId; scope='https://graph.microsoft.com/.default'; client_secret=$secret; grant_type='client_credentials' }
    (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($cfg.tenantId)/oauth2/v2.0/token" -Body $body).access_token
}
function Invoke-Graph { param([string]$Uri,[switch]$Beta)
    if (-not $script:tok) { $script:tok = Get-GraphToken }
    $base = if ($Beta) { 'https://graph.microsoft.com/beta' } else { 'https://graph.microsoft.com/v1.0' }
    if ($Uri -notmatch '^https?://') { $Uri = $base + $Uri }
    $h = @{ Authorization = "Bearer $script:tok"; ConsistencyLevel = 'eventual' }
    $out = New-Object System.Collections.Generic.List[object]
    do {
        $p = Invoke-RestMethod -Method Get -Uri $Uri -Headers $h
        if ($null -ne $p.value) { foreach ($i in $p.value) { $out.Add($i) }; $Uri = $p.'@odata.nextLink' }
        else { $out.Add($p); $Uri = $null }
    } while ($Uri)
    $out
}
#endregion

# signInActivity can't be $select'd when addressing a user by UPN (Graph requires the object id/GUID),
# so query the collection with a filter instead - that form supports signInActivity in one call.
$u = (Invoke-Graph ("/users?`$filter=userPrincipalName eq '$UserPrincipalName'&`$select=displayName,userPrincipalName,accountEnabled,userType,jobTitle,department,createdDateTime,signInActivity,assignedLicenses,onPremisesSyncEnabled,id"))[0]
if (-not $u) { throw "No user found with UPN '$UserPrincipalName'." }
$skus = @{}; Invoke-Graph '/subscribedSkus' | ForEach-Object { $skus[$_.skuId] = $_.skuPartNumber }
$lic = (@($u.assignedLicenses) | ForEach-Object { $skus[$_.skuId] }) -join ', '
$mfa = $null; try { $mfa = (Invoke-Graph "/reports/authenticationMethods/userRegistrationDetails/$($u.id)")[0] } catch {}
$mgr = $null; try { $mgr = (Invoke-Graph "/users/$UserPrincipalName/manager")[0].userPrincipalName } catch {}
[PSCustomObject]@{
    UserPrincipalName = $u.userPrincipalName
    DisplayName       = $u.displayName
    Enabled           = $u.accountEnabled
    Type              = $u.userType
    Department        = $u.department
    Title             = $u.jobTitle
    Created           = $u.createdDateTime
    LastSignIn        = $u.signInActivity.lastSignInDateTime
    Licenses          = $lic
    MFARegistered     = $mfa.isMfaRegistered
    Manager           = $mgr
    OnPremSynced      = $u.onPremisesSyncEnabled
}
