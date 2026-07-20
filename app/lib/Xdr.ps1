# Xdr.ps1 - Microsoft Defender XDR / Graph Security alerts (alerts_v2): Defender for Office 365 (email),
# Defender for Identity, DLP, etc. This is SEPARATE from the endpoint (Defender for Endpoint / WindowsDefenderATP)
# feed in Defender.ps1 - deliberately kept distinct so endpoint alerts stay clean. Read-only; reuses the shared
# Graph app (data\graph.config.json) which holds SecurityAlert.Read.All.
#
# Noise handling (a PHI-heavy tenant generates lots of operational/DLP chatter):
#   - a config-driven TITLE suppression list drops user/admin workflow + housekeeping alerts, and
#   - DLP is put in its OWN bucket (near-always false positive) so it never drives the security signal.
# Both are tunable in data\config.json under { "xdrAlerts": { "suppressTitles": [ ... ] } } with no code change.

function Test-XdrConfigured {
    # XDR reads via Microsoft Graph (same app as Graph.ps1), so it's available whenever Graph is configured.
    try { Test-Path (Get-GraphConfigPath) } catch { $false }
}

# Default operational-noise suppressions (case-insensitive substring match on the alert title). Seeded from the
# 30-day noise analysis: user junk votes, quarantine-release requests, admin investigations, TABL housekeeping.
$script:XdrDefaultSuppress = @(
    'reported by user as not junk'
    'reported by user as junk'
    'requested to release a quarantined'
    'Admin triggered manual investigation'
    'Administrative action submitted'
    'Tenant Allow/Block List'
)

function Get-XdrSuppressTitles {
    $cfg = Get-Store config
    $s = $null
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'xdrAlerts') -and $cfg.xdrAlerts -and
        ($cfg.xdrAlerts.PSObject.Properties.Name -contains 'suppressTitles')) { $s = @($cfg.xdrAlerts.suppressTitles) }
    if ($null -eq $s -or -not @($s).Count) { $s = $script:XdrDefaultSuppress }
    @(@($s) | Where-Object { $_ })
}

# Friendly product name from the alert's serviceSource.
function ConvertTo-XdrSource {
    param([string]$ServiceSource)
    switch -Regex ($ServiceSource) {
        'DataLossPrevention'   { 'DLP'; break }
        'DefenderForOffice365' { 'Office 365 (email)'; break }
        'DefenderForIdentity'  { 'Identity'; break }
        'DefenderForEndpoint'  { 'Endpoint'; break }
        'DefenderForCloudApps' { 'Cloud Apps'; break }
        '365Defender'          { 'M365 Defender'; break }
        default                { if ($ServiceSource) { [string]$ServiceSource } else { '(unknown)' } }
    }
}

# Pull unified Graph Security alerts for the last N days (bounded paging). Returns
# @{ ok; error; alerts=@({ Source; Severity; Status; Title; Category; Created(string); Bucket; Suppressed }) }
# newest first. Dates are preformatted local strings (the /run JSON path would otherwise hit the WinPS 5.1
# /Date(ms)/ trap). Suppression + DLP bucketing are applied here so every caller sees a consistent view.
function Get-XdrAlerts {
    param([int]$Days = 30)
    if (-not (Test-XdrConfigured)) { return @{ ok = $false; error = 'Graph app not configured (data\graph.config.json).'; alerts = @() } }
    try {
        $tok = Get-GraphToken
        $h = @{ Authorization = "Bearer $tok" }
        $since = (Get-Date).ToUniversalTime().AddDays(-1 * [Math]::Abs($Days)).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $uri = "https://graph.microsoft.com/v1.0/security/alerts_v2?`$filter=createdDateTime ge $since&`$top=1000"
        $raw = New-Object System.Collections.Generic.List[object]
        $pages = 0
        do {
            $p = Invoke-RestMethod -Method Get -Uri $uri -Headers $h -ErrorAction Stop
            foreach ($a in @($p.value)) { $raw.Add($a) }
            $uri = $p.'@odata.nextLink'; $pages++
        } while ($uri -and $pages -lt 25)

        $sup = Get-XdrSuppressTitles
        $sorted = $raw.ToArray() | Sort-Object { try { [datetime]$_.createdDateTime } catch { Get-Date '1970-01-01' } } -Descending
        $rows = foreach ($a in $sorted) {
            $title = [string]$a.title
            $src   = ConvertTo-XdrSource ([string]$a.serviceSource)
            $isSup = $false
            $lt = $title.ToLower()
            foreach ($s in $sup) { if ($s -and $lt.Contains(([string]$s).ToLower())) { $isSup = $true; break } }
            $created = try { ([datetime]$a.createdDateTime).ToLocalTime().ToString('MM/dd/yyyy h:mm tt') } catch { [string]$a.createdDateTime }
            [pscustomobject]@{
                Source     = $src
                Severity   = [string]$a.severity
                Status     = [string]$a.status
                Title      = $title
                Category   = [string]$a.category
                Created    = $created
                Bucket     = if ($src -eq 'DLP') { 'dlp' } else { 'security' }
                Suppressed = $isSup
            }
        }
        @{ ok = $true; alerts = @($rows) }
    } catch {
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        @{ ok = $false; error = "Graph Security query failed (http $code): $($_.Exception.Message)"; alerts = @() }
    }
}
