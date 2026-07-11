# UserProvision.ps1 - Phase-1 on-prem AD user creation + department mapping + cloud-onboarding queue.
#
# SECURITY MODEL:
#  - WRITE operations bind to AD with the OPERATOR's OWN credentials (passed per request),
#    never the read-only service account. The service account stays read-only.
#  - The live create is gated by the 'enabled' flag in provisioning settings (default OFF).
#    Until AD create-delegation exists and the flag is on, /users/new/create runs preview-only.
#  - Cloud group/license (Phase 2) is deferred until the user syncs to Entra, then handled by a
#    dedicated app-only Graph write app. This file only queues the pending cloud work.

# Default OU that decommissioned users are disabled + moved into (out of the Entra sync scope, so
# ADSync then removes them from Entra). Overridable via provision.json "disabledOu".
$script:DefaultDisabledOu = 'OU=Disabled Accounts,DC=example,DC=org'

function Get-ProvisionSettings {
    $s = Get-Store provision
    if (-not $s) { return [pscustomobject]@{ enabled=$false; upnSuffix=''; supervisorGroup='Supervisors'; supervisorGroups=@('Supervisors','Supervisors_TRD'); licenseSkuId=''; usageLocation='US'; onboardingAutoRun=$false; disabledOu=$script:DefaultDisabledOu; baseGroups=@(); onCallGroup=''; onCallExceptDepartments=@(); departments=@() } }
    foreach ($f in 'baseGroups','onCallExceptDepartments','departments','supervisorGroups') { if ($null -eq $s.$f) { $s | Add-Member -NotePropertyName $f -NotePropertyValue @() -Force } }
    if ($null -eq $s.onCallGroup)       { $s | Add-Member -NotePropertyName onCallGroup -NotePropertyValue '' -Force }
    if ($null -eq $s.supervisorGroup)   { $s | Add-Member -NotePropertyName supervisorGroup -NotePropertyValue 'Supervisors' -Force }
    if ($null -eq $s.licenseSkuId)      { $s | Add-Member -NotePropertyName licenseSkuId -NotePropertyValue '' -Force }
    if ($null -eq $s.usageLocation)     { $s | Add-Member -NotePropertyName usageLocation -NotePropertyValue 'US' -Force }
    if ($null -eq $s.onboardingAutoRun) { $s | Add-Member -NotePropertyName onboardingAutoRun -NotePropertyValue $false -Force }
    if ([string]::IsNullOrWhiteSpace([string]$s.disabledOu)) { $s | Add-Member -NotePropertyName disabledOu -NotePropertyValue $script:DefaultDisabledOu -Force }
    return $s
}
function Set-ProvisionSettings($Settings) { Set-Store provision $Settings }

# Pure computation: derive the account fields from raw inputs + the chosen department mapping.
# Needs no directory access, so it is safe to call for live preview.
function Get-ProvisionPlan {
    param([string]$FirstName,[string]$LastName,[string]$Username,[string]$Department,[string]$Manager,[string[]]$JobTitles,[string]$Mobile,[switch]$IsSupervisor,[string]$IntuneDevice)
    $s = Get-ProvisionSettings
    $suffix = if ($s.upnSuffix) { $s.upnSuffix } else { (Get-Store config).ldapServer }
    $match = @($s.departments | Where-Object { $_.name -eq $Department })
    $dept = if ($match.Count) { $match[0] } else { $null }
    $sam = (([string]$Username).Trim().ToLower() -replace '[^a-z0-9.\-_]','')
    $first = ([string]$FirstName).Trim(); $last = ([string]$LastName).Trim()
    # Resolve group membership, in order:
    #   base groups (everyone) + On Call (unless this dept is excepted) + department groups
    #   + each selected job title's addGroups, minus each selected job title's removeGroups.
    # Job titles let one department grant role-specific groups (e.g. Autism > Behavioral Technician
    # gets a different set and no On Call) without inventing a separate pseudo-department.
    $except = @($s.onCallExceptDepartments | ForEach-Object { ([string]$_).ToLower() })
    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($g in @($s.baseGroups)) { if ($g) { [void]$resolved.Add([string]$g) } }
    if ($s.onCallGroup -and ($except -notcontains ([string]$Department).ToLower())) { [void]$resolved.Add([string]$s.onCallGroup) }
    if ($dept) { foreach ($g in @($dept.cloudGroups)) { if ($g) { [void]$resolved.Add([string]$g) } } }
    $selectedJobs = @(); $removeSet = @{}
    if ($dept -and $JobTitles) {
        foreach ($jtName in $JobTitles) {
            $jt = @($dept.jobTitles | Where-Object { $_.name -eq $jtName })
            if ($jt.Count) {
                $j = $jt[0]; $selectedJobs += [string]$j.name
                foreach ($g in @($j.addGroups))    { if ($g) { [void]$resolved.Add([string]$g) } }
                foreach ($g in @($j.removeGroups)) { if ($g) { $removeSet[([string]$g).ToLower()] = $true } }
            }
        }
    }
    # Optional, deliberate "mark as supervisor" - most new users are NOT supervisors, so this is a
    # separate switch, not tied to any department/job title.
    if ($IsSupervisor) { foreach ($g in @($s.supervisorGroups)) { if ($g) { [void]$resolved.Add([string]$g) } } }
    $seen = @{}; $cloudGroups = @()
    foreach ($g in $resolved) { $lk = $g.ToLower(); if ($removeSet.ContainsKey($lk)) { continue }; if (-not $seen.ContainsKey($lk)) { $seen[$lk] = $true; $cloudGroups += $g } }
    [pscustomobject]@{
        firstName         = $first
        lastName          = $last
        displayName       = ("$first $last").Trim()
        samAccountName    = $sam
        userPrincipalName = if ($sam -and $suffix) { "$sam@$suffix" } else { '' }
        department        = $Department
        manager           = ([string]$Manager).Trim()
        mobile            = ([string]$Mobile).Trim()
        isSupervisor      = [bool]$IsSupervisor
        intuneDevice      = ([string]$IntuneDevice).Trim()
        ou                = if ($dept) { [string]$dept.ou } else { '' }
        cloudGroups       = $cloudGroups
        departmentGroups  = if ($dept) { @($dept.cloudGroups) } else { @() }
        jobTitles         = @($selectedJobs)
        title             = if ($selectedJobs.Count) { [string]$selectedJobs[0] } else { '' }
        licenseGroup      = if ($dept -and $dept.licenseGroup) { [string]$dept.licenseGroup } else { '' }
        mappingFound      = [bool]$dept
        enabled           = [bool]$s.enabled
    }
}

