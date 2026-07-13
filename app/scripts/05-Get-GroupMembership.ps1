<#
.SYNOPSIS  Export direct members of an AD group.
.RUNEXAMPLE  GroupName=Case Managers
.CATEGORY  Active Directory
.NOTES     Pure ADSI. -GroupName is the sAMAccountName of the group (required). Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GroupName
)
$rootDse = [ADSI]"LDAP://RootDSE"
$domainDN = $rootDse.defaultNamingContext.Value
$ds = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$domainDN")
# Escape the operator-supplied group name for the LDAP filter (RFC 4515). .Replace() is a literal
# (non-regex) replace; $bs is a STRING (not char) so the Replace(string,string) overload is used, and
# the backslash is escaped first so the escapes we add aren't re-escaped.
$bs = [string][char]92
$g = $GroupName.Replace($bs, $bs + '5c').Replace('(', $bs + '28').Replace(')', $bs + '29').Replace('*', $bs + '2a')
$ds.Filter = "(&(objectCategory=group)(sAMAccountName=$g))"
[void]$ds.PropertiesToLoad.Add('distinguishedName')
$grp = $ds.FindOne()
if (-not $grp) { Write-Error "Group '$GroupName' not found."; return }
$grpDN = $grp.Properties['distinguishedname'][0]

$ms = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$domainDN")
$ms.Filter = "(&(objectCategory=user)(memberOf=$grpDN))"
$ms.PageSize = 1000
@('sAMAccountName','displayName','mail','userAccountControl') | ForEach-Object { [void]$ms.PropertiesToLoad.Add($_) }
$ms.FindAll() | ForEach-Object {
    $p = $_.Properties
    $uac = [int]"$($p.useraccountcontrol)"
    [PSCustomObject]@{
        SamAccountName = "$($p.samaccountname)"
        DisplayName    = "$($p.displayname)"
        Email          = "$($p.mail)"
        Enabled        = -not ($uac -band 2)
    }
} | Sort-Object SamAccountName
