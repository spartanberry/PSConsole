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

function Test-Authorized([string]$Role, [string]$Action) {
    # actions: run, view-history, upload, configure, create-user, decommission-user, onboarding-run,
    #          manage-reports, veeam-reports, inventory (all but the helpdesk list below are admin-only
    #          via default-deny; 'inventory' stays admin-only until the swap feature is verified)
    switch ($Role) {
        'admin'    { return $true }
        # Helpdesk: run scripts, create + onboard + decommission users, manage their OWN scheduled reports,
        # and the overview dashboard. Deliberately NO 'view-history' (Audit) and NO 'configure' (Config).
        'helpdesk' { return ($Action -in @('run','create-user','decommission-user','manage-reports')) }
        default    { return $false }
    }
}
