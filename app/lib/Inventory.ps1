# Inventory.ps1 - read (and later update) the Computer_Inventory SharePoint list via the graph-write
# app (Sites.Selected on the InformationTechnology site). ADMIN-ONLY feature. Config + the org-specific
# column internal-name map live in data\inventory.config.json (gitignored, never shipped), so no
# environment-specific field names sit in the code.

function Get-InventoryConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'inventory.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\inventory.config.json' }
}
function Test-InventoryConfigured {
    $p = Get-InventoryConfigPath
    if (-not (Test-Path $p)) { return $false }
    try { $c = Get-Content $p -Raw | ConvertFrom-Json; return ([bool]$c.enabled -and [bool]$c.siteId -and [bool]$c.listId) } catch { return $false }
}
function Get-InventoryConfig { Get-Content (Get-InventoryConfigPath) -Raw | ConvertFrom-Json }

# Site/list IDs are stored resolved in config, so no Graph round-trip needed to get context.
function Get-InventoryContext {
    $c = Get-InventoryConfig
    @{ siteId = [string]$c.siteId; listId = [string]$c.listId; fields = $c.fields }
}

# All inventory rows as simplified objects, cached ~90s. The whole list is small (few hundred), so we pull
# it once and do case-insensitive SUBSTRING matching in memory (searching "379" finds LAPTOP379) - something
# SharePoint/Graph $filter can't do (it only supports startswith on indexed columns, and case-sensitively).
# Swaps read fresh via Find-InventoryItemByTitle, so the only staleness is the browse view showing a
# just-changed row for up to ~90s.
$script:InvCache = $null
$script:InvCacheAt = [datetime]::MinValue
function Get-InventoryAll {
    param([switch]$Refresh)
    if (-not $Refresh -and $script:InvCache -and (((Get-Date) - $script:InvCacheAt).TotalSeconds -lt 90)) { return $script:InvCache }
    $ctx = Get-InventoryContext; $f = $ctx.fields
    $items = @(); $uri = "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items?`$expand=fields&`$top=200"
    do { $resp = Invoke-GraphWrite -Method GET -Uri $uri; $items += @($resp.value); $uri = [string]$resp.'@odata.nextLink' } while ($uri)
    $script:InvCache = @($items | ForEach-Object {
        $fl = $_.fields
        [pscustomobject]@{
            id               = [string]$_.id
            title            = [string]$fl.($f.title)
            owner            = [string]$fl.($f.owner)
            deploymentStatus = [string]$fl.($f.deploymentStatus)
            computerStatus   = [string]$fl.($f.computerStatus)
            physicalStatus   = [string]$fl.($f.physicalStatus)
            intuneStatus     = [string](@($fl.($f.intuneStatus)) -join ', ')
            serial           = [string]$fl.($f.serial)
            model            = [string]$fl.($f.model)
            dateIssued       = [string]$fl.($f.dateIssued)
            warranty         = [string]$fl.($f.warranty)
            purchaseDate     = [string]$fl.($f.purchaseDate)
            comment          = [string]$fl.($f.comment)
        }
    } | Sort-Object title)
    $script:InvCacheAt = Get-Date
    $script:InvCache
}

# Browse/search the inventory - substring match on computer name, owner, or serial (blank = all).
function Get-InventoryItems {
    param([string]$Search, [int]$Max = 600)
    $rows = Get-InventoryAll
    if ($Search) {
        $q = [string]$Search
        $rows = @($rows | Where-Object { ($_.title -like "*$q*") -or ($_.owner -like "*$q*") -or ($_.serial -like "*$q*") })
    }
    @($rows | Select-Object -First $Max)
}

# Fast device-name matches for the swap typeahead (substring on computer name).
function Find-InventoryTitles {
    param([string]$Query, [int]$Max = 12)
    $q = [string]$Query
    @(Get-InventoryAll | Where-Object { $_.title -like "*$q*" } | Select-Object -First $Max)
}

