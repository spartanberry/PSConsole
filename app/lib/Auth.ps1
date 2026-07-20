# Auth.ps1 - local (PBKDF2) + LDAPS auth, RBAC. Requires Store.ps1 loaded.

# Ensure the directory assemblies are present in EVERY runspace (Pode route runspaces don't
# auto-load System.DirectoryServices.Protocols, so the first LDAP call would otherwise throw a
# type-not-found and surface as a 500 on login).
Add-Type -AssemblyName System.DirectoryServices.Protocols -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue

function Write-LdapDebug([string]$Msg) {
    try { Add-Content -Path (Join-Path (Get-DataDir) 'ldap-debug.log') -Value ("{0} {1}" -f (Get-Date).ToString('o'), $Msg) } catch {}
}

function New-PasswordHash([string]$Password) {
    $salt = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 120000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $hash = $kdf.GetBytes(32)
    "{0}:{1}:{2}" -f 120000, [Convert]::ToBase64String($salt), [Convert]::ToBase64String($hash)
}
function Test-PasswordHash([string]$Password, [string]$Stored) {
    $parts = $Stored -split ':'
    if ($parts.Count -ne 3) { return $false }
    $iter = [int]$parts[0]; $salt = [Convert]::FromBase64String($parts[1]); $want = [Convert]::FromBase64String($parts[2])
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, $iter, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $got = $kdf.GetBytes(32)
    # CryptographicOperations not in .NET Framework; manual constant-time XOR compare
    $diff = $got.Length -bxor $want.Length
    $n = [Math]::Min($got.Length, $want.Length)
    for ($i = 0; $i -lt $n; $i++) { $diff = $diff -bor ($got[$i] -bxor $want[$i]) }
    $diff -eq 0
}

# Validates a user's OWN credential by binding LDAPS as them. We never store end-user passwords.
function Test-LdapCredential([string]$Username, [string]$Password) {
    # Defence-in-depth: never attempt a bind with an empty password (AD treats an empty-password simple bind
    # as an unauthenticated bind and returns success). Invoke-Authenticate also guards this.
    if ([string]::IsNullOrWhiteSpace($Password)) { return $false }
    try {
        $cfg    = Get-Store config
        $server = $cfg.ldapServer; $port = [int]$cfg.ldapPort; $ssl = [bool]$cfg.ldapUseSsl

        # Attempt 1 - Negotiate (Kerberos/NTLM). Split DOMAIN\user so SSPI gets the domain in its own
        # field; passing "DOMAIN\user" as one string with an empty domain is rejected as invalid.
        if ($Username -match '^([^\\]+)\\(.+)$') { $cred = New-Object System.Net.NetworkCredential($Matches[2], $Password, $Matches[1]) }
        else { $cred = New-Object System.Net.NetworkCredential($Username, $Password) }
        $id   = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier($server, $port)
        $conn = New-Object System.DirectoryServices.Protocols.LdapConnection($id, $cred)
        $conn.SessionOptions.ProtocolVersion = 3
        if ($ssl) { $conn.SessionOptions.SecureSocketLayer = $true }
        $conn.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
        try { $conn.Bind(); return $true }
        catch { Write-LdapDebug "negotiate bind failed for '$Username': $($_.Exception.Message)" }
        finally { $conn.Dispose() }

        # Attempt 2 (LDAPS only) - simple/Basic bind with the raw username; reliable for UPN or full DN.
        if ($ssl) {
            $cred2 = New-Object System.Net.NetworkCredential($Username, $Password)
            $id2   = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier($server, $port)
            $conn2 = New-Object System.DirectoryServices.Protocols.LdapConnection($id2, $cred2)
            $conn2.SessionOptions.ProtocolVersion = 3
            $conn2.SessionOptions.SecureSocketLayer = $true
            $conn2.AuthType = [System.DirectoryServices.Protocols.AuthType]::Basic
            try { $conn2.Bind(); return $true }
            catch { Write-LdapDebug "simple bind failed for '$Username': $($_.Exception.Message)" }
            finally { $conn2.Dispose() }
        }
        return $false
    } catch {
        Write-LdapDebug "Test-LdapCredential threw for '$Username': $($_.Exception.ToString())"
        return $false
    }
}

# Resolve role from AD group membership against config.roleMap (admin wins over helpdesk).
function Resolve-LdapRole([string]$Username) {
    try {
        $cfg = Get-Store config
        $server = if ($cfg.ldapServer) { $cfg.ldapServer } else { 'RootDSE' }
        $rootDse = [ADSI]"LDAP://$server/RootDSE"
        $domainDN = $rootDse.defaultNamingContext.Value
        $sam = ($Username -split '\\')[-1] -replace '@.*$',''
        $ds = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$server/$domainDN")
        $ds.Filter = "(&(objectCategory=person)(sAMAccountName=$(ConvertTo-LdapFilterValue $sam)))"
        [void]$ds.PropertiesToLoad.Add('memberOf')
        $u = $ds.FindOne()
        if (-not $u) { Write-LdapDebug "Resolve-LdapRole: no user found for sam '$sam'"; return $null }
        $groups = @($u.Properties['memberof'] | ForEach-Object { ($_ -split ',')[0] -replace '^CN=','' })
        if (@($cfg.roleMap.admin)    | Where-Object { $groups -contains $_ }) { return 'admin' }
        if (@($cfg.roleMap.helpdesk) | Where-Object { $groups -contains $_ }) { return 'helpdesk' }
        Write-LdapDebug "Resolve-LdapRole: '$sam' matched no role group (member of: $($groups -join ', '))"
        return $null
    } catch {
        Write-LdapDebug "Resolve-LdapRole threw for '$Username': $($_.Exception.ToString())"
        return $null
    }
}

