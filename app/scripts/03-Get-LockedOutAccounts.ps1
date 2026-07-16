<#
.SYNOPSIS  Currently locked-out user accounts.
.RUNEXAMPLE  (no parameters)
.CATEGORY  Active Directory
.NOTES     Pure ADSI. Filters lockoutTime>=1 then validates against domain lockoutDuration. Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param()
$rootDse = [ADSI]"LDAP://RootDSE"
$domainDN = $rootDse.defaultNamingContext.Value
$domain = [ADSI]"LDAP://$domainDN"
$lockoutDurTicks = [Math]::Abs([int64]($domain.ConvertLargeIntegerToInt64($domain.lockoutDuration.Value)))
$now = Get-Date

# Emit a preformatted local string: WinPS 5.1 ConvertTo-Json renders a raw DateTime as
# "/Date(1333728371000)/", which is what would reach the table, CSV export and emailed reports.
function Format-Stamp { param($Value) if ($Value) { ([datetime]$Value).ToString('MM/dd/yyyy h:mm tt') } else { '' } }

$ds = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$domainDN")
$ds.Filter = "(&(objectCategory=person)(objectClass=user)(lockoutTime>=1))"
$ds.PageSize = 1000
@('sAMAccountName','displayName','lockoutTime') | ForEach-Object { [void]$ds.PropertiesToLoad.Add($_) }
$ds.FindAll() | ForEach-Object {
    $p = $_.Properties
    $lt = [int64]"$($p.lockouttime)"
    if ($lt -le 0) { return }
    $lockedAt = [DateTime]::FromFileTimeUtc($lt).ToLocalTime()
    # if lockoutDuration is set, account auto-unlocks after it elapses
    $stillLocked = if ($lockoutDurTicks -gt 0) { ($now - $lockedAt).Ticks -lt $lockoutDurTicks } else { $true }
    if ($stillLocked) {
        [PSCustomObject]@{
            SamAccountName = "$($p.samaccountname)"
            DisplayName    = "$($p.displayname)"
            LockedOutAt    = $lockedAt
        }
    }
# Sort on the real DateTime FIRST, then project the formatted string. Formatting before the sort
# would order lexicographically (by month), silently scrambling "most recently locked out first".
} | Sort-Object LockedOutAt -Descending |
    Select-Object SamAccountName, DisplayName, @{ Name = 'LockedOutAt'; Expression = { Format-Stamp $_.LockedOutAt } }
