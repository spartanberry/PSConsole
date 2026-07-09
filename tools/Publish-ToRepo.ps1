<#
.SYNOPSIS
    Publish the PSConsole working tree to the GitHub repo (spartanberry/PSScripts) under psconsole/,
    as a single commit, via the GitHub Git Data API. No git client required.

.DESCRIPTION
    Uploads every file under -SourceRoot (excluding data/, .claude/, dist/, .git/, logs) as blobs,
    builds a tree on top of the current branch head (so unchanged files are preserved and the commit
    diff shows only real changes), commits, and fast-forwards the branch ref.

    The GitHub PAT is read from $env:GITHUB_PAT, or prompted for as a SecureString - it is NEVER
    passed as a plain parameter, so it stays out of shell history. Use a fine-grained PAT scoped to
    the PSScripts repo with Contents: Read and write.

.EXAMPLE
    $env:GITHUB_PAT = '<paste-here-in-this-session-only>'   # or let it prompt
    .\Publish-ToRepo.ps1 -Message "Release v1.2.0: user provisioning + onboarding"
#>
[CmdletBinding()]
param(
    [string]$Owner      = 'spartanberry',
    [string]$Repo       = 'PSScripts',
    [string]$Branch     = 'main',
    [string]$RepoPath   = 'psconsole',                 # subfolder in the repo
    [string]$SourceRoot = (Join-Path $PSScriptRoot '..'),
    [switch]$NoScrub,                                  # push the working tree verbatim (real names) - normally OFF
    [Parameter(Mandatory)][string]$Message
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)

# The repo is a distribution channel (new users clone/download it), so shipped text is scrubbed of
# this org's real domain/host names by default - same transform as the dist zip. -NoScrub opts out.
. (Join-Path $PSScriptRoot 'Get-DistScrub.ps1')

