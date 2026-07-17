# Sdp.ps1 - OPTIONAL add-on: read-only ManageEngine ServiceDesk Plus reporting.
#
# The free edition has no REST API, so reports come from DIRECT, READ-ONLY SQL against the SDP SQL Server
# backend (System.Data.SqlClient, native on WinPS 5.1). We only ever SELECT - never write to the live desk
# DB (that would break FK/trigger logic). Ticket write-back/close is NOT possible on free; it would need an
# API-v3 licence upgrade, not a SQL feature.
#
# Config: data\sdp.config.json (helper: sdp-setup\Set-SdpConfig.ps1), shaped:
#   { "enabled": true, "server": "SQLHOST\\INSTANCE", "database": "servicedesk",
#     "username": "psc_sdpread",            # OMIT username+secret for Windows Integrated auth (runs as the
#     "secret": "<DPAPI LocalMachine>",     #   service account) - then no secret is stored at all
#     "encrypt": true, "trustServerCertificate": true }
#
# Access model: a read-only principal with db_datareader on the SDP DB only (ideally a read replica).
# Integrated auth (no username) = connect as zpsconsole, no stored secret. SQL auth (username+secret) =
# a dedicated read-only SQL login, separate identity, DPAPI-encrypted password.

function Get-SdpConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'sdp.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\sdp.config.json' }
}
function Get-SdpConfig {
    $p = Get-SdpConfigPath
    if (-not (Test-Path $p)) { return $null }
    try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null }
}
function Test-SdpConfigured {
    $c = Get-SdpConfig
    return ([bool]$c -and [bool]$c.enabled -and [bool]$c.server -and [bool]$c.database)
}

# Build the connection string via SqlConnectionStringBuilder so values (esp. the password) are escaped.
function Get-SdpConnectionString {
    param($Cfg)
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Server']           = [string]$Cfg.server
    $b['Database']         = [string]$Cfg.database
    $b['Application Name']  = 'PSConsole-SDP'
    $b['Connect Timeout']  = $(if ($Cfg.connectTimeout) { [int]$Cfg.connectTimeout } else { 15 })
    if ($Cfg.username) {
        $pw = ''
        if ($Cfg.secret) {
            Add-Type -AssemblyName System.Security
            $pw = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$Cfg.secret), $null, 'LocalMachine'))
        }
        $b['User ID']  = [string]$Cfg.username
        $b['Password'] = $pw
    } else {
        $b['Integrated Security'] = $true
    }
    if ($null -ne $Cfg.encrypt)               { $b['Encrypt'] = [bool]$Cfg.encrypt }
    if ($null -ne $Cfg.trustServerCertificate) { $b['TrustServerCertificate'] = [bool]$Cfg.trustServerCertificate }
    $b.ConnectionString
}

# Run a read-only query. ALWAYS parameterise anything user-influenced (@name) - never string-concat into SQL.
# Returns @{ ok; error; rows=@(PSCustomObject...) }. Never throws.
function Invoke-SdpQuery {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [hashtable]$Parameters,
        [int]$TimeoutSec = 30
    )
    if (-not (Test-SdpConfigured)) { return @{ ok = $false; error = 'Service Desk Plus add-on is not configured (data\sdp.config.json).'; rows = @() } }
    $conn = New-Object System.Data.SqlClient.SqlConnection (Get-SdpConnectionString (Get-SdpConfig))
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = $TimeoutSec
        if ($Parameters) { foreach ($k in $Parameters.Keys) { $val = $Parameters[$k]; if ($null -eq $val) { $val = [DBNull]::Value }; [void]$cmd.Parameters.AddWithValue($k, $val) } }
        $rdr  = $cmd.ExecuteReader()
        $cols = @(0..($rdr.FieldCount - 1) | ForEach-Object { $rdr.GetName($_) })
        $rows = New-Object System.Collections.Generic.List[object]
        while ($rdr.Read()) {
            $o = [ordered]@{}
            for ($i = 0; $i -lt $rdr.FieldCount; $i++) { $v = $rdr.GetValue($i); if ($v -is [DBNull]) { $v = $null }; $o[$cols[$i]] = $v }
            $rows.Add([pscustomobject]$o)
        }
        $rdr.Close()
        return @{ ok = $true; error = ''; rows = $rows.ToArray() }
    }
    catch { return @{ ok = $false; error = $_.Exception.Message; rows = @() } }
    finally { $conn.Dispose() }
}

# SDP stores timestamps as epoch-MILLISECOND bigints; unset is 0 or -1. Format LOCAL at the source (the
# WinPS 5.1 ConvertTo-Json /Date(ms)/ trap) and never emit a raw DateTime from a catalog script.
function ConvertFrom-SdpEpoch {
    param($Millis)
    if ($null -eq $Millis) { return $null }
    $m = 0L; if (-not [int64]::TryParse("$Millis", [ref]$m)) { return $null }
    if ($m -le 0) { return $null }
    try { [DateTimeOffset]::FromUnixTimeMilliseconds($m).LocalDateTime } catch { $null }
}
function Format-SdpDate {
    param($Millis)
    $d = ConvertFrom-SdpEpoch $Millis
    if ($d) { $d.ToString('MM/dd/yyyy h:mm tt') } else { '' }
}

