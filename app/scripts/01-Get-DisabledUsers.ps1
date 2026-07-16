<#
.SYNOPSIS  List all disabled user accounts in Active Directory.
.RUNEXAMPLE  (no parameters)
.CATEGORY  Active Directory
.NOTES     Pure ADSI. No RSAT/ActiveDirectory module required. Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param(
    [string]$SearchBase  # optional DN, e.g. "OU=Staff,DC=example,DC=org". Blank = whole domain.
)
$root = if ($SearchBase) { [ADSI]"LDAP://$SearchBase" } else { [ADSI]"LDAP://RootDSE" | ForEach-Object { [ADSI]"LDAP://$($_.defaultNamingContext)" } }

# AD hands back whenChanged as UTC but tagged Kind=Unspecified, so it renders hours off unless it is
# stamped UTC before converting to local.
function ConvertFrom-AdUtc { param($Value) if (-not $Value) { return $null }; [datetime]::SpecifyKind([datetime]$Value, [DateTimeKind]::Utc).ToLocalTime() }
# Emit a preformatted local string: WinPS 5.1 ConvertTo-Json renders a raw DateTime as
# "/Date(1333728371000)/", which is what would reach the table, CSV export and emailed reports.
function Format-Stamp { param($Value) if ($Value) { ([datetime]$Value).ToString('MM/dd/yyyy h:mm tt') } else { '' } }

$ds = New-Object System.DirectoryServices.DirectorySearcher($root)
# UAC bit 2 = ACCOUNTDISABLE
$ds.Filter = "(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=2))"
$ds.PageSize = 1000
@('sAMAccountName','displayName','mail','whenChanged','distinguishedName') | ForEach-Object { [void]$ds.PropertiesToLoad.Add($_) }
$ds.FindAll() | ForEach-Object {
    $p = $_.Properties
    $changed = if ($p.whenchanged) { ConvertFrom-AdUtc $p.whenchanged[0] } else { $null }
    [PSCustomObject]@{
        SamAccountName = "$($p.samaccountname)"
        DisplayName    = "$($p.displayname)"
        Email          = "$($p.mail)"
        LastModified   = Format-Stamp $changed
        DN             = "$($p.distinguishedname)"
    }
} | Sort-Object SamAccountName
