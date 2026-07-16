<#
.SYNOPSIS  Members of AD's protected/privileged groups, flagged for disabled or stale accounts.
.RUNEXAMPLE  StaleDays=90
.CATEGORY  AD Hygiene
.NOTES     Pure ADSI. Read-only.
           Privileged groups are DISCOVERED via adminCount=1 (the AdminSDHolder-protected set:
           Domain/Enterprise/Schema Admins, Administrators, the Operators groups, etc.) rather than
           hardcoded by name, so this works on non-English domains and picks up anything the domain
           has since protected. Nested membership is resolved with LDAP_MATCHING_RULE_IN_CHAIN.
           A disabled or long-stale account in one of these groups is the finding to act on.
.ROLE      Admin
#>
[CmdletBinding()]
param(
    [int]$StaleDays = 90
)
$domainDN = ([ADSI]"LDAP://RootDSE").defaultNamingContext.Value
$root = [ADSI]"LDAP://$domainDN"

# Preformat as a local string: WinPS 5.1 ConvertTo-Json renders a raw DateTime as
# "/Date(1333728371000)/", which is what would reach the table, CSV export and emailed reports.
function Format-Stamp { param($Value) if ($Value) { ([datetime]$Value).ToString('MM/dd/yyyy h:mm tt') } else { '' } }

# Escape the LDAP filter metacharacters that may legally appear in a DN (RFC 4515).
function Protect-LdapFilterValue {
    param([string]$Value)
    $Value -replace '\\','\5c' -replace '\(','\28' -replace '\)','\29' -replace '\*','\2a'
}

$gs = New-Object System.DirectoryServices.DirectorySearcher($root)
$gs.Filter = '(&(objectCategory=group)(adminCount=1))'
$gs.PageSize = 1000
@('name','distinguishedName') | ForEach-Object { [void]$gs.PropertiesToLoad.Add($_) }
$groups = @($gs.FindAll() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Properties.name)"; DN = "$($_.Properties.distinguishedname)" } })

$now  = Get-Date
$rows = New-Object System.Collections.Generic.List[object]
foreach ($g in $groups) {
    $us = New-Object System.DirectoryServices.DirectorySearcher($root)
    $us.Filter = "(&(objectCategory=person)(objectClass=user)(memberOf:1.2.840.113556.1.4.1941:=$(Protect-LdapFilterValue $g.DN)))"
    $us.PageSize = 1000
    @('sAMAccountName','displayName','userAccountControl','lastLogonTimestamp','memberOf','distinguishedName') | ForEach-Object { [void]$us.PropertiesToLoad.Add($_) }
    foreach ($u in $us.FindAll()) {
        $p = $u.Properties
        $uac = [int]"$($p.useraccountcontrol)"
        $llt = [int64]"$($p.lastlogontimestamp)"
        $last = if ($llt -gt 0) { [DateTime]::FromFileTimeUtc($llt).ToLocalTime() } else { $null }
        $staleDaysVal = if ($last) { [math]::Round(($now - $last).TotalDays, 0) } else { $null }
        $enabled = -not ($uac -band 2)

        $note = New-Object System.Collections.Generic.List[string]
        if (-not $enabled) { $note.Add('DISABLED') }
        if ($null -eq $staleDaysVal) { $note.Add('never logged on') }
        # A negative age means lastLogonTimestamp is dated in the future - the account is not "fresh",
        # the source DC's clock is ahead. Called out rather than reported as a small DaysStale, which
        # would quietly rank the account as recently used.
        elseif ($staleDaysVal -lt 0) { $note.Add('lastLogon dated in the future - check DC clock skew') }
        elseif ($staleDaysVal -ge $StaleDays) { $note.Add("stale ${staleDaysVal}d") }

        $rows.Add([PSCustomObject]@{
            Group          = $g.Name
            SamAccountName = "$($p.samaccountname)"
            DisplayName    = "$($p.displayname)"
            Enabled        = $enabled
            Membership     = if (@($p.memberof) -contains $g.DN) { 'Direct' } else { 'Nested' }
            LastLogon      = Format-Stamp $last
            DaysStale      = if ($null -eq $staleDaysVal) { 'never' } elseif ($staleDaysVal -lt 0) { 'future' } else { $staleDaysVal }
            Review         = ($note -join ', ')
            DN             = "$($p.distinguishedname)"
        })
    }
}
# Accounts needing review first, then by group.
$rows | Sort-Object @{ Expression = { [bool]$_.Review }; Descending = $true }, Group, SamAccountName
