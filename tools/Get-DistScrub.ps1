<#
    Shared scrubbing for SHIPPED artifacts (the dist zip and the repo publish).

    The working tree deliberately keeps this org's real identifiers - it is the live install and the
    admin/helpdesk runbook ("documentation for myself"). But anything that leaves this server for a
    new user on a different domain (the dist zip, the GitHub publish) is passed through
    ConvertTo-ScrubbedText first, so real domain/host names never ship.

    Dot-source this file (`. .\Get-DistScrub.ps1`) from the build and publish scripts.
#>

# Ordered, case-insensitive replacements - MOST SPECIFIC FIRST (later rules must not re-hit earlier
# output). Kept as a simple literal-ish map so it's obvious what leaves the building.
$script:PscScrubMap = @(
    @{ from = 'Exampleorg\.onmicrosoft\.com'; to = 'contoso.onmicrosoft.com' }  # M365 tenant (EXO)
    @{ from = 'example\.org';                 to = 'example.org' }              # AD / internal domain
    @{ from = 'Example\.org';                 to = 'example.com' }              # UPN / mail domain (kept distinct)
    @{ from = 'PSCONSOLE01';                    to = 'PSCONSOLE01' }              # server hostname
    @{ from = 'example';                      to = 'example' }                  # NetBIOS / DC= label / stragglers
    @{ from = 'Example';                      to = 'Example' }                  # OU names / stragglers
)

# Extensions treated as text (scrubbed). Anything else ships byte-for-byte (images, zips, certs).
$script:PscScrubTextExt = @('.md','.txt','.ps1','.psm1','.psd1','.pode','.json','.xml','.html','.htm','.css','.js','.yml','.yaml','.config','.ini','.cmd','.bat')

# Identifiers that must NOT survive into shipped output - the post-scrub leak gate.
$script:PscScrubForbidden = @('example','PSCONSOLE01','Example')

function Test-PscTextFile {
    param([Parameter(Mandatory)][string]$Path)
    return ($script:PscScrubTextExt -contains ([IO.Path]::GetExtension($Path).ToLower()))
}

function ConvertTo-ScrubbedText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    foreach ($r in $script:PscScrubMap) { $Text = [regex]::Replace($Text, $r.from, $r.to, 'IgnoreCase') }
    return $Text
}

# Returns the forbidden tokens still present in $Text (empty array = clean).
function Find-PscScrubLeaks {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $hits = @()
    foreach ($t in $script:PscScrubForbidden) { if ($Text -imatch [regex]::Escape($t)) { $hits += $t } }
    return $hits
}