# All Intune managed-device NAMES, cached ~5 min (via the READ app). Used by the Create-User Intune
# typeahead. We pull the full name list once and substring-match in memory (Intune managedDevices $filter
# doesn't support startswith on deviceName reliably), returning only the top N so the huge device count
# never reaches the browser - the "just show the first ten" approach.
$script:IntuneNames = $null
$script:IntuneNamesAt = [datetime]::MinValue
function Get-IntuneDeviceNames {
    param([switch]$Refresh)
    if (-not $Refresh -and $script:IntuneNames -and (((Get-Date) - $script:IntuneNamesAt).TotalSeconds -lt 300)) { return $script:IntuneNames }
    $names = New-Object System.Collections.Generic.List[string]
    $tok = Get-GraphToken
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=deviceName&`$top=200"
    do {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec 30
        foreach ($d in $resp.value) { if ($d.deviceName) { $names.Add([string]$d.deviceName) } }
        $uri = [string]$resp.'@odata.nextLink'
    } while ($uri)
    $script:IntuneNames = @($names | Sort-Object -Unique)
    $script:IntuneNamesAt = Get-Date
    $script:IntuneNames
}
function Find-IntuneDeviceNames {
    param([string]$Query, [int]$Max = 10)
    $q = [string]$Query
    if (-not $q) { return @() }
    @(Get-IntuneDeviceNames | Where-Object { $_ -like "*$q*" } | Select-Object -First $Max)
}

# Resolve the "reimage" user (config: reimageUser - a UPN, or a sam/mailNickname like 'zimageuser') to an
# Entra object id, cached per identifier. Returned devices swapped OUT get this user set as their Intune
# primary user. $null if not configured or unresolvable (the swap then just skips that step).
$script:ReimageUserId = $null
$script:ReimageUserFor = $null
function Get-ReimageUserId {
    $ident = [string](Get-InventoryConfig).reimageUser
    if (-not $ident) { return $null }
    if ($script:ReimageUserId -and $script:ReimageUserFor -eq $ident) { return $script:ReimageUserId }
    $hdr = @{ Authorization = "Bearer $(Get-GraphToken)" }
    $id = $null
    if ($ident -like '*@*') {
        try {
            $r = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($ident))?`$select=id" -Headers $hdr -TimeoutSec 15
            $id = [string]$r.id
        } catch {}
    }
    if (-not $id) {
        $esc = $ident -replace "'", "''"
        foreach ($flt in @("mailNickname eq '$esc'", "startswith(userPrincipalName,'$esc')")) {
            try {
                $r = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/users?`$filter=$([uri]::EscapeDataString($flt))&`$select=id&`$top=1" -Headers $hdr -TimeoutSec 15
                $id = [string](@($r.value)[0].id)
                if ($id) { break }
            } catch {}
        }
    }
    if ($id) { $script:ReimageUserId = $id; $script:ReimageUserFor = $ident }
    $id
}

# --- choice options, status change, and add-computer (single + bulk) --------------------------------

# Choice options for the status columns, read live from the list schema and cached ~10 min so the form
# dropdowns always match SharePoint.
$script:InvChoices = $null
$script:InvChoicesAt = [datetime]::MinValue
function Get-InventoryChoices {
    if ($script:InvChoices -and (((Get-Date) - $script:InvChoicesAt).TotalSeconds -lt 600)) { return $script:InvChoices }
    $ctx = Get-InventoryContext; $f = $ctx.fields
    $cols = Invoke-GraphWrite -Method GET -Uri "/sites/$($ctx.siteId)/lists/$($ctx.listId)/columns?`$top=200"
    $byName = @{}
    foreach ($c in $cols.value) { if ($c.choice) { $byName[[string]$c.name] = @($c.choice.choices) } }
    $script:InvChoices = @{
        deployment = @($byName[[string]$f.deploymentStatus])
        computer   = @($byName[[string]$f.computerStatus])
        intune     = @($byName[[string]$f.intuneStatus])
    }
    $script:InvChoicesAt = Get-Date
    $script:InvChoices
}

# Change an existing device's status (Deployment / Computer) and optional comment.
function Set-InventoryStatus {
    param([string]$Title, [string]$Deployment, [string]$Computer, [string]$Physical, [string]$Comment, [switch]$SetComment)
    $ctx = Get-InventoryContext; $f = $ctx.fields
    $item = Find-InventoryItemByTitle $Title
    if (-not $item) { return @{ ok = $false; error = "'$Title' not found in inventory" } }
    $fields = @{}
    if ($Deployment) { $fields[$f.deploymentStatus] = $Deployment }
    if ($Computer)   { $fields[$f.computerStatus]   = $Computer }
    # Physical Status is free text (field_1); set it only when something was typed (blank = leave unchanged).
    if ($Physical -and "$Physical".Trim()) { $fields[$f.physicalStatus] = "$Physical".Trim() }
    if ($SetComment) { $fields[$f.comment] = [string]$Comment }
    if (-not $fields.Count) { return @{ ok = $false; error = 'nothing to change' } }
    try { Set-InventoryFields -ItemId $item.id -Fields $fields | Out-Null; return @{ ok = $true } }
    catch { return @{ ok = $false; error = (Get-GraphError $_) } }
}

# Intune device detail for the intake autofill (serial/model/manufacturer/OS). $null if not enrolled.
function Get-IntuneDeviceDetail {
    param([string]$DeviceName)
    if (-not $DeviceName) { return $null }
    $flt = [uri]::EscapeDataString("deviceName eq '$(([string]$DeviceName) -replace "'", "''")'")
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$flt&`$select=id,deviceName,serialNumber,model,manufacturer,operatingSystem,osVersion"
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $(Get-GraphToken)" } -TimeoutSec 20
        @($resp.value) | Select-Object -First 1
    } catch { $null }
}

# Add one computer. $Row is a hashtable keyed by the FRIENDLY field names (title/brand/model/serial/os/
# deploymentStatus/computerStatus/purchaseDate/purchasePrice/warranty/comment) plus optional intuneStatus.
# Refuses a duplicate Title. Returns @{ ok; error; title }.
function Add-InventoryComputer {
    param([hashtable]$Row)
    $ctx = Get-InventoryContext; $f = $ctx.fields
    $title = ([string]$Row.title).Trim()
    if (-not $title) { return @{ ok = $false; error = 'missing computer name'; title = '' } }
    if (Find-InventoryItemByTitle $title) { return @{ ok = $false; error = 'a computer with this name already exists'; title = $title } }

    $fields = @{ $f.title = $title }
    foreach ($k in 'brand', 'model', 'serial', 'os', 'comment', 'deploymentStatus', 'computerStatus') {
        if ($Row.ContainsKey($k) -and "$($Row[$k])".Trim()) { $fields[$f.$k] = "$($Row[$k])".Trim() }
    }
    # dates -> ISO 8601 (noon UTC); price -> number
    foreach ($k in 'purchaseDate', 'warranty') {
        if ($Row.ContainsKey($k) -and "$($Row[$k])".Trim()) {
            $dt = [datetime]::MinValue
            if ([datetime]::TryParse("$($Row[$k])", [ref]$dt)) { $fields[$f.$k] = $dt.ToString('yyyy-MM-ddT12:00:00Z') }
        }
    }
    if ($Row.ContainsKey('purchasePrice') -and "$($Row.purchasePrice)".Trim()) {
        $num = 0.0; if ([double]::TryParse((("$($Row.purchasePrice)") -replace '[^0-9.\-]', ''), [ref]$num)) { $fields[$f.purchasePrice] = $num }
    }
    try {
        $new = Invoke-GraphWrite -Method POST -Uri "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items" -Body @{ fields = $fields }
        # Intune Status is a multi-select choice -> separate Collection(Edm.String) PATCH.
        $iv = if ($Row.ContainsKey('intuneStatus') -and "$($Row.intuneStatus)".Trim()) { "$($Row.intuneStatus)".Trim() } else { $null }
        if ($iv) { try { Set-InventoryMultiChoice -ItemId $new.id -FieldInternalName $f.intuneStatus -Values @($iv) | Out-Null } catch {} }
        @{ ok = $true; title = $title }
    } catch { @{ ok = $false; error = (Get-GraphError $_); title = $title } }
}

# --- swap: find one item by exact Title, patch fields, orchestrate a computer swap -------------------

function Find-InventoryItemByTitle {
    param([string]$Title)
    if (-not $Title) { return $null }
    $ctx = Get-InventoryContext; $f = $ctx.fields
    $esc = ([string]$Title) -replace "'", "''"
    $uri = "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items?`$expand=fields&`$filter=fields/$($f.title) eq '$esc'&`$top=2"
    $resp = Invoke-GraphWrite -Method GET -Uri $uri -Headers @{ Prefer = 'HonorNonIndexedQueriesWarningMayFailRandomly' }
    $hit = @($resp.value)
    if ($hit.Count -ge 1) { return $hit[0] }   # raw Graph item: has .id and .fields
    $null
}

function Set-InventoryFields {
    param([string]$ItemId, [hashtable]$Fields)
    $ctx = Get-InventoryContext
    Invoke-GraphWrite -Method PATCH -Uri "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items/$ItemId/fields" -Body $Fields
}

# Multi-select (checkbox) choice columns must be written as a Collection(Edm.String) via a RAW JSON body -
# the @odata.type annotation is required, and a single-element array would otherwise collapse to a scalar
# under WinPS 5.1 ConvertTo-Json. (Choice values here are fixed/controlled, so no escaping needed.)
function Set-InventoryMultiChoice {
    param([string]$ItemId, [string]$FieldInternalName, [string[]]$Values)
    $ctx = Get-InventoryContext
    $arr = (@($Values) | ForEach-Object { '"' + [string]$_ + '"' }) -join ','
    $body = '{"' + $FieldInternalName + '@odata.type":"Collection(Edm.String)","' + $FieldInternalName + '":[' + $arr + ']}'
    Invoke-GraphWrite -Method PATCH -Uri "/sites/$($ctx.siteId)/lists/$($ctx.listId)/items/$ItemId/fields" -Body $body
}

# Intune managed device(s) matching a deviceName, via the READ app. Direct non-paged REST (an exact-name
# filter returns 0-1 rows). IMPORTANT: callers must wrap the result in @() - a single match unrolls to a
# scalar on assignment, so `$md.Count` would be $null (this exact trap gave the swap preview a false
# "not found in Intune").
function Get-IntuneDeviceIdByName {
    param([string]$DeviceName)
    if (-not $DeviceName) { return @() }
    $flt = [uri]::EscapeDataString("deviceName eq '$(([string]$DeviceName) -replace "'", "''")'")
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$flt&`$select=id,deviceName"
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $(Get-GraphToken)" } -TimeoutSec 20
        @($resp.value)
    } catch { @() }
}

# Dry run: resolve everything and describe what a swap WOULD do (no writes).
function Get-SwapPreview {
    param([string]$UserDisplayName, [string]$OldTitle, [string]$NewTitle, [string]$OldPhysical)
    $ctx = Get-InventoryContext; $f = $ctx.fields
    $newItem = Find-InventoryItemByTitle $NewTitle
    $oldItem = Find-InventoryItemByTitle $OldTitle
    $md = @(Get-IntuneDeviceIdByName $NewTitle)
    $mdOld = @(Get-IntuneDeviceIdByName $OldTitle)
    $warnings = @()
    if ($NewTitle -and -not $newItem) { $warnings += "New device '$NewTitle' not found in inventory." }
    if ($OldTitle -and -not $oldItem) { $warnings += "Old device '$OldTitle' not found in inventory - its record won't be updated." }
    if ($NewTitle -and $md.Count -eq 0) { $warnings += "New device '$NewTitle' not found in Intune - primary user won't be set (retry once enrolled)." }
    if ($md.Count -gt 1) { $warnings += "New device '$NewTitle' matches $($md.Count) Intune devices - primary user won't be set automatically." }
    [pscustomobject]@{
        user = $UserDisplayName; newTitle = $NewTitle; oldTitle = $OldTitle
        newFound = [bool]$newItem; oldFound = [bool]$oldItem; intuneFound = ($md.Count -eq 1); oldIntuneFound = ($mdOld.Count -eq 1)
        reimageUser = [string](Get-InventoryConfig).reimageUser
        oldPhysical = [string]$OldPhysical
        newCurrentOwner = if ($newItem) { [string]$newItem.fields.($f.owner) } else { '' }
        oldCurrentOwner = if ($oldItem) { [string]$oldItem.fields.($f.owner) } else { '' }
        warnings = @($warnings)
    }
}

# Execute the swap: new device -> user (inventory + Intune primary), old device -> returned (inventory).
# Idempotent-ish and best-effort per step; returns per-step status so partials are visible.
function Invoke-ComputerSwap {
    param([string]$UserDisplayName, [string]$UserId, [string]$OldTitle, [string]$NewTitle, [string]$OldPhysical)
    $ctx = Get-InventoryContext; $f = $ctx.fields
    # SharePoint dateTime columns need ISO 8601; noon UTC so date-only display doesn't roll back a day in US zones.
    $today = (Get-Date).ToString('yyyy-MM-ddT12:00:00Z')
    $steps = @(); $ok = $true

    $newItem = Find-InventoryItemByTitle $NewTitle
    if (-not $newItem) {
        return [pscustomobject]@{ ok = $false; user = $UserDisplayName; newTitle = $NewTitle; oldTitle = $OldTitle;
            steps = @(@{ step = "New device"; ok = $false; msg = "'$NewTitle' not found in inventory - nothing was changed." }) }
    }

    # Resolve the new device in Intune up front - it drives both the Intune Status field (Intune vs Not
    # Managed) and the primary-user set below.
    $md = @(Get-IntuneDeviceIdByName $NewTitle)
    $newIntuneVal = if ($md.Count -eq 1) { 'Intune' } else { 'Not Managed' }

    # 1) New device inventory fields. Intune Status is a multi-select (checkbox) choice, so it goes in a
    #    separate Collection(Edm.String) PATCH; the plain fields go in one normal PATCH so the multi-choice
    #    quirk can't fail the whole update.
    $nf = @{}
    $nf[$f.owner] = $UserDisplayName; $nf[$f.dateIssued] = $today
    $nf[$f.deploymentStatus] = 'Deployed'; $nf[$f.computerStatus] = 'Deployed'
    try {
        Set-InventoryFields -ItemId $newItem.id -Fields $nf | Out-Null
        $msg = "owner -> $UserDisplayName; status -> Deployed"
        try { Set-InventoryMultiChoice -ItemId $newItem.id -FieldInternalName $f.intuneStatus -Values @($newIntuneVal) | Out-Null; $msg += "; Intune -> $newIntuneVal" }
        catch { $msg += "; (Intune Status not set: $(Get-GraphError $_))" }
        $steps += @{ step = "Inventory: $NewTitle"; ok = $true; msg = $msg }
    }
    catch { $ok = $false; $steps += @{ step = "Inventory: $NewTitle"; ok = $false; msg = (Get-GraphError $_) } }

    # 2) New device Intune primary user (uses $md resolved above)
    if (($md.Count -eq 1) -and $UserId) {
        $pr = Set-IntuneDevicePrimaryUser -DeviceId ([string]$md[0].id) -UserId $UserId
        if ($pr.ok) { $steps += @{ step = 'Intune primary user'; ok = $true; msg = "set to $UserDisplayName" } }
        else { $ok = $false; $steps += @{ step = 'Intune primary user'; ok = $false; msg = $pr.error } }
    }
    elseif (-not $UserId) { $ok = $false; $steps += @{ step = 'Intune primary user'; ok = $false; msg = 'no user id (pick the user from the dropdown) - skipped' } }
    else {
        $ok = $false
        $reason = if ($md.Count -eq 0) { 'device not found in Intune (retry once enrolled)' } else { "matches $($md.Count) Intune devices" }
        $steps += @{ step = 'Intune primary user'; ok = $false; msg = "$reason - skipped" }
    }

    # 3) Old device -> returned: owner cleared, Deployment 'Needs Image', Computer 'Needs to be Imaged',
    #    and Intune Status toggled to match whether it's still a managed device in Intune.
    if ($OldTitle) {
        $oldItem = Find-InventoryItemByTitle $OldTitle
        $mdOld = @(Get-IntuneDeviceIdByName $OldTitle)
        if ($oldItem) {
            $of = @{}
            $of[$f.owner] = ''; $of[$f.deploymentStatus] = 'Needs Image'; $of[$f.computerStatus] = 'Needs to be Imaged'
            # Physical Status is free text typed by the tech (blank = leave unchanged).
            if ($OldPhysical -and "$OldPhysical".Trim()) { $of[$f.physicalStatus] = "$OldPhysical".Trim() }
            $oldIntuneVal = if ($mdOld.Count -eq 1) { 'Intune' } else { 'Not Managed' }
            try {
                Set-InventoryFields -ItemId $oldItem.id -Fields $of | Out-Null
                $omsg = 'owner cleared; status -> Needs Image'
                if ($OldPhysical -and "$OldPhysical".Trim()) { $omsg += "; physical -> $("$OldPhysical".Trim())" }
                try { Set-InventoryMultiChoice -ItemId $oldItem.id -FieldInternalName $f.intuneStatus -Values @($oldIntuneVal) | Out-Null; $omsg += "; Intune -> $oldIntuneVal" }
                catch { $omsg += "; (Intune Status not set: $(Get-GraphError $_))" }
                $steps += @{ step = "Inventory: $OldTitle"; ok = $true; msg = $omsg }
            }
            catch { $ok = $false; $steps += @{ step = "Inventory: $OldTitle"; ok = $false; msg = (Get-GraphError $_) } }
        }
        else { $ok = $false; $steps += @{ step = "Inventory: $OldTitle"; ok = $false; msg = 'not found in inventory - skipped' } }

        # Old device Intune primary user -> the reimage user (e.g. zimageuser), so the returned machine is
        # ready to be re-imaged. Only when the old device is a single Intune match and a reimage user is set.
        if ($mdOld.Count -eq 1) {
            $reLabel = [string](Get-InventoryConfig).reimageUser
            $riId = Get-ReimageUserId
            if ($riId) {
                $pr = Set-IntuneDevicePrimaryUser -DeviceId ([string]$mdOld[0].id) -UserId $riId
                if ($pr.ok) { $steps += @{ step = 'Intune primary user (old)'; ok = $true; msg = "set to $reLabel" } }
                else { $ok = $false; $steps += @{ step = 'Intune primary user (old)'; ok = $false; msg = $pr.error } }
            }
            else { $steps += @{ step = 'Intune primary user (old)'; ok = $true; msg = 'no reimage user configured (reimageUser) - skipped' } }
        }
    }

    [pscustomobject]@{ ok = $ok; user = $UserDisplayName; newTitle = $NewTitle; oldTitle = $OldTitle; steps = @($steps) }
}

