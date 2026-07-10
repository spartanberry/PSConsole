<#
.SYNOPSIS  Health board for Intune management connectors: Exchange, NDES/SCEP, Managed Google Play, MTD, and device-mgmt partners.
.CATEGORY  Intune
.NOTES     Graph app perms: DeviceManagementServiceConfig.Read.All + DeviceManagementConfiguration.Read.All. Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param([int]$StaleDays = 7)
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
# Health from a state string + a last-activity timestamp: error/disconnected/inactive -> ERROR;
# no recent heartbeat -> Stale; otherwise OK.
function Get-Health([string]$State,$LastSeen) {
    $bad = @('disconnected','inactive','error','terminated','rejected','unresponsive','unavailable','notBound','unbind')
    if ($bad -contains $State) { return 'ERROR' }
    if ($LastSeen) { $age = ((Get-Date) - [datetime]$LastSeen).TotalDays; if ($age -gt $StaleDays) { return "Stale ($([math]::Round($age,0))d)" } }
    return 'OK'
}
function Add-Row($Connector,$Name,$State,$LastSeen) {
    $rows.Add([PSCustomObject]@{ Connector=$Connector; Name=$Name; State=$State
        LastActivity=$(if($LastSeen){$LastSeen}else{''}); Health=(Get-Health $State $LastSeen) })
}
function Get-HttpCode($err) { $c = 0; try { $c = [int]$err.Exception.Response.StatusCode } catch {}; $c }
# Each source is independent - a missing/unpermitted one degrades to an info row, not a failure.
# 503 is a transient Graph hiccup (retry); 404/400 mean the connector isn't set up; 501 means the
# endpoint isn't applicable to this tenant (e.g. no on-prem Exchange connector) - all shown cleanly.
function Try-Source($Connector,[scriptblock]$Get) {
    for ($attempt = 1; ; $attempt++) {
        try { & $Get; return }
        catch {
            $code = Get-HttpCode $_; $msg = $_.Exception.Message
            if ($code -eq 503 -and $attempt -le 3) { Start-Sleep -Seconds 2; continue }
            $note = if ($code -in 404,400) { 'not configured' } elseif ($code -eq 501) { 'not applicable in this tenant' } else { $msg }
            $rows.Add([PSCustomObject]@{ Connector=$Connector; Name=''; State='(unavailable)'; LastActivity=''; Health=$note })
            return
        }
    }
}

Try-Source 'Exchange' {
    foreach ($c in @(Invoke-Graph '/deviceManagement/exchangeConnectors')) { Add-Row 'Exchange' $c.serverName $c.status $c.lastSyncDateTime }
}
Try-Source 'NDES/SCEP' {
    foreach ($c in @(Invoke-Graph '/deviceManagement/ndesConnectors' -Beta)) { Add-Row 'NDES/SCEP' $c.displayName $c.state $c.lastConnectionDateTime }
}
Try-Source 'Managed Google Play' {
    $a = Invoke-Graph '/deviceManagement/androidManagedStoreAccountEnterpriseSettings' -Beta | Select-Object -First 1
    if ($a) { Add-Row 'Managed Google Play' $a.ownerUserPrincipalName $a.bindStatus $a.lastAppSyncDateTime }
}
Try-Source 'Mobile Threat Defense' {
    foreach ($c in @(Invoke-Graph '/deviceManagement/mobileThreatDefenseConnectors')) { Add-Row 'Mobile Threat Defense' $c.id $c.partnerState $c.lastHeartbeatDateTime }
}
Try-Source 'Device Mgmt Partner' {
    foreach ($c in @(Invoke-Graph '/deviceManagement/deviceManagementPartners')) {
        if ($c.partnerState -and $c.partnerState -ne 'unknown') { Add-Row 'Device Mgmt Partner' $c.partnerAppType $c.partnerState $c.lastHeartbeatDateTime }
    }
}

if (-not $rows.Count) { $rows.Add([PSCustomObject]@{ Connector='(none)'; Name=''; State='No connectors configured'; LastActivity=''; Health='' }) }
$rows | Sort-Object Connector