# Single entry point. Tries local app users first, then LDAP if enabled.
function Invoke-Authenticate([string]$Username, [string]$Password) {
    # Reject blank username/password up front. CRITICAL: an empty password on an LDAP *simple* bind is
    # treated by Active Directory as an anonymous/unauthenticated bind that returns SUCCESS - which would be
    # an auth bypass (valid username + empty password -> role resolved -> admin session). Never bind without one.
    if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) { return @{ ok=$false } }
    $users = @(Get-Store users)
    $local = $users | Where-Object { $_.username -eq $Username -and $_.type -eq 'local' }
    if ($local) {
        if (Test-PasswordHash $Password $local.hash) { return @{ ok=$true; username=$Username; role=$local.role; type='local' } }
        return @{ ok=$false }
    }
    $cfg = Get-Store config
    if ($cfg.ldapEnabled) {
        if (Test-LdapCredential $Username $Password) {
            $role = Resolve-LdapRole $Username
            if ($role) { return @{ ok=$true; username=$Username; role=$role; type='ldap' } }
            return @{ ok=$false; reason='authenticated-but-no-role' }
        }
    }
    @{ ok=$false }
}

# The set of features an admin can grant/revoke for the helpdesk role (rendered as checkboxes in Config).
# configure, view-history (Audit), and upload are deliberately NOT here - they are permanently admin-only.
# Onboarding rides on 'create-user'. Order is the display order on the Config page.
function Get-HelpdeskFeatureCatalog {
    @(
        [pscustomobject]@{ action = 'operations-view';   label = 'Operations Dashboard' }
        [pscustomobject]@{ action = 'run';               label = 'Run Scripts' }
        [pscustomobject]@{ action = 'create-user';       label = 'Create User / Onboarding' }
        [pscustomobject]@{ action = 'decommission-user'; label = 'Decommission User' }
        [pscustomobject]@{ action = 'manage-reports';    label = 'Scheduled Reports' }
        [pscustomobject]@{ action = 'inventory';         label = 'Computer Inventory' }
        [pscustomobject]@{ action = 'veeam-reports';     label = 'Veeam Reports' }
        [pscustomobject]@{ action = 'unifi';             label = 'UniFi Network Scripts' }
        [pscustomobject]@{ action = 'hyperv-view';       label = 'Hyper-V (view)' }
        # Deliberately separate from hyperv-view so read-only visibility can be granted without it.
        # Note this toggle is NOT the only gate: a migration runs as the OPERATOR'S OWN credentials, so
        # granting this to someone without cluster rights still fails at authentication - it moves no VM.
        # It also does nothing at all unless "migrationEnabled": true in data\hyperv.config.json.
        [pscustomobject]@{ action = 'hyperv-migrate';    label = 'Hyper-V VM migration' }
        # Read is 'hyperv-view'; this is the WRITE that deletes a checkpoint (Remove-VMSnapshot). Separate
        # from migration so checkpoint cleanup and VM migration can be delegated independently. Like all
        # write actions it runs as the operator's OWN credentials, so granting it to someone without
        # Hyper-V rights still fails at authentication.
        [pscustomobject]@{ action = 'hyperv-checkpoint-remove'; label = 'Hyper-V checkpoint removal' }
    )
}
# Legacy default when config has no explicit helpdeskFeatures list (fresh/upgraded installs) - preserves
# the historical helpdesk grant so an upgrade never silently changes access.
$script:HelpdeskDefaultFeatures = @('run', 'create-user', 'decommission-user', 'manage-reports')

# The helpdesk-enabled features from config, clamped to the toggleable catalog. Absent config -> default.
function Get-HelpdeskFeatures {
    $valid = @(Get-HelpdeskFeatureCatalog | ForEach-Object { $_.action })
    $cfg = Get-Store config
    $set = $null
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'helpdeskFeatures')) { $set = $cfg.helpdeskFeatures }
    if ($null -eq $set) { $set = $script:HelpdeskDefaultFeatures }
    @(@($set) | Where-Object { $_ -in $valid })
}

function Test-Authorized([string]$Role, [string]$Action) {
    # actions: run, view-history, upload, configure, create-user, decommission-user, manage-reports,
    #          veeam-reports, inventory, unifi, hyperv-view, hyperv-migrate, hyperv-checkpoint-remove.
    #          Admin allows all. Helpdesk is
    #          CONFIG-DRIVEN via the toggleable catalog above (Config > Helpdesk feature access);
    #          configure/view-history/upload never apply.
    switch ($Role) {
        'admin'    { return $true }
        'helpdesk' {
            if ($Action -in @('configure', 'view-history', 'upload')) { return $false }
            return ($Action -in (Get-HelpdeskFeatures))
        }
        default    { return $false }
    }
}
