# GraphWrite.ps1 - app-only Microsoft Graph WRITE helper for Phase-2 onboarding
# (usageLocation + license assignment + cloud group membership).
#
# Uses the SEPARATE PSConsole-Graph-Write app registration (data\graph-write.config.json), which holds
# GroupMember.ReadWrite.All + User.ReadWrite.All. Kept distinct from the read-only graph.config.json on
# purpose: the read app can never write, and this write app is only ever used by the onboarding path.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-GraphWriteConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'graph-write.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\graph-write.config.json' }
}
function Test-GraphWriteConfigured { Test-Path (Get-GraphWriteConfigPath) }

function Get-GraphWriteToken {
    if ($script:GWTok -and $script:GWTokExp -and (Get-Date) -lt $script:GWTokExp) { return $script:GWTok }
    $cfgPath = Get-GraphWriteConfigPath
    if (-not (Test-Path $cfgPath)) { throw "Graph-write config not found at $cfgPath. Run graph-setup\Set-GraphWriteCredential.ps1 on this server." }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    Add-Type -AssemblyName System.Security
    $secret = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($cfg.secret),$null,'LocalMachine'))
    $body = @{ client_id=$cfg.clientId; scope='https://graph.microsoft.com/.default'; client_secret=$secret; grant_type='client_credentials' }
    $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($cfg.tenantId)/oauth2/v2.0/token" -Body $body
    $script:GWTok = $r.access_token
    $script:GWTokExp = (Get-Date).AddSeconds([int]$r.expires_in - 300)
    $script:GWTok
}

# $Body may be a hashtable (JSON-encoded here) or a pre-built JSON string (used where PS 5.1's
# single-element-array collapse would otherwise corrupt the payload, e.g. assignLicense).
function Invoke-GraphWrite {
    param([ValidateSet('GET','POST','PATCH','PUT','DELETE')][string]$Method,[string]$Uri,$Body,[hashtable]$Headers,[switch]$Beta)
    $tok = Get-GraphWriteToken
    if ($Uri -notmatch '^https?://') { $Uri = "https://graph.microsoft.com/$(if ($Beta) { 'beta' } else { 'v1.0' })" + $Uri }
    $hdr = @{ Authorization = "Bearer $tok" }
    if ($Headers) { foreach ($k in $Headers.Keys) { $hdr[$k] = $Headers[$k] } }
    $p = @{ Method=$Method; Uri=$Uri; Headers=$hdr }
    if ($null -ne $Body) {
        $p.ContentType = 'application/json'
        $p.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 6 }
    }
    Invoke-RestMethod @p
}

# Pull the meaningful Graph error text out of an ErrorRecord. Invoke-RestMethod puts the response
# JSON body in .ErrorDetails.Message (where Graph's real "code/message" lives). Preference order:
#   1) parsed Graph "code: message" from the JSON body,
#   2) the raw body if it isn't the expected JSON shape,
#   3) HTTP status + reason phrase (e.g. "HTTP 400 Bad Request") - some 400/404s come back with an
#      empty body, and this is far more useful than the opaque .Exception.Message,
#   4) the generic .Exception.Message as a last resort.
function Get-GraphError($err) {
    $body = $null
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) { $body = $err.ErrorDetails.Message }
    if ($body) {
        try { $j = $body | ConvertFrom-Json; if ($j.error -and $j.error.message) { return "$($j.error.code): $($j.error.message)" } } catch {}
        return $body
    }
    # No JSON error body - surface the HTTP status + reason phrase instead of the opaque
    # "The remote server returned an error: (400) Bad Request." (WinPS 5.1 = HttpWebResponse with
    # .StatusDescription; PS7 = HttpResponseMessage with .ReasonPhrase - handle both.)
    $resp = $null
    if ($err.Exception -and ($err.Exception.PSObject.Properties.Name -contains 'Response')) { $resp = $err.Exception.Response }
    if ($resp) {
        $code = $null; $reason = $null
        try { $code = [int]$resp.StatusCode } catch {}
        try { $reason = [string]$resp.StatusDescription } catch {}
        if (-not $reason) { try { $reason = [string]$resp.ReasonPhrase } catch {} }
        if ($code) {
            if ($reason) { return "HTTP $code $reason" }
            return "HTTP $code"
        }
    }
    "$($err.Exception.Message)"
}

# Add a user (directoryObject id) to a group. Idempotent: an "already exists" response is success.
function Add-EntraGroupMember {
    param([string]$GroupId,[string]$UserId)
    try {
        Invoke-GraphWrite -Method POST -Uri "/groups/$GroupId/members/`$ref" -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$UserId" } | Out-Null
        return @{ ok=$true }
    } catch {
        $msg = Get-GraphError $_
        if ($msg -match 'already exist') { return @{ ok=$true; note='already a member' } }
        return @{ ok=$false; error=$msg }
    }
}

function Set-EntraUsageLocation {
    param([string]$UserId,[string]$UsageLocation)
    try { Invoke-GraphWrite -Method PATCH -Uri "/users/$UserId" -Body @{ usageLocation = $UsageLocation } | Out-Null; return @{ ok=$true } }
    catch { return @{ ok=$false; error="$($_.Exception.Message)" } }
}

# Set the PRIMARY user of an Intune managed device (beta endpoint). Removes any existing primary-user
# reference first (best-effort), then assigns the new one. Requires the write app to hold
# DeviceManagementManagedDevices.ReadWrite.All. Returns @{ ok; error }.
function Set-IntuneDevicePrimaryUser {
    param([string]$DeviceId,[string]$UserId)
    if (-not $DeviceId -or -not $UserId) { return @{ ok=$false; error='missing device or user id' } }
    $ref = "/deviceManagement/managedDevices/$DeviceId/users/`$ref"
    try { Invoke-GraphWrite -Method DELETE -Uri $ref -Beta | Out-Null } catch {}   # clear existing primary user (ok if none)
    try {
        Invoke-GraphWrite -Method POST -Uri $ref -Beta -Body @{ '@odata.id' = "https://graph.microsoft.com/beta/users/$UserId" } | Out-Null
        return @{ ok=$true }
    } catch { return @{ ok=$false; error=(Get-GraphError $_) } }
}

# assignLicense body is built as a raw JSON string on purpose - PS 5.1 collapses a single-element
# array (addLicenses) into an object via ConvertTo-Json, which Graph rejects.
function Set-EntraLicense {
    param([string]$UserId,[string]$SkuId)
    $body = '{"addLicenses":[{"skuId":"' + $SkuId + '","disabledPlans":[]}],"removeLicenses":[]}'
    try { Invoke-GraphWrite -Method POST -Uri "/users/$UserId/assignLicense" -Body $body | Out-Null; return @{ ok=$true } }
    catch {
        $msg = Get-GraphError $_
        if ($msg -match 'already assigned|conflicting|isAssigned') { return @{ ok=$true; note='already licensed' } }
        return @{ ok=$false; error=$msg }
    }
}
