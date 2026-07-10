<#
.SYNOPSIS
    One-time: make the PSConsole Veeam query account TRUST the Veeam server's self-signed
    Identity-service certificate, so non-interactive queries stop failing with
    "Failed to connect to Identity service". Run ON the PSConsole server, after Set-VeeamConfig.ps1.

.DESCRIPTION
    Veeam's PowerShell client pins the backup server's certificate PER WINDOWS USER. The first time
    an account connects it must interactively ACCEPT the (self-signed) certificate; that acceptance
    is stored in the user's "Veeam Backup and Replication" certificate store on the Veeam server.
    A service/reader account driven non-interactively can never see that prompt, so Connect-VBRServer
    aborts and Veeam reports the misleading error "Failed to connect to Identity service".

    This script performs that one-time acceptance FOR the configured query account: it opens an
    interactive PowerShell on the Veeam server over WinRM and answers the certificate prompt on the
    account's behalf, which records the trust in that account's profile.

    Read-only: it connects and immediately disconnects - no backup is started or changed. Re-run only
    if the Veeam server's certificate is regenerated (e.g. after a Veeam upgrade).

.EXAMPLE
    .\Set-VeeamTrust.ps1
    # uses the account stored by Set-VeeamConfig.ps1 (-Username), or the current account if none

.NOTES
    Prerequisites (same as the Veeam add-on itself): the query account can WinRM into the Veeam
    server, has the Veeam "Backup Viewer"/"Restore Operator" role, and pwsh 7 is installed there.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

# Reuse the add-on's config/credential helpers (self-contained - no Pode needed).
. (Join-Path $PSScriptRoot '..\app\lib\Veeam.ps1')
if (-not $env:PSCONSOLE_DATA) { $env:PSCONSOLE_DATA = (Resolve-Path (Join-Path $PSScriptRoot '..\data')).Path }

$cfg = Get-VeeamConfig
if (-not $cfg -or -not $cfg.server) { throw "Veeam is not configured. Run Set-VeeamConfig.ps1 first." }
$cred = Get-VeeamCredential -Cfg $cfg
$who  = if ($cred) { [string]$cred.UserName } else { "$env:USERDOMAIN\$env:USERNAME (current account)" }
Write-Host "Establishing Veeam certificate trust for '$who' on $($cfg.server) ..." -ForegroundColor Cyan

$remote = {
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { foreach ($p in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "$env:ProgramW6432\PowerShell\7\pwsh.exe")) { if (Test-Path $p) { $pwsh = $p; break } } }
    if (-not $pwsh) { return 'ERROR: PowerShell 7 (pwsh.exe) not found on the Veeam server; the Veeam module requires it.' }
    $inner = @'
try { Import-Module Veeam.Backup.PowerShell -DisableNameChecking; Connect-VBRServer -Server localhost -ErrorAction Stop; "OK jobs=" + (@(Get-VBRJob).Count); Disconnect-VBRServer } catch { "ERR: " + $_.Exception.Message }
'@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwsh
    # Deliberately NOT -NonInteractive, so Veeam's certificate-acceptance prompt can be answered via STDIN.
    $psi.Arguments = "-NoProfile -EncodedCommand $enc"
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    Start-Sleep -Seconds 3
    # Answer the "accept this certificate?" prompt (accept/yes/first-choice cover the known variants).
    foreach ($ans in 'c', 'y', 'a', '1', '') { try { $proc.StandardInput.WriteLine($ans) } catch {} }
    try { $proc.StandardInput.Close() } catch {}
    if (-not $proc.WaitForExit(60000)) { try { $proc.Kill() } catch {}; return 'ERROR: timed out establishing certificate trust.' }
    $outTask.Result.Trim()
}

$ic = @{ ComputerName = [string]$cfg.server; ScriptBlock = $remote; ErrorAction = 'Stop' }
if ($cred)      { $ic.Credential = $cred }
if ($cfg.useSsl) { $ic.UseSSL = $true }
$result = "$(Invoke-Command @ic)".Trim()

if ($result -match 'OK jobs=(\d+)') {
    Write-Host "Success - certificate trusted; connected and saw $($Matches[1]) job(s)." -ForegroundColor Green
    Write-Host "The Veeam page will now load non-interactively for the PSConsole service." -ForegroundColor DarkGray
}
else {
    Write-Warning "Trust not confirmed. The Veeam server returned:`n$result"
    Write-Host "Check that '$who' can WinRM into $($cfg.server), has the Veeam Backup Viewer role, and that pwsh 7 is installed there." -ForegroundColor DarkGray
    exit 1
}
