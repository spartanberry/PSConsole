<#
.SYNOPSIS  Members of an Entra (Azure AD) group with their name and job title - defaults to "Case Managers".
.NOTES     Graph app perms: GroupMember.Read.All (or Directory.Read.All), User.Read.All. Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
# Type the group in the Run params box as  GroupName=<group>  (or the shorter  Group=<group> ).
# Spaces are fine, e.g.  Group=Home Based Services . Blank falls back to Case Managers.
param([Alias('Group','Name')][string]$GroupName = 'Case Managers')
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

# 1) Resolve the group by display name (exact match). Escape single quotes for OData and URL-encode
# the whole filter value so names with & / # don't corrupt the query string.
if ([string]::IsNullOrWhiteSpace($GroupName)) { $GroupName = 'Case Managers' }
$GroupName = $GroupName.Trim()
$flt = [uri]::EscapeDataString("displayName eq '$($GroupName -replace "'","''")'")
$groups = @(Invoke-Graph "/groups?`$filter=$flt&`$select=id,displayName")
if ($groups.Count -eq 0) { throw "No Entra group named '$GroupName' was found." }
if ($groups.Count -gt 1) { Write-Warning "$($groups.Count) groups are named '$GroupName'; listing members of the first (id $($groups[0].id))." }
$grp = $groups[0]

# 2) List user members (transitive, so nested-group members are included too).
try {
    $members = @(Invoke-Graph "/groups/$($grp.id)/transitiveMembers/microsoft.graph.user?`$select=displayName,jobTitle,userPrincipalName,mail,accountEnabled&`$top=999")
} catch {
    if ("$($_.Exception.Message)" -match 'Authorization_RequestDenied|Forbidden|\b403\b') {
        throw "Access denied reading group members. The Graph app registration needs GroupMember.Read.All (or Directory.Read.All) with admin consent."
    }
    throw
}

$members | ForEach-Object {
    [PSCustomObject]@{
        Name     = $_.displayName
        JobTitle = if ($_.jobTitle) { $_.jobTitle } else { '(none)' }
        UPN      = $_.userPrincipalName
        Email    = $_.mail
        Enabled  = $_.accountEnabled
    }
} | Sort-Object JobTitle, Name
