# Catalog.ps1 - script catalog metadata (category + role) and the Intune add-on gate.
#
# Run-page scripts are grouped into categories on screen. Category + minimum role come from the script's
# comment-based-help header (.CATEGORY / .ROLE); if a script omits them we fall back to its numeric
# prefix (0x = AD, 1x = Entra, 2x = Intune) and default role HelpDesk. .ROLE is ENFORCED here and on the
# /run route (admin sees/runs all; helpdesk only HelpDesk-tagged). Intune and Veeam are optional add-ons:
# their scripts are hidden and non-runnable unless their config (data\intune.config.json /
# data\veeam.config.json) is present and enabled.

$script:PSCCategoryOrder = @('Active Directory', 'Entra ID', 'Intune', 'Veeam')

# --- Intune add-on gate (mirrors the Veeam config pattern) ---
function Get-IntuneConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'intune.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\intune.config.json' }
}
function Get-IntuneConfig {
    $p = Get-IntuneConfigPath
    if (-not (Test-Path $p)) { return $null }
    try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null }
}
function Test-IntuneConfigured {
    $c = Get-IntuneConfig
    return ([bool]$c -and [bool]$c.enabled)
}

# --- script metadata ---
function Get-ScriptCategoryFromName {
    param([string]$Name)
    if ($Name -match '^(\d+)') {
        $n = [int]$Matches[1]
        if     ($n -lt 10) { return 'Active Directory' }
        elseif ($n -lt 20) { return 'Entra ID' }
        elseif ($n -lt 30) { return 'Intune' }
    }
    'Other'
}
function Get-ScriptMeta {
    param([string]$Path)
    $name = Split-Path -Leaf $Path
    $cat = ''; $role = ''; $ex = ''
    foreach ($line in (Get-Content -Path $Path -TotalCount 14 -ErrorAction SilentlyContinue)) {
        if     ($line -match '^\s*\.CATEGORY\s+(.+?)\s*$')   { $cat  = $Matches[1] }
        elseif ($line -match '^\s*\.ROLE\s+(.+?)\s*$')       { $role = $Matches[1] }
        elseif ($line -match '^\s*\.RUNEXAMPLE\s+(.+?)\s*$') { $ex   = $Matches[1] }   # per-script params hint for the Run page
    }
    if (-not $cat)  { $cat  = Get-ScriptCategoryFromName $name }
    # Fail-closed: an untagged script is admin-only until it explicitly declares '.ROLE HelpDesk'.
    if (-not $role) { $role = 'Admin' }
    [PSCustomObject]@{ Name = $name; Category = $cat; Role = $role; Example = $ex }
}

# Scripts the given role may see/run, after the role gate and the Intune add-on gate.
function Get-ScriptCatalog {
    param([string]$Dir, [string]$Role = 'admin')
    $intuneOn = Test-IntuneConfigured
    $veeamOn  = Test-VeeamConfigured
    @(Get-ChildItem $Dir -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object { Get-ScriptMeta $_.FullName } |
        Where-Object { ($Role -eq 'admin' -or $_.Role -eq 'HelpDesk') -and ($_.Category -ne 'Intune' -or $intuneOn) -and ($_.Category -ne 'Veeam' -or $veeamOn) })
}

# Grouped <optgroup> HTML for a <select>, categories in PSCCategoryOrder then any extras.
function Get-ScriptOptionsHtml {
    param([string]$Dir, [string]$Role = 'admin')
    $cat  = Get-ScriptCatalog -Dir $Dir -Role $Role
    $cats = @($script:PSCCategoryOrder) + @($cat.Category | Where-Object { $script:PSCCategoryOrder -notcontains $_ })
    $html = ''
    foreach ($c in (@($cats) | Select-Object -Unique)) {
        $items = @($cat | Where-Object { $_.Category -eq $c } | Sort-Object Name)
        if (-not $items.Count) { continue }
        $opts = ($items | ForEach-Object { "<option>$(ConvertTo-PSCEncoded $_.Name)</option>" }) -join ''
        $html += "<optgroup label=`"$(ConvertTo-PSCEncoded $c)`">$opts</optgroup>"
    }
    $html
}

# JSON map { scriptName: paramsExampleHint } so the Run page can swap the params placeholder per script.
function Get-ScriptExamplesJson {
    param([string]$Dir, [string]$Role = 'admin')
    $map = @{}
    foreach ($s in (Get-ScriptCatalog -Dir $Dir -Role $Role)) { $map[[string]$s.Name] = [string]$s.Example }
    ($map | ConvertTo-Json -Compress)
}
