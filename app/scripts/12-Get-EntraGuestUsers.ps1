<#
.SYNOPSIS  Guest (B2B) accounts with invite state and last sign-in - for access reviews / cleanup.
.NOTES     Graph app perms: User.Read.All, AuditLog.Read.All. Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param([int]$StaleDays = 0)  # 0 = all guests; >0 = only guests with no sign-in in N days
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

$now = Get-Date
Invoke-Graph "/users?`$filter=userType eq 'Guest'&`$select=displayName,userPrincipalName,mail,createdDateTime,externalUserState,signInActivity&`$top=999" |
ForEach-Object {
    $last = $_.signInActivity.lastSignInDateTime
    $daysIdle = if ($last) { [math]::Round(($now - [datetime]$last).TotalDays,0) } else { $null }
    [PSCustomObject]@{
        DisplayName = $_.displayName
        UPN         = $_.userPrincipalName
        Email       = $_.mail
        InviteState = $_.externalUserState
        Created     = $_.createdDateTime
        LastSignIn  = $last
        DaysIdle    = $daysIdle
    }
} | Where-Object { $StaleDays -le 0 -or $_.DaysIdle -eq $null -or $_.DaysIdle -ge $StaleDays } | Sort-Object DaysIdle -Descending
