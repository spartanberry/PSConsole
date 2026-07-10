<#
.SYNOPSIS  Export direct members of an AD group.
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
$ds.Filter = "(&(objectCategory=group)(sAMAccountName=$GroupName))"
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