function Test-ProvisionPlan([pscustomobject]$Plan) {
    $errs = New-Object System.Collections.Generic.List[string]
    if (-not $Plan.firstName)      { $errs.Add('First name is required.') }
    if (-not $Plan.lastName)       { $errs.Add('Last name is required.') }
    if (-not $Plan.samAccountName) { $errs.Add('Username is required (letters, digits, . - _).') }
    elseif ($Plan.samAccountName.Length -gt 20) { $errs.Add("Username '$($Plan.samAccountName)' exceeds the 20-character sAMAccountName limit.") }
    if (-not $Plan.mappingFound)   { $errs.Add("Department '$($Plan.department)' has no mapping (add it under Config > Department mapping).") }
    elseif (-not $Plan.ou)         { $errs.Add("Department '$($Plan.department)' has no OU configured.") }
    if (-not $Plan.userPrincipalName) { $errs.Add('Cannot form a UPN (missing username or UPN suffix).') }
    return $errs
}

# Escape a value for safe use as an RDN attribute value in a DN (RFC 4514), so a display name containing
# DN metacharacters (e.g. "Smith, Jr") can't break or relocate the created object's CN. For a normal name
# with no special characters this returns the value unchanged. .Replace() is literal (non-regex).
function ConvertTo-RdnValue([string]$v) {
    if ([string]::IsNullOrEmpty($v)) { return $v }
    $bs = [string][char]92
    $v = $v.Replace($bs, $bs + $bs).Replace(',', $bs + ',').Replace('+', $bs + '+').Replace('"', $bs + '"').Replace('<', $bs + '<').Replace('>', $bs + '>').Replace(';', $bs + ';').Replace('=', $bs + '=')
    if ($v.StartsWith('#') -or $v.StartsWith(' ')) { $v = $bs + $v }
    if ($v.EndsWith(' ')) { $v = $v.Substring(0, $v.Length - 1) + $bs + ' ' }
    $v
}

