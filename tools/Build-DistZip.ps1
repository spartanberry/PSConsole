<#
.SYNOPSIS
    Build dist\PSConsole-v<VERSION>.zip from the working tree, with shipped text files scrubbed of
    this org's real domain/host names (see Get-DistScrub.ps1). The working tree is left untouched.

.DESCRIPTION
    Stages every shippable file (excludes data\, .claude\, dist\, .git\, logs) into a temp folder,
    runs text files through ConvertTo-ScrubbedText, zips the staged copy, and runs a leak gate that
    FAILS the build if any forbidden identifier survives. data\ (real config + secrets) never ships.

.EXAMPLE
    .\Build-DistZip.ps1
#>
[CmdletBinding()]
param(
    [string]$SourceRoot = (Join-Path $PSScriptRoot '..'),
    [string]$OutDir     = (Join-Path $PSScriptRoot '..\dist')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-DistScrub.ps1')

$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$OutDir     = [IO.Path]::GetFullPath($OutDir)
$version    = (Get-Content (Join-Path $SourceRoot 'VERSION') -Raw).Trim()
$excludeTop = @('data', '.claude', 'dist', '.git')

$files = Get-ChildItem $SourceRoot -Recurse -File -Force | Where-Object {
    $rel = $_.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
    $top = ($rel -split '[\\/]')[0]
    ($excludeTop -notcontains $top) -and ($_.Extension -notin '.log', '.tmp', '.bak')
}

$staging = Join-Path ([IO.Path]::GetTempPath()) ("psconsole-dist-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
Write-Host "Staging $($files.Count) files -> $staging" -ForegroundColor Cyan

try {
    $scrubbedCount = 0
    $leaks = @()
    foreach ($f in $files) {
        $rel  = $f.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $dest = Join-Path $staging $rel
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        if (Test-PscTextFile $f.FullName) {
            $txt = [IO.File]::ReadAllText($f.FullName)
            $out = ConvertTo-ScrubbedText $txt
            if ($out -ne $txt) { $scrubbedCount++ }
            [IO.File]::WriteAllText($dest, $out, (New-Object Text.UTF8Encoding($false)))
            $hit = Find-PscScrubLeaks $out
            if ($hit) { $leaks += ("{0} -> {1}" -f $rel, ($hit -join ', ')) }
        }
        else {
            Copy-Item -LiteralPath $f.FullName -Destination $dest
        }
    }

    if ($leaks.Count) {
        throw ("Leak gate FAILED - forbidden identifiers survived scrubbing in:`n  " + ($leaks -join "`n  "))
    }
    Write-Host "Scrubbed $scrubbedCount text file(s); leak gate clean." -ForegroundColor Green

    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
    $zip = Join-Path $OutDir "PSConsole-v$version.zip"
    if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)

    $info = Get-Item $zip
    Write-Host ("Built {0}  ({1:N1} MB, {2} files)" -f $zip, ($info.Length / 1MB), $files.Count) -ForegroundColor Green
}
finally {
    if (Test-Path $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
