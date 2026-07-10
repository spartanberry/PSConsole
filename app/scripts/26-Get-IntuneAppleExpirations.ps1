<#
.SYNOPSIS  Apple token/cert expirations that silently break iOS/macOS management: APNs push cert, VPP tokens, ADE/DEP tokens.
.CATEGORY  Intune
.NOTES     Graph app perms: DeviceManagementServiceConfig.Read.All. Read-only. -Days sets the "expiring soon" flag window (default 60).
.ROLE      HelpDesk
#>
[CmdletBinding()]
param([int]$Days = 60)
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

$rows = New-Object System.Collections.Generic.List[object]
function Add-Token($Type,$Identity,$Expires,$State) {
    $daysLeft = $null; $status = 'OK'
    if ($Expires) {
        $daysLeft = [math]::Round(([datetime]$Expires - (Get-Date)).TotalDays,0)
        $status = if ($daysLeft -lt 0) { 'EXPIRED' } elseif ($daysLeft -le $Days) { "Expiring ($daysLeft d)" } else { 'OK' }
    }
    $rows.Add([PSCustomObject]@{ TokenType=$Type; Identity=$Identity; Expires=$Expires; DaysLeft=$daysLeft; State=$State; Status=$status })
}
function Get-HttpCode($err) { $c = 0; try { $c = [int]$err.Exception.Response.StatusCode } catch {}; $c }
function Try-Source([scriptblock]$Get,$Type) {
    for ($attempt = 1; ; $attempt++) {
        try { & $Get; return }
        catch {
            $code = Get-HttpCode $_; $msg = $_.Exception.Message
            if ($code -eq 503 -and $attempt -le 3) { Start-Sleep -Seconds 2; continue }   # transient
            # 404/400/501 just mean this token type isn't set up in the tenant - not a real error.
            $status = if ($code -in 404,400,501) { 'not configured' } else { "query failed: $msg" }
            $rows.Add([PSCustomObject]@{ TokenType=$Type; Identity=''; Expires=''; DaysLeft=$null; State=''; Status=$status })
            return
        }
    }
}

# APNs push certificate (singleton; 404 when never uploaded)
Try-Source { $c = Invoke-Graph '/deviceManagement/applePushNotificationCertificate'; if ($c) { Add-Token 'APNs push cert' $c.appleIdentifier $c.expirationDateTime '' } } 'APNs push cert'
# VPP tokens
Try-Source { foreach ($t in @(Invoke-Graph '/deviceManagement/vppTokens')) { Add-Token 'VPP token' ($t.organizationName + ' / ' + $t.appleId) $t.expirationDateTime $t.state } } 'VPP token'
# ADE / DEP enrollment program tokens (beta)
Try-Source { foreach ($t in @(Invoke-Graph '/deviceManagement/depOnboardingSettings' -Beta)) { Add-Token 'ADE/DEP token' ($t.tokenName + ' / ' + $t.appleIdentifier) $t.tokenExpirationDateTime '' } } 'ADE/DEP token'

# Soonest-expiring first; nulls (not configured) at the end.
$rows | Sort-Object @{ E = { if ($null -eq $_.DaysLeft) { [double]::MaxValue } else { $_.DaysLeft } } }