# Phase 1: create the on-prem AD user via ADSI, binding as the operator. UNTESTED until go-live;
# only reachable when provisioning is enabled.
function New-OnPremUser {
    param([pscustomobject]$Plan,[string]$Password,[string]$OperatorUser,[string]$OperatorPassword,[bool]$MustChangePassword = $true)
    $cfg = Get-Store config
    $server = if ($cfg.ldapServer) { $cfg.ldapServer } else { $env:USERDNSDOMAIN }
    try {
        $ou = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$server/$($Plan.ou)", $OperatorUser, $OperatorPassword)
        [void]$ou.NativeObject   # forces a bind now
        # A bad operator credential (or wrong OU) does NOT reliably throw here - the bind can come back
        # with a null Children collection, which would otherwise fail two lines down as the cryptic
        # "You cannot call a method on a null-valued expression." Catch it now with a clear message.
        if ($null -eq $ou.Children) {
            throw "Could not bind to the target OU as operator '$OperatorUser'. Enter YOUR OWN AD username and password (the account authorized to create users) - not the new user's name - and confirm the OU '$($Plan.ou)' exists."
        }
        $user = $ou.Children.Add("CN=$(ConvertTo-RdnValue $Plan.displayName)", 'user')
        $user.Properties['sAMAccountName'].Value    = $Plan.samAccountName
        $user.Properties['userPrincipalName'].Value = $Plan.userPrincipalName
        $user.Properties['givenName'].Value         = $Plan.firstName
        $user.Properties['sn'].Value                = $Plan.lastName
        $user.Properties['displayName'].Value       = $Plan.displayName
        if ($Plan.department) { $user.Properties['department'].Value = $Plan.department }
        if ($Plan.title)      { $user.Properties['title'].Value = $Plan.title }   # AD "Job Title"; syncs to Entra jobTitle
        if ($Plan.mobile)     { $user.Properties['mobile'].Value = $Plan.mobile }
        $user.CommitChanges()
        $user.Invoke('SetPassword', $Password) | Out-Null
        $user.Properties['userAccountControl'].Value = 0x200   # NORMAL_ACCOUNT, enabled
        # pwdLastSet = 0 forces a change at next logon; -1 stamps it "now" so no change is required.
        $user.Properties['pwdLastSet'].Value = if ($MustChangePassword) { 0 } else { -1 }
        if ($Plan.manager) {
            $mdn = Resolve-UserDN $server $Plan.manager $OperatorUser $OperatorPassword
            if ($mdn) { $user.Properties['manager'].Value = $mdn }
        }
        $user.CommitChanges()
        return @{ ok=$true; dn=[string]$user.Properties['distinguishedName'].Value }
    } catch {
        return @{ ok=$false; error=$_.Exception.Message }
    }
}

function Resolve-UserDN($server,$idlike,$u,$p) {
    try {
        $root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$server", $u, $p)
        $ds = New-Object System.DirectoryServices.DirectorySearcher($root)
        $sam = ($idlike -split '\\')[-1] -replace '@.*$',''
        $samF = ConvertTo-LdapFilterValue $sam; $idF = ConvertTo-LdapFilterValue $idlike
        $ds.Filter = "(&(objectCategory=person)(|(sAMAccountName=$samF)(userPrincipalName=$idF)(displayName=$idF)))"
        $r = $ds.FindOne()
        if ($r) { return [string]$r.Properties['distinguishedname'][0] }
    } catch {}
    return $null
}

# Queue the cloud work (group/license) to be applied once Entra Connect syncs the new user.
function Add-OnboardingPending {
    param([pscustomobject]$Plan,[string]$Operator,[string]$OperatorRole,[string]$Dn)
    $q = @(Get-Store onboarding)
    $q += [pscustomobject]@{
        id            = [guid]::NewGuid().ToString()
        upn           = $Plan.userPrincipalName
        displayName   = $Plan.displayName
        department    = $Plan.department
        title         = $Plan.title
        mobile        = $Plan.mobile
        cloudGroups   = @($Plan.cloudGroups)
        intuneDevice  = [string]$Plan.intuneDevice
        dn            = $Dn
        createdBy     = $Operator
        createdByRole = $OperatorRole          # drives the completion/failure email recipient (admin vs helpdesk)
        createdAt     = (Get-Date).ToString('o')
        cloudStatus   = 'pending-sync'
        groupsAdded   = @()
        groupsExo     = @()
        groupsFailed  = @()
        attempts      = 0
        lastRun       = ''
        note          = 'queued'
        notified      = $false                 # completion/failure email sent once, then suppressed
        completedAt   = ''                      # stamped when first reaching 'complete' (drives 7-day cleanup)
    }
    Set-Store onboarding $q
}

# Supervisor picklist for the Create User form, sourced from the Entra "Supervisors" group via Graph.
# Cached in the store so we don't hit Graph on every page render; falls back to stale/empty on error.
function Get-Supervisors {
    param([int]$MaxAgeMinutes = 240, [switch]$Force)
    $cache = Get-Store supervisors-cache
    $fresh = $cache -and $cache.fetchedAt -and (((Get-Date) - [datetime]$cache.fetchedAt).TotalMinutes -lt $MaxAgeMinutes)
    if ($fresh -and -not $Force) { return @($cache.list) }
    try {
        $gn = (Get-ProvisionSettings).supervisorGroup; if (-not $gn) { $gn = 'Supervisors' }
        $users = Get-EntraGroupUsers -GroupName $gn -Select @('displayName','userPrincipalName','jobTitle')
        $list = @($users | Where-Object { $_.userPrincipalName } |
                    ForEach-Object { [pscustomobject]@{ name=[string]$_.displayName; upn=[string]$_.userPrincipalName; title=[string]$_.jobTitle } } |
                    Sort-Object name)
        Set-Store supervisors-cache ([pscustomobject]@{ fetchedAt=(Get-Date).ToString('o'); group=$gn; list=$list })
        return $list
    } catch {
        if ($cache -and $cache.list) { return @($cache.list) }   # stale is better than nothing
        return @()
    }
}
