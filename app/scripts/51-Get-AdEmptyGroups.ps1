<#
.SYNOPSIS  Groups with no members - candidates for cleanup.
.RUNEXAMPLE  (no parameters)
.CATEGORY  AD Hygiene
.NOTES     Pure ADSI. Read-only.
           Well-known groups (RID < 1000) are excluded, for two reasons: AD does not list a user's
           PRIMARY group in that group's `member` attribute, so Domain Users/Guests/Computers look
           empty when they are not; and an empty built-in like Account Operators is the DESIRED
           state, not a cleanup item. Everything reported here is a domain-created group (RID 1000+).
           A group backed by a custom primary-group assignment could still be a false positive -
           verify before deleting.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param(
    [string]$SearchBase  # optional DN. Blank = whole domain.
)
$root = if ($SearchBase) { [ADSI]"LDAP://$SearchBase" } else { [ADSI]"LDAP://RootDSE" | ForEach-Object { [ADSI]"LDAP://$($_.defaultNamingContext)" } }

# AD hands back whenCreated as UTC but tagged Kind=Unspecified - stamp it before converting to local.
function ConvertFrom-AdUtc { param($Value) if (-not $Value) { return $null }; [datetime]::SpecifyKind([datetime]$Value, [DateTimeKind]::Utc).ToLocalTime() }
# Preformat: WinPS 5.1 ConvertTo-Json renders a raw DateTime as "/Date(1333728371000)/" in the UI.
function Format-Stamp { param($Value) if ($Value) { ([datetime]$Value).ToString('MM/dd/yyyy h:mm tt') } else { '' } }

$ds = New-Object System.DirectoryServices.DirectorySearcher($root)
$ds.Filter = "(&(objectCategory=group)(!(member=*)))"
$ds.PageSize = 1000
@('sAMAccountName','name','description','groupType','objectSid','whenCreated','distinguishedName') | ForEach-Object { [void]$ds.PropertiesToLoad.Add($_) }

# groupType is a bitmask: 0x80000000 = security (else distribution); low bits = scope.
$ds.FindAll() | ForEach-Object {
    $p = $_.Properties
    $sid = if ($p.objectsid) { New-Object System.Security.Principal.SecurityIdentifier(([byte[]]$p.objectsid[0]), 0) } else { $null }
    $rid = if ($sid) { [int]($sid.Value -split '-')[-1] } else { 0 }
    if ($rid -lt 1000) { return }
    $gt = [int]"$($p.grouptype)"
    $scope = switch ($gt -band 0x0000000E) { 2 { 'Global' } 4 { 'DomainLocal' } 8 { 'Universal' } default { 'Unknown' } }
    $created = if ($p.whencreated) { ConvertFrom-AdUtc $p.whencreated[0] } else { $null }
    [PSCustomObject]@{
        Name        = "$($p.name)"
        SamAccountName = "$($p.samaccountname)"
        Type        = if ($gt -band 0x80000000) { 'Security' } else { 'Distribution' }
        Scope       = $scope
        Description = "$($p.description)"
        Created     = Format-Stamp $created
        DN          = "$($p.distinguishedname)"
    }
} | Sort-Object Name
