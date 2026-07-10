<#
.SYNOPSIS  Recent failed interactive sign-ins (default last 24h). Optional -UserPrincipalName to scope to one user.
.CATEGORY  Entra ID
.NOTES     Graph app perms: AuditLog.Read.All. Needs Entra ID P1+. Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param([int]$Hours = 24, [string]$UserPrincipalName)
#region Graph bootstrap (app-only client-credentials; reads data\graph.config.json)
# zpsconsole has NO cloud rights; auth is via an Entra app registration, not this account.
# The client secret is read from a DPAPI-encrypted config file, never from a parameter.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Get-GraphToken {
    $cfgPath = if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'graph.config.json' }
               else { Join-Path $PSScriptRoot '..\..\data\graph.config.json' }
    if (-not (Test-Path $cfgPath)) { throw "Graph config not found at $cfgPath. Run graph-setup\Set-GraphCredential.ps1 on the server first." }
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

# Filter time server-side (reliable); filter failures client-side (avoids advanced-query pitfalls).
# Invoke-Graph auto-pages, so the whole window is covered.
$since = (Get-Date).ToUniversalTime().AddHours(-$Hours).ToString('yyyy-MM-ddTHH:mm:ssZ')
$filter = "createdDateTime ge $since"
if ($UserPrincipalName) { $filter += " and userPrincipalName eq '$UserPrincipalName'" }
Invoke-Graph ("/auditLogs/signIns?`$filter=$filter") |
Where-Object { $_.status.errorCode -ne 0 } |
ForEach-Object {
    [PSCustomObject]@{
        Time      = $_.createdDateTime
        UPN       = $_.userPrincipalName
        App       = $_.appDisplayName
        ErrorCode = $_.status.errorCode
        Reason    = $_.status.failureReason
        IP        = $_.ipAddress
        Location  = (@($_.location.city, $_.location.countryOrRegion) -join ', ')
        ClientApp = $_.clientAppUsed
    }
} | Sort-Object Time -Descending
