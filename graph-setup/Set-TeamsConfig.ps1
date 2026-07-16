<#
.SYNOPSIS
    Write data\teams.config.json so PSConsole can post alerts to a Microsoft Teams channel. This is a
    REUSABLE notification channel - the expiration-alert hub uses it, and future features can too.

    Run ON the PSConsole host: the webhook URL is DPAPI-encrypted (LocalMachine scope) and only decrypts
    on this machine.

.DESCRIPTION
    Microsoft is retiring the legacy Office 365 "Incoming Webhook" connector. The supported path is a
    Power Automate "Workflows" flow in Teams:
      Teams channel -> ... (more options) -> Workflows -> "Post to a channel when a webhook request is
      received" -> create it, then COPY the generated HTTP POST URL.
    Paste that URL here. (An old Incoming Webhook URL still works too - same card format.)

.EXAMPLE
    .\Set-TeamsConfig.ps1
    # paste the Workflows URL when prompted, then it posts a test card

.EXAMPLE
    .\Set-TeamsConfig.ps1 -SkipTest         # store without posting a test card
    .\Set-TeamsConfig.ps1 -Disable          # keep the URL but turn the channel off
#>
[CmdletBinding()]
param(
    [string]$Target,          # optional named destination (e.g. 'veeam' = a personal flow); blank = default/shared channel
    [switch]$SkipTest,
    [switch]$Disable,
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$dataDir = Join-Path $PSScriptRoot '..\data'
if (-not (Test-Path $dataDir)) { throw "Data dir not found: $dataDir" }
$path = Join-Path $dataDir 'teams.config.json'

if ($Remove) {
    if (Test-Path $path) { Remove-Item $path -Force }
    Write-Host "Removed $path - Teams channel disabled." -ForegroundColor Green
    return
}

# Toggle-only: flip enabled on the existing config without re-entering the URL.
if ($Disable) {
    if (-not (Test-Path $path)) { throw "No existing $path to disable." }
    $existing = Get-Content $path -Raw | ConvertFrom-Json
    $existing.enabled = $false
    $existing | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8
    Write-Host "Teams channel DISABLED (URL kept)." -ForegroundColor Yellow
    return
}

$sec  = Read-Host -AsSecureString 'Paste the Teams Workflows (or Incoming Webhook) POST URL'
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try { $url = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if ([string]::IsNullOrWhiteSpace($url)) { throw 'No URL entered.' }
if ($url -notmatch '^https://') { throw 'The URL must start with https://' }

if (-not $SkipTest) {
    Write-Host 'Posting a test card to the channel ...' -ForegroundColor Cyan
    $card = [ordered]@{
        type='message'
        attachments=@(@{
            contentType='application/vnd.microsoft.card.adaptive'
            content=[ordered]@{
                '$schema'='http://adaptivecards.io/schemas/adaptive-card.json'
                type='AdaptiveCard'; version='1.4'
                body=@(
                    [ordered]@{ type='TextBlock'; text='PSConsole test message'; weight='Bolder'; size='Large' }
                    [ordered]@{ type='TextBlock'; text='If you can see this card, the Teams notification channel is working.'; wrap=$true }
                )
            }
        })
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json' -Body ($card | ConvertTo-Json -Depth 12) -TimeoutSec 25 | Out-Null }
    catch { throw "Test post failed: $($_.Exception.Message). Check the URL is the flow's POST URL and the flow is turned on." }
    Write-Host 'Test card posted - confirm it appeared in the channel.' -ForegroundColor Green
}

Add-Type -AssemblyName System.Security
$enc = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($url), $null, 'LocalMachine'))
$url = $null

# Preserve any existing config (the other of default/targets) when writing this one.
$existing = $null
if (Test-Path $path) { try { $existing = Get-Content $path -Raw | ConvertFrom-Json } catch {} }
if ($Target) {
    $targets = if ($existing -and $existing.targets) { $existing.targets } else { [pscustomobject]@{} }
    $targets | Add-Member -NotePropertyName $Target -NotePropertyValue $enc -Force
    $obj = [ordered]@{ enabled = $true; webhookUrl = [string]($existing.webhookUrl); targets = $targets }
    Write-Host "Wrote $path (target '$Target', enabled). URL is DPAPI-encrypted." -ForegroundColor Green
} else {
    $targets = if ($existing -and $existing.targets) { $existing.targets } else { $null }
    $obj = [ordered]@{ enabled = (-not $Disable); webhookUrl = $enc; targets = $targets }
    Write-Host "Wrote $path (default channel, enabled=$(-not $Disable)). URL is DPAPI-encrypted." -ForegroundColor Green
}
$obj | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8
Write-Host 'No service restart needed - config is read per send.' -ForegroundColor DarkGray
