<#
.SYNOPSIS  Reconcile the Computer Inventory list against Intune: devices marked "Intune" in inventory that aren't actually enrolled (and the reverse), plus inventory Owner vs Intune primary-user mismatches. Read-only. Use -IncludeMatches to also list rows that agree.
.RUNEXAMPLE  IncludeMatches=true
.CATEGORY  Intune
.NOTES     App perms: read app DeviceManagementManagedDevices.Read.All + write app Sites.Selected on the inventory site. No writes. Needs data\inventory.config.json.
.ROLE      Admin
#>
[CmdletBinding()]
param([switch]$IncludeMatches)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-CfgPath([string]$Name) {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA $Name } else { Join-Path $PSScriptRoot "..\..\data\$Name" }
}
# App-only token from a DPAPI-encrypted config (graph.config.json = read app, graph-write.config.json = write app).
function Get-AppToken([string]$ConfigName) {
    $p = Get-CfgPath $ConfigName
    if (-not (Test-Path $p)) { throw "Config not found: $p" }
    $cfg = Get-Content $p -Raw | ConvertFrom-Json
    Add-Type -AssemblyName System.Security
    $secret = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($cfg.secret), $null, 'LocalMachine'))
    $body = @{ client_id = $cfg.clientId; scope = 'https://graph.microsoft.com/.default'; client_secret = $secret; grant_type = 'client_credentials' }
    (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($cfg.tenantId)/oauth2/v2.0/token" -Body $body).access_token
}
function Invoke-GraphGet([string]$Uri, [string]$Token) {
    $h = @{ Authorization = "Bearer $Token" }
    $out = New-Object System.Collections.Generic.List[object]
    do {
        $p = Invoke-RestMethod -Method Get -Uri $Uri -Headers $h
        if ($null -ne $p.value) { foreach ($i in $p.value) { $out.Add($i) }; $Uri = $p.'@odata.nextLink' }
        else { $out.Add($p); $Uri = $null }
    } while ($Uri)
    $out
}

# --- Intune managed devices (read app) - keyed by upper-cased device name ---
$rtok = Get-AppToken 'graph.config.json'
$intune = @{}
foreach ($d in Invoke-GraphGet "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=deviceName,userPrincipalName,userDisplayName" $rtok) {
    $k = ("$($d.deviceName)").Trim().ToUpper()
    if ($k -and -not $intune.ContainsKey($k)) { $intune[$k] = $d }
}

# --- Inventory list (write app + inventory.config.json) ---
$icfg = Get-Content (Get-CfgPath 'inventory.config.json') -Raw | ConvertFrom-Json
$f = $icfg.fields
$wtok = Get-AppToken 'graph-write.config.json'
$items = Invoke-GraphGet "https://graph.microsoft.com/v1.0/sites/$($icfg.siteId)/lists/$($icfg.listId)/items?`$expand=fields&`$top=200" $wtok

$rows = New-Object System.Collections.Generic.List[object]
foreach ($it in $items) {
    $fl = $it.fields
    $title = ("$($fl.($f.title))").Trim()
    if (-not $title) { continue }
    $owner    = ("$($fl.($f.owner))").Trim()
    $invIntun = (@($fl.($f.intuneStatus)) -join ', ')
    $marked   = ($invIntun -match 'Intune')                    # inventory says "Intune" (managed)
    $dev      = $intune[$title.ToUpper()]
    $inIntune = [bool]$dev
    $primary  = if ($dev) { ("$($dev.userDisplayName)").Trim() } else { '' }

    $issue = $null
    if     ($marked -and -not $inIntune)                       { $issue = 'Inventory=Intune but NOT enrolled in Intune' }
    elseif ($inIntune -and -not $marked)                       { $issue = 'In Intune but inventory=Not Managed' }
    elseif ($inIntune -and $owner -and $primary -and ($owner -ne $primary)) { $issue = 'Owner does not match Intune primary user' }
    elseif ($inIntune -and $owner -and -not $primary)          { $issue = 'Inventory owner set; Intune has no primary user' }
    elseif ($inIntune -and -not $owner -and $primary)          { $issue = 'Intune primary user set; inventory owner blank' }

    if ($issue -or $IncludeMatches) {
        $rows.Add([PSCustomObject]@{
            Device            = $title
            Issue             = if ($issue) { $issue } else { 'OK' }
            InventoryOwner    = $owner
            InventoryIntune   = $invIntun
            IntunePrimaryUser = $primary
        })
    }
}

if ($rows.Count -eq 0) {
    [PSCustomObject]@{ Result = 'No discrepancies found - inventory and Intune agree.' }
} else {
    $rows | Sort-Object Issue, Device
}
