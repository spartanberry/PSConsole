<#
.SYNOPSIS  Disabled accounts that are still members of groups - leftover access to clean up.
.RUNEXAMPLE  (no parameters)
.CATEGORY  AD Hygiene
.NOTES     Pure ADSI. Read-only.
           A disabled account cannot authenticate, so this is cleanup hygiene rather than an active
           breach: the risk is that re-enabling the account silently restores every listed group.
           Primary group (usually Domain Users) is not stored in memberOf and so is not counted.
           Well-known accounts (RID < 1000, i.e. Guest and krbtgt) are excluded - they are disabled
           and group-joined by design and would never clear, drowning out real findings.
.ROLE      Admin
#>
[CmdletBinding()]
param(
    [string]$SearchBase  # optional DN. Blank = whole domain.
)
$root = if ($SearchBase) { [ADSI]"LDAP://$SearchBase" } else { [ADSI]"LDAP://RootDSE" | ForEach-Object { [ADSI]"LDAP://$($_.defaultNamingContext)" } }

# AD hands back whenChanged as UTC but tagged Kind=Unspecified - stamp it before converting, so it
# does not silently disagree with LastLogon (a FileTime, which converts to local).
function ConvertFrom-AdUtc { param($Value) if (-not $Value) { return $null }; [datetime]::SpecifyKind([datetime]$Value, [DateTimeKind]::Utc).ToLocalTime() }
# Preformat: WinPS 5.1 ConvertTo-Json renders a raw DateTime as "/Date(1333728371000)/" in the UI.
function Format-Stamp { param($Value) if ($Value) { ([datetime]$Value).ToString('MM/dd/yyyy h:mm tt') } else { '' } }

$ds = New-Object System.DirectoryServices.DirectorySearcher($root)
# UAC bit 2 = ACCOUNTDISABLE, and at least one memberOf value.
$ds.Filter = "(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=2)(memberOf=*))"
$ds.PageSize = 1000
@('sAMAccountName','displayName','memberOf','whenChanged','lastLogonTimestamp','objectSid','distinguishedName') | ForEach-Object { [void]$ds.PropertiesToLoad.Add($_) }

$ds.FindAll() | ForEach-Object {
    $p = $_.Properties
    $sid = if ($p.objectsid) { New-Object System.Security.Principal.SecurityIdentifier(([byte[]]$p.objectsid[0]), 0) } else { $null }
    if ($sid -and [int]($sid.Value -split '-')[-1] -lt 1000) { return }
    # memberOf holds full DNs; show just the group CN for readability.
    $groups = @($p.memberof) | ForEach-Object {
        if ("$_" -match '^CN=(?<cn>(?:[^,\\]|\\.)+),') { $Matches['cn'] -replace '\\(.)', '$1' } else { "$_" }
    } | Sort-Object
    $llt = [int64]"$($p.lastlogontimestamp)"
    $last = if ($llt -gt 0) { [DateTime]::FromFileTimeUtc($llt).ToLocalTime() } else { $null }
    $changed = if ($p.whenchanged) { ConvertFrom-AdUtc $p.whenchanged[0] } else { $null }
    [PSCustomObject]@{
        SamAccountName = "$($p.samaccountname)"
        DisplayName    = "$($p.displayname)"
        GroupCount     = @($groups).Count
        Groups         = ($groups -join ', ')
        LastLogon      = Format-Stamp $last
        LastModified   = Format-Stamp $changed
        DN             = "$($p.distinguishedname)"
    }
} | Sort-Object GroupCount -Descending