# --- token (secure) ---
$pat = $env:GITHUB_PAT
if ([string]::IsNullOrWhiteSpace($pat)) {
    $sec  = Read-Host -AsSecureString "GitHub PAT (Contents: read/write on $Owner/$Repo)"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $pat = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if ([string]::IsNullOrWhiteSpace($pat)) { throw 'No PAT provided.' }
$H = @{ Authorization = "token $pat"; 'User-Agent' = 'PSConsole-Publish'; Accept = 'application/vnd.github+json' }
$PSDefaultParameterValues = @{ 'Invoke-RestMethod:ContentType' = 'application/json' }
$api = "https://api.github.com/repos/$Owner/$Repo"

# Wrapper that retries on GitHub secondary rate limits (403/429): honors Retry-After, else backs off.
function Invoke-GH {
    param([string]$Method = 'Get', [string]$Uri, $Body)
    for ($attempt = 1; ; $attempt++) {
        try {
            if ($null -ne $Body) { return Invoke-RestMethod -Headers $H -Method $Method -Uri $Uri -Body $Body }
            else                 { return Invoke-RestMethod -Headers $H -Method $Method -Uri $Uri }
        } catch {
            $resp = $_.Exception.Response
            $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
            if (($code -eq 403 -or $code -eq 429) -and $attempt -le 6) {
                $wait = 0
                try { $ra = $resp.Headers['Retry-After']; if ($ra) { $wait = [int]$ra } } catch {}
                if (-not $wait) { $wait = [int][Math]::Min(60, [Math]::Pow(2, $attempt)) }
                Write-Host ("  rate-limited ({0}); waiting {1}s (attempt {2})..." -f $code, $wait, $attempt) -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }
}

# --- collect files (exclude runtime state, secrets, logs) ---
$excludeDirs = @('data','.claude','dist','.git')
$files = Get-ChildItem $SourceRoot -Recurse -File -Force | Where-Object {
    $rel = $_.FullName.Substring($SourceRoot.Length).TrimStart('\','/')
    $top = ($rel -split '[\\/]')[0]
    ($excludeDirs -notcontains $top) -and ($_.Extension -notin '.log','.tmp','.bak')
}
Write-Host "Publishing $($files.Count) files to $Owner/$Repo ($Branch) under $RepoPath/ ..." -ForegroundColor Cyan

# --- current head + base tree (tolerate a brand-new empty repo with no branch yet) ---
$headSha = $null; $baseTree = $null
try {
    $ref      = Invoke-GH -Uri "$api/git/ref/heads/$Branch"
    $headSha  = $ref.object.sha
    $baseTree = (Invoke-GH -Uri "$api/git/commits/$headSha").tree.sha
} catch {
    # Empty repo: the Git Data API (blobs/trees) returns 409 until a commit exists, so seed the first
    # commit via the Contents API - it works on an empty repo and creates the $Branch ref for us.
    Write-Host "Branch '$Branch' has no commits yet - seeding an initial commit via the Contents API ..." -ForegroundColor Yellow
    $seedBody = @{
        message = 'Initialize repository'
        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("# PSConsole`n"))
        branch  = $Branch
    } | ConvertTo-Json
    $seed     = Invoke-GH -Method Put -Uri "$api/contents/README.md" -Body $seedBody
    $headSha  = $seed.commit.sha
    $baseTree = (Invoke-GH -Uri "$api/git/commits/$headSha").tree.sha
}

# --- blobs -> tree entries ---
$tree = New-Object System.Collections.Generic.List[object]
$leaks = @()
$i = 0
foreach ($f in $files) {
    $i++
    $rel   = $f.FullName.Substring($SourceRoot.Length).TrimStart('\','/').Replace('\','/')
    # Scrub shipped text files unless -NoScrub; binaries and non-text ship byte-for-byte.
    if (-not $NoScrub -and (Test-PscTextFile $f.FullName)) {
        $out = ConvertTo-ScrubbedText ([IO.File]::ReadAllText($f.FullName))
        $hit = Find-PscScrubLeaks $out
        if ($hit) { $leaks += ("{0} -> {1}" -f $rel, ($hit -join ', ')) }
        $b64 = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($out))
    }
    else {
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))
    }
    $blob  = Invoke-GH -Method Post -Uri "$api/git/blobs" -Body (@{ content=$b64; encoding='base64' } | ConvertTo-Json)
    $path  = if ([string]::IsNullOrEmpty($RepoPath)) { $rel } else { "$RepoPath/$rel" }   # '' = repo root
    $tree.Add(@{ path = $path; mode = '100644'; type = 'blob'; sha = $blob.sha })
    Start-Sleep -Milliseconds 150            # pace requests to avoid secondary rate limiting
    if ($i % 25 -eq 0) { Write-Host "  ...$i/$($files.Count)" }
}
if ($leaks.Count) {
    throw ("Leak gate FAILED - forbidden identifiers survived scrubbing (nothing committed):`n  " + ($leaks -join "`n  "))
}

# --- tree -> commit -> move ref (base_tree/parents/ref differ for the bootstrap case) ---
$treeBody = if ($baseTree) { @{ base_tree = $baseTree; tree = $tree } } else { @{ tree = $tree } }
$newTree = Invoke-GH -Method Post -Uri "$api/git/trees" -Body ($treeBody | ConvertTo-Json -Depth 6)
$commitBody = @{ message = $Message; tree = $newTree.sha }
if ($headSha) { $commitBody.parents = @($headSha) }
$commit = Invoke-GH -Method Post -Uri "$api/git/commits" -Body ($commitBody | ConvertTo-Json)
if ($headSha) {
    Invoke-GH -Method Patch -Uri "$api/git/refs/heads/$Branch" -Body (@{ sha=$commit.sha; force=$false } | ConvertTo-Json) | Out-Null
} else {
    Invoke-GH -Method Post -Uri "$api/git/refs" -Body (@{ ref="refs/heads/$Branch"; sha=$commit.sha } | ConvertTo-Json) | Out-Null
}

Write-Host "Committed $($commit.sha.Substring(0,7)) to $Branch." -ForegroundColor Green
Write-Host "https://github.com/$Owner/$Repo/commit/$($commit.sha)"
