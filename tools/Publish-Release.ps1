<#
.SYNOPSIS
    Publish PSConsole to BOTH targets from the one working tree:
      - PRIVATE (real names, -NoScrub):  spartanberry/PSScripts  under psconsole/   (your source of truth)
      - PUBLIC  (scrubbed):              spartanberry/PSConsole   at the repo root   (for new users)

    The working tree is never modified; only the public copy is scrubbed (see Get-DistScrub.ps1).
    You're prompted for the GitHub PAT once and it's reused for both pushes.

.DESCRIPTION
    The PAT must have Contents: read/write on BOTH repos. With -CreatePublicRepo it also needs repo
    creation rights (classic 'repo' scope, or a fine-grained token with Administration: read/write) -
    it will create spartanberry/PSConsole as a PUBLIC repo if it doesn't exist yet.

.EXAMPLE
    .\Publish-Release.ps1 -Message "Release v1.4.0: UI facelift + TLS helper" -CreatePublicRepo

.EXAMPLE
    # once the public repo exists, subsequent releases:
    .\Publish-Release.ps1 -Message "Release v1.4.1"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Message,
    [string]$Owner            = 'spartanberry',
    [string]$PrivateRepo      = 'PSScripts',
    [string]$PrivateRepoPath  = 'psconsole',
    [string]$PublicRepo       = 'PSConsole',
    [string]$Branch           = 'main',
    [switch]$CreatePublicRepo
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$core = Join-Path $PSScriptRoot 'Publish-ToRepo.ps1'

# --- one PAT for both pushes (SecureString -> env for the core script to read) ---
$weSetPat = $false
if ([string]::IsNullOrWhiteSpace($env:GITHUB_PAT)) {
    $sec  = Read-Host -AsSecureString "GitHub PAT (Contents r/w on $Owner/$PrivateRepo AND $Owner/$PublicRepo)"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $env:GITHUB_PAT = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $weSetPat = $true
}
if ([string]::IsNullOrWhiteSpace($env:GITHUB_PAT)) { throw 'No PAT provided.' }

try {
    $H = @{ Authorization = "token $($env:GITHUB_PAT)"; 'User-Agent' = 'PSConsole-Publish'; Accept = 'application/vnd.github+json' }

    # --- ensure the public repo exists (optional) ---
    $exists = $true
    try { Invoke-RestMethod -Headers $H -Uri "https://api.github.com/repos/$Owner/$PublicRepo" | Out-Null }
    catch { $exists = $false }
    if (-not $exists) {
        if (-not $CreatePublicRepo) {
            throw "Public repo $Owner/$PublicRepo doesn't exist. Create it on GitHub (Public), or re-run with -CreatePublicRepo."
        }
        Write-Host "Creating PUBLIC repo $Owner/$PublicRepo ..." -ForegroundColor Yellow
        $body = @{ name = $PublicRepo; private = $false; description = 'PSConsole - self-hosted PowerShell execution platform (Pode).' } | ConvertTo-Json
        Invoke-RestMethod -Headers $H -Method Post -Uri 'https://api.github.com/user/repos' -Body $body -ContentType 'application/json' | Out-Null
        Write-Host "Created $Owner/$PublicRepo (public)." -ForegroundColor Green
    }

    Write-Host "`n== 1/2  PRIVATE (real) -> $Owner/$PrivateRepo/$PrivateRepoPath ==" -ForegroundColor Cyan
    & $core -Owner $Owner -Repo $PrivateRepo -Branch $Branch -RepoPath $PrivateRepoPath -NoScrub -Message $Message

    Write-Host "`n== 2/2  PUBLIC (scrubbed) -> $Owner/$PublicRepo (root) ==" -ForegroundColor Cyan
    & $core -Owner $Owner -Repo $PublicRepo -Branch $Branch -RepoPath '' -Message $Message

    Write-Host "`nBoth repos published." -ForegroundColor Green
}
finally {
    if ($weSetPat) { $env:GITHUB_PAT = $null }   # don't leave the token in the environment
}
