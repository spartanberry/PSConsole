# Store.ps1 - flat JSON persistence under $env:PSCONSOLE_DATA. No external DB.
$script:DataDir = if ($env:PSCONSOLE_DATA) { $env:PSCONSOLE_DATA } else { Join-Path $PSScriptRoot '..\..\data' }

function Initialize-Store {
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    foreach ($f in 'config.json','users.json','registry.json') {
        $p = Join-Path $script:DataDir $f
        if (-not (Test-Path $p)) {
            $seed = switch ($f) {
                'config.json'   { @{ ldapEnabled=$false; ldapServer="example.org"; ldapPort=636; ldapUseSsl=$true; ldapBaseDn=""; certThumbprint=""; roleMap=@{ admin=@(); helpdesk=@() } } }
                'users.json'    { @() }
                'registry.json' { @() }
            }
            $seed | ConvertTo-Json -Depth 8 | Set-Content -Path $p -Encoding UTF8
        }
    }
}
function Get-Store([string]$Name) {
    $p = Join-Path $script:DataDir "$Name.json"
    if (-not (Test-Path $p)) { return $null }
    $raw = Get-Content $p -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $o = $raw | ConvertFrom-Json
    # Self-heal legacy corruption: an array that was serialized by a buggy writer as the collection
    # WRAPPER object {"value":[...],"Count":N} (a Windows PowerShell 5.1 ConvertTo-Json artifact).
    # If we see exactly those two properties, return the real payload (.value).
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $names = @($o.PSObject.Properties.Name)
        if ($names.Count -le 2 -and ($names -contains 'value') -and ($names -contains 'Count')) { return $o.value }
    }
    $o
}
function Set-Store([string]$Name, $Object) {
    $p = Join-Path $script:DataDir "$Name.json"
    $tmp = "$p.tmp"
    # Windows PowerShell 5.1 ConvertTo-Json has two traps for collections:
    #   - PIPING a collection unrolls it, so a SINGLE-element array serializes as a bare object {...}.
    #   - -InputObject on an EMPTY collection serializes as the wrapper {"value":[],"Count":0}.
    # So handle collections explicitly: 0 -> [], 1 -> wrap the one object in [ ], many -> array.
    if ($null -eq $Object) {
        $json = '[]'
    } elseif (($Object -is [System.Collections.IEnumerable]) -and ($Object -isnot [string]) -and ($Object -isnot [System.Collections.IDictionary])) {
        $items = @($Object)
        if     ($items.Count -eq 0) { $json = '[]' }
        elseif ($items.Count -eq 1) { $json = "[`r`n" + (ConvertTo-Json -InputObject $items[0] -Depth 12) + "`r`n]" }
        else                        { $json = ConvertTo-Json -InputObject $items -Depth 12 }
    } else {
        $json = ConvertTo-Json -InputObject $Object -Depth 12
    }
    if ([string]::IsNullOrWhiteSpace($json)) { $json = '[]' }
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    Move-Item -Path $tmp -Destination $p -Force   # atomic-ish replace
}
function Get-DataDir { $script:DataDir }
