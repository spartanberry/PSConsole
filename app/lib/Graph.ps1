# Graph.ps1 - shared app-only Microsoft Graph read helper for the web app (e.g. the supervisor
# dropdown). Same DPAPI + client-credentials pattern the app\scripts\1x-Entra*.ps1 scripts use.
# zpsconsole has NO cloud rights; auth is via the Entra app registration whose secret lives
# DPAPI-encrypted in data\graph.config.json. Read-only.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-GraphConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'graph.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\graph.config.json' }
}

function Get-GraphToken {
    # cached until ~5 min before expiry
    if ($script:GraphTok -and $script:GraphTokExp -and (Get-Date) -lt $script:GraphTokExp) { return $script:GraphTok }
    $cfgPath = Get-GraphConfigPath
    if (-not (Test-Path $cfgPath)) { throw "Graph config not found at $cfgPath." }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    Add-Type -AssemblyName System.Security
    $secret = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($cfg.secret),$null,'LocalMachine'))
    $body = @{ client_id=$cfg.clientId; scope='https://graph.microsoft.com/.default'; client_secret=$secret; grant_type='client_credentials' }
    $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($cfg.tenantId)/oauth2/v2.0/token" -Body $body
    $script:GraphTok = $r.access_token
    $script:GraphTokExp = (Get-Date).AddSeconds([int]$r.expires_in - 300)
    $script:GraphTok
}

function Invoke-Graph { param([string]$Uri,[switch]$Beta)
    $tok = Get-GraphToken
    $base = if ($Beta) { 'https://graph.microsoft.com/beta' } else { 'https://graph.microsoft.com/v1.0' }
    if ($Uri -notmatch '^https?://') { $Uri = $base + $Uri }
    $h = @{ Authorization = "Bearer $tok"; ConsistencyLevel = 'eventual' }
    $out = New-Object System.Collections.Generic.List[object]
    do {
        $p = Invoke-RestMethod -Method Get -Uri $Uri -Headers $h
        if ($null -ne $p.value) { foreach ($i in $p.value) { $out.Add($i) }; $Uri = $p.'@odata.nextLink' }
        else { $out.Add($p); $Uri = $null }
    } while ($Uri)
    $out
}

# Users that are transitive members of an Entra group (by display name). Empty array if not found.
function Get-EntraGroupUsers {
    param([string]$GroupName,[string[]]$Select = @('displayName','userPrincipalName'))
    $flt = [uri]::EscapeDataString("displayName eq '$($GroupName -replace "'","''")'")
    $grp = @(Invoke-Graph "/groups?`$filter=$flt&`$select=id")
    if (-not $grp -or $grp.Count -eq 0) { return @() }
    $sel = ($Select -join ',')
    @(Invoke-Graph "/groups/$($grp[0].id)/transitiveMembers/microsoft.graph.user?`$select=$sel&`$top=999")
}
