# Defender.ps1 - OPTIONAL add-on: read-only Microsoft Defender for Endpoint (MDE) device inventory.
#
# Reuses the SAME Entra app registration + DPAPI secret as Graph.ps1 (data\graph.config.json), but requests
# a token for the WindowsDefenderATP resource (api.securitycenter.microsoft.com) instead of Graph. The app
# must have the WindowsDefenderATP APPLICATION permission `Machine.Read.All` with admin consent granted.
# Strictly read-only (we only GET /api/machines and related).
#
# Config: data\defender.config.json -> { "enabled": true, "apiBase": "https://api.securitycenter.microsoft.com" }
#   apiBase is the (optionally regional) data host, e.g. https://api-us.securitycenter.microsoft.com. The AAD
#   token audience is always the global https://api.securitycenter.microsoft.com regardless of region.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-DefenderConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'defender.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\defender.config.json' }
}
function Get-DefenderConfig {
    $p = Get-DefenderConfigPath
    if (-not (Test-Path $p)) { return $null }
    try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null }
}
# Enabled AND the shared Graph app creds exist (Defender reuses graph.config.json for client id/secret).
function Test-DefenderConfigured {
    $c = Get-DefenderConfig
    return ([bool]$c -and [bool]$c.enabled -and (Test-Path (Get-GraphConfigPath)))
}
function Get-DefenderApiBase {
    $c = Get-DefenderConfig
    if ($c -and $c.apiBase) { ([string]$c.apiBase).TrimEnd('/') } else { 'https://api.securitycenter.microsoft.com' }
}

# App-only token for the MDE resource, using the shared graph.config.json creds. Cached until ~5 min before expiry.
function Get-DefenderToken {
    if ($script:MdeTok -and $script:MdeTokExp -and (Get-Date) -lt $script:MdeTokExp) { return $script:MdeTok }
    $cfgPath = Get-GraphConfigPath
    if (-not (Test-Path $cfgPath)) { throw "Graph config not found at $cfgPath (the Defender add-on reuses it for app creds)." }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    Add-Type -AssemblyName System.Security
    $secret = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($cfg.secret), $null, 'LocalMachine'))
    $body = @{ client_id = $cfg.clientId; scope = 'https://api.securitycenter.microsoft.com/.default'; client_secret = $secret; grant_type = 'client_credentials' }
    $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($cfg.tenantId)/oauth2/v2.0/token" -Body $body
    $script:MdeTok    = $r.access_token
    $script:MdeTokExp = (Get-Date).AddSeconds([int]$r.expires_in - 300)
    $script:MdeTok
}

# GET an MDE API path (e.g. '/api/machines'), auto-paging on @odata.nextLink. Returns a flat list of records.
function Invoke-Mde {
    param([Parameter(Mandatory)][string]$Path)
    $uri = if ($Path -match '^https?://') { $Path } else { (Get-DefenderApiBase) + $Path }
    $tok = Get-DefenderToken
    $h = @{ Authorization = "Bearer $tok" }
    $out = New-Object System.Collections.Generic.List[object]
    do {
        $p = Invoke-RestMethod -Method Get -Uri $uri -Headers $h
        if ($null -ne $p.value) { foreach ($i in $p.value) { $out.Add($i) }; $uri = [string]$p.'@odata.nextLink' }
        else { $out.Add($p); $uri = $null }
    } while ($uri)
    $out
}

# MDE timestamps are ISO-8601 UTC strings (e.g. 2026-07-15T12:34:56.78Z). Render LOCAL at the source so a
# catalog script never emits a raw DateTime (the WinPS 5.1 ConvertTo-Json /Date(ms)/ trap).
function Format-MdeDate {
    param($Iso)
    if (-not $Iso) { return '' }
    try { ([DateTimeOffset]::Parse([string]$Iso)).LocalDateTime.ToString('MM/dd/yyyy h:mm tt') } catch { [string]$Iso }
}

# Defender for Endpoint alerts (needs the WindowsDefenderATP Alert.Read.All app permission, in addition to
# Machine.Read.All). Returns @{ ok; error; alerts=@(...) } - normalized, newest first, dates rendered local.
# -ActiveOnly keeps New/InProgress; -Severity filters (e.g. 'High','Medium'). Never throws.
function Get-DefenderAlerts {
    param([int]$Days = 30, [switch]$ActiveOnly, [string[]]$Severity)
    if (-not (Test-DefenderConfigured)) { return @{ ok = $false; error = 'Defender add-on is not configured (data\defender.config.json).'; alerts = @() } }
    $since = (Get-Date).AddDays(-[math]::Abs($Days)).ToString('yyyy-MM-ddTHH:mm:ssZ')
    try {
        $raw = @(Invoke-Mde "/api/alerts?`$filter=alertCreationTime ge $since")
    } catch {
        $m = $_.Exception.Message; if ($_.ErrorDetails.Message) { $m = $_.ErrorDetails.Message }
        return @{ ok = $false; error = $m; alerts = @() }
    }
    $sev = @($Severity)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($a in ($raw | Sort-Object @{ e = { try { [datetimeoffset]$_.alertCreationTime } catch { [datetimeoffset]::MinValue } }; Descending = $true })) {
        $st = [string]$a.status
        if ($ActiveOnly -and $st -ne 'New' -and $st -ne 'InProgress') { continue }
        if ($sev.Count -and ($sev -notcontains [string]$a.severity)) { continue }
        $rows.Add([pscustomobject]@{
            Severity        = [string]$a.severity
            Status          = $st
            Title           = [string]$a.title
            Category        = [string]$a.category
            Device          = [string]$a.computerDnsName
            DetectionSource = [string]$a.detectionSource
            Created         = Format-MdeDate $a.alertCreationTime
            CreatedRaw      = [string]$a.alertCreationTime
            Id              = [string]$a.id
        })
    }
    @{ ok = $true; alerts = $rows.ToArray() }
}
