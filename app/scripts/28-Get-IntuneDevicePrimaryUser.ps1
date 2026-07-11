<#
.SYNOPSIS  Primary user of each Intune managed device (device name -> primary user UPN/name). Optional -DeviceName / -UserPrincipalName substring filters.
.CATEGORY  Intune
.NOTES     Graph app perms: DeviceManagementManagedDevices.Read.All. Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param([string]$DeviceName, [string]$UserPrincipalName)
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

# managedDevice.userPrincipalName / userDisplayName / userId are the device's PRIMARY user.
$sel = 'deviceName,userPrincipalName,userDisplayName,userId,managedDeviceOwnerType,operatingSystem,lastSyncDateTime'
Invoke-Graph "/deviceManagement/managedDevices?`$select=$sel" |
Where-Object { (-not $DeviceName -or $_.deviceName -like "*$DeviceName*") -and (-not $UserPrincipalName -or $_.userPrincipalName -like "*$UserPrincipalName*") } |
ForEach-Object {
    [PSCustomObject]@{
        Device          = $_.deviceName
        PrimaryUser     = $_.userPrincipalName
        PrimaryUserName = $_.userDisplayName
        Ownership       = $_.managedDeviceOwnerType
        OS              = $_.operatingSystem
        LastCheckIn     = $_.lastSyncDateTime
        HasPrimaryUser  = [bool]$_.userId
    }
} | Sort-Object Device
