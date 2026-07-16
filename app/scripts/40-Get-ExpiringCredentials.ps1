<#
.SYNOPSIS  Expiration hub: consolidates the credentials that silently break integrations when they lapse - Entra app-registration client secrets & certificates, plus Intune's Apple APNs push cert, VPP tokens and ADE/DEP tokens - into one list, soonest-expiring first, flagged OK / Expiring / EXPIRED.
.RUNEXAMPLE  Days=60
.CATEGORY  Expirations
.NOTES     Graph app perms: Application.Read.All (app secrets/certs) + DeviceManagementServiceConfig.Read.All (Apple tokens). Read-only. -Days sets the "expiring soon" window (default 60). Only credential METADATA is read - never secret values.
.ROLE      Admin
#>
[CmdletBinding()]
param([int]$Days = 60)
#region Graph bootstrap (app-only client-credentials; reads data\graph.config.json)
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
function Add-Item($Type,$Identity,$Expires,$Detail) {
    $daysLeft = $null; $status = 'no expiry'
    if ($Expires) {
        $daysLeft = [int][math]::Round(([datetime]$Expires - (Get-Date)).TotalDays,0)
        $status = if ($daysLeft -lt 0) { 'EXPIRED' } elseif ($daysLeft -le $Days) { "Expiring ($daysLeft d)" } else { 'OK' }
    }
    $rows.Add([PSCustomObject]@{ Type=$Type; Identity=$Identity; Expires=$(if($Expires){([datetime]$Expires).ToString('yyyy-MM-dd')}else{''}); DaysLeft=$daysLeft; Status=$status; Detail=$Detail })
}
function Get-HttpCode($err) { $c = 0; try { $c = [int]$err.Exception.Response.StatusCode } catch {}; $c }
function Try-Source([scriptblock]$Get,$Type) {
    for ($attempt = 1; ; $attempt++) {
        try { & $Get; return }
        catch {
            $code = Get-HttpCode $_; $msg = $_.Exception.Message
            if ($code -eq 503 -and $attempt -le 3) { Start-Sleep -Seconds 2; continue }
            $status = if ($code -in 404,400,501) { 'not configured' } else { "query failed: $msg" }
            $rows.Add([PSCustomObject]@{ Type=$Type; Identity=''; Expires=''; DaysLeft=$null; Status=$status; Detail='' })
            return
        }
    }
}

# --- Entra app registrations: client secrets + certificates ---
Try-Source {
    foreach ($app in @(Invoke-Graph '/applications?$select=displayName,appId,passwordCredentials,keyCredentials&$top=200')) {
        foreach ($pw in @($app.passwordCredentials)) {
            $label = if ($pw.displayName) { $pw.displayName } else { "keyId $($pw.keyId)" }
            Add-Item 'App secret' "$($app.displayName) / $label" $pw.endDateTime "appId $($app.appId)"
        }
        foreach ($kc in @($app.keyCredentials)) {
            $label = if ($kc.displayName) { $kc.displayName } else { "$($kc.usage) $($kc.keyId)" }
            Add-Item 'App certificate' "$($app.displayName) / $label" $kc.endDateTime "appId $($app.appId)"
        }
    }
} 'App secret'

# --- Intune Apple tokens/certs ---
Try-Source { $c = Invoke-Graph '/deviceManagement/applePushNotificationCertificate'; if ($c) { Add-Item 'APNs push cert' $c.appleIdentifier $c.expirationDateTime '' } } 'APNs push cert'
Try-Source { foreach ($t in @(Invoke-Graph '/deviceManagement/vppTokens')) { Add-Item 'VPP token' ($t.organizationName + ' / ' + $t.appleId) $t.expirationDateTime $t.state } } 'VPP token'
Try-Source { foreach ($t in @(Invoke-Graph '/deviceManagement/depOnboardingSettings' -Beta)) { Add-Item 'ADE/DEP token' ($t.tokenName + ' / ' + $t.appleIdentifier) $t.tokenExpirationDateTime '' } } 'ADE/DEP token'

# Soonest-expiring first; items with no expiry / not-configured sink to the bottom.
$rows | Sort-Object @{ E = { if ($null -eq $_.DaysLeft) { [double]::MaxValue } else { $_.DaysLeft } } }
