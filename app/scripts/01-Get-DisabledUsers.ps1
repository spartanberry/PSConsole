<#
.SYNOPSIS  List all disabled user accounts in Active Directory.
.NOTES     Pure ADSI. No RSAT/ActiveDirectory module required. Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param(
    [string]$SearchBase  # optional DN, e.g. "OU=Staff,DC=example,DC=org". Blank = whole domain.
)
$root = if ($SearchBase) { [ADSI]"LDAP://$SearchBase" } else { [ADSI]"LDAP://RootDSE" | ForEach-Object { [ADSI]"LDAP://$($_.defaultNamingContext)" } }
$ds = New-Object System.DirectoryServices.DirectorySearcher($root)
# UAC bit 2 = ACCOUNTDISABLE
$ds.Filter = "(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=2))"
$ds.PageSize = 1000
@('sAMAccountName','displayName','mail','whenChanged','distinguishedName') | ForEach-Object { [void]$ds.PropertiesToLoad.Add($_) }
$ds.FindAll() | ForEach-Object {
    $p = $_.Properties
    [PSCustomObject]@{
        SamAccountName = "$($p.samaccountname)"
        DisplayName    = "$($p.displayname)"
        Email          = "$($p.mail)"
        LastModified   = "$($p.whenchanged)"
        DN             = "$($p.distinguishedname)"
    }
} | Sort-Object SamAccountName
