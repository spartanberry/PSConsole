# Decommission.ps1 - on-prem AD user offboarding.
#
# SECURITY MODEL (same as Phase-1 creation):
#  - The lookup/preview runs as the read-only service account (directory READ only).
#  - The WRITE (disable + strip on-prem groups + move to the Disabled Accounts OU) binds to AD with
#    the OPERATOR's OWN credentials, entered per request - never the service account, never stored.
#  - Gated by the provisioning 'enabled' master switch: while off, the run route is preview-only.
#
# Cloud cleanup is intentionally NOT done here: moving the object to the Disabled Accounts OU takes it
# out of the Entra Connect sync scope, so ADSync removes it from Entra (and thus all cloud groups) on
# its next cycle. Only on-prem group memberships are stripped here.

# Escape a value for safe use inside an LDAP search filter (RFC 4515).
function ConvertTo-LdapFilterValue([string]$v) {
    if ($null -eq $v) { return '' }
    $v -replace '\\','\5c' -replace '\(','\28' -replace '\)','\29' -replace '\*','\2a' -replace "`0",'\00'
}

# Look up a single AD user by sAMAccountName / UPN / displayName (read-only). Returns a plan object.
function Find-AdUserForDecomm {
    param([string]$Identity)
    $result = [pscustomobject]@{
        found=$false; identity=$Identity; sam=''; upn=''; displayName=''; dn=''; ou='';
        enabled=$null; onPremGroups=@(); inDisabledOu=$false; error=''
    }
    $Identity = ([string]$Identity).Trim()
    if (-not $Identity) { $result.error = 'Enter a username to look up.'; return $result }
    try {
        $cfg    = Get-Store config
        $server = if ($cfg.ldapServer) { $cfg.ldapServer } else { $env:USERDNSDOMAIN }
        $domainDN = ([ADSI]"LDAP://$server/RootDSE").defaultNamingContext.Value
        $sam = ($Identity -split '\\')[-1] -replace '@.*$',''
        $samF = ConvertTo-LdapFilterValue $sam
        $idF  = ConvertTo-LdapFilterValue $Identity
        $ds = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$server/$domainDN")
        $ds.Filter = "(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=$samF)(userPrincipalName=$idF)(displayName=$idF)))"
        foreach ($p in 'sAMAccountName','userPrincipalName','displayName','distinguishedName','userAccountControl','memberOf') { [void]$ds.PropertiesToLoad.Add($p) }
        $hits = @($ds.FindAll())
        if ($hits.Count -eq 0) { $result.error = "No AD user found matching '$Identity'."; return $result }
        if ($hits.Count -gt 1) { $result.error = "'$Identity' matches $($hits.Count) accounts - enter the exact sAMAccountName."; return $result }
        $e   = $hits[0].Properties
        $dn  = [string]$e['distinguishedname'][0]
        $uac = if ($e['useraccountcontrol'].Count) { [int]$e['useraccountcontrol'][0] } else { 0 }
        $disabledOu = (Get-ProvisionSettings).disabledOu
        $result.found        = $true
        $result.sam          = [string]$e['samaccountname'][0]
        $result.upn          = [string]$e['userprincipalname'][0]
        $result.displayName  = [string]$e['displayname'][0]
        $result.dn           = $dn
        $result.ou           = ($dn -replace '^CN=[^,]+,','')          # parent OU of the object
        $result.enabled      = -not [bool]($uac -band 0x2)             # 0x2 = ACCOUNTDISABLE
        $result.onPremGroups = @($e['memberof'] | ForEach-Object { [string]$_ })   # group DNs
        $result.inDisabledOu = ($dn -match ([regex]::Escape($disabledOu) + '$'))
        return $result
    } catch { $result.error = $_.Exception.Message; return $result }
}

# Validate a decommission plan. Blocks: not found, already in Disabled OU, or a protected/admin account.
function Test-DecommPlan([pscustomobject]$Plan) {
    $errs = New-Object System.Collections.Generic.List[string]
    if (-not $Plan.found) { if ($Plan.error) { $errs.Add($Plan.error) } else { $errs.Add('User not found.') }; return $errs }
    if ($Plan.inDisabledOu) { $errs.Add("$($Plan.sam) is already in the Disabled Accounts OU - nothing to do.") }
    $protected = @('Domain Admins','Enterprise Admins','Schema Admins','Administrators','Account Operators','Server Operators','Backup Operators','Domain Controllers')
    $cns = @($Plan.onPremGroups | ForEach-Object { (($_ -split ',')[0] -replace '^CN=','') })
    $hit = @($cns | Where-Object { $protected -contains $_ })
    if ($hit.Count) { $errs.Add("$($Plan.sam) is a member of a protected/administrative group ($($hit -join ', ')) - refusing to decommission from the web tool. If this is truly intended, do it manually.") }
    return $errs
}

# Perform the decommission, binding as the operator: disable, note description, strip on-prem group
# memberships, then move to the Disabled Accounts OU. Group removal is best-effort and per-group.
function Invoke-Decommission {
    param([pscustomobject]$Plan,[string]$OperatorUser,[string]$OperatorPassword)
    $cfg        = Get-Store config
    $server     = if ($cfg.ldapServer) { $cfg.ldapServer } else { $env:USERDNSDOMAIN }
    $disabledOu = (Get-ProvisionSettings).disabledOu
    $removed = @(); $failedGroups = @()
    try {
        $user = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$server/$($Plan.dn)", $OperatorUser, $OperatorPassword)
        [void]$user.NativeObject   # force a bind now so bad creds / bad DN fail clearly here

        # 1) disable the account (preserve other UAC flags) + stamp a description
        $uac = [int]$user.Properties['userAccountControl'].Value
        $user.Properties['userAccountControl'].Value = ($uac -bor 0x2)   # set ACCOUNTDISABLE
        $user.Properties['description'].Value = ("Decommissioned {0} by {1} via PSConsole" -f (Get-Date).ToString('yyyy-MM-dd'), $OperatorUser)
        $user.CommitChanges()

        # 2) remove from on-prem groups (the primary group isn't in memberOf, so it's left alone)
        foreach ($gdn in @($Plan.onPremGroups)) {
            $cn = (($gdn -split ',')[0] -replace '^CN=','')
            try {
                $grp = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$server/$gdn", $OperatorUser, $OperatorPassword)
                $grp.Invoke('Remove', @("LDAP://$server/$($Plan.dn)"))
                $grp.CommitChanges()
                $removed += $cn
            } catch { $failedGroups += ("$cn ($(($_.Exception.Message) -replace '\s+',' '))") }
        }

        # 3) move the (now disabled) object into the Disabled Accounts OU -> leaves the sync scope
        $target = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$server/$disabledOu", $OperatorUser, $OperatorPassword)
        [void]$target.NativeObject
        $user.MoveTo($target)
        $user.CommitChanges()
        $newDn = [string]$user.Properties['distinguishedName'].Value

        return @{ ok=$true; dn=$newDn; disabled=$true; groupsRemoved=$removed; groupsFailed=$failedGroups }
    } catch {
        return @{ ok=$false; error=$_.Exception.Message; groupsRemoved=$removed; groupsFailed=$failedGroups }
    }
}
