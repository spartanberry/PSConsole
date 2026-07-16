<#
.SYNOPSIS  Computer objects with no logon in N days (default 90).
.RUNEXAMPLE  Days=90
.CATEGORY  Active Directory
.NOTES     Pure ADSI. Uses lastLogonTimestamp (replicated). Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param(
    [int]$Days = 90
)
$rootDse = [ADSI]"LDAP://RootDSE"
$domainDN = $rootDse.defaultNamingContext.Value
$cutoff = (Get-Date).AddDays(-$Days)
$cutoffFileTime = $cutoff.ToFileTimeUtc()

# Emit a preformatted local string: WinPS 5.1 ConvertTo-Json renders a raw DateTime as
# "/Date(1333728371000)/", which is what would reach the table, CSV export and emailed reports.
function Format-Stamp { param($Value) if ($Value) { ([datetime]$Value).ToString('MM/dd/yyyy h:mm tt') } else { '' } }

$ds = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$domainDN")
$ds.Filter = "(&(objectCategory=computer)(lastLogonTimestamp<=$cutoffFileTime))"
$ds.PageSize = 1000
@('name','dNSHostName','lastLogonTimestamp','operatingSystem','distinguishedName') | ForEach-Object { [void]$ds.PropertiesToLoad.Add($_) }
$ds.FindAll() | ForEach-Object {
    $p = $_.Properties
    $llt = [int64]"$($p.lastlogontimestamp)"
    $last = if ($llt -gt 0) { [DateTime]::FromFileTimeUtc($llt).ToLocalTime() } else { $null }
    [PSCustomObject]@{
        Name          = "$($p.name)"
        DNSHostName   = "$($p.dnshostname)"
        OS            = "$($p.operatingsystem)"
        LastLogon     = Format-Stamp $last
        DaysStale     = if ($last) { [math]::Round(((Get-Date) - $last).TotalDays,0) } else { 'never' }
        DN            = "$($p.distinguishedname)"
    }
# LastLogon is now a formatted string, so sorting on it would order lexicographically (by month).
# Sort on DaysStale instead - descending with never-logged-on pinned first reproduces the previous
# "Sort-Object LastLogon" order exactly (nulls first, then oldest logon first).
} | Sort-Object @{ Expression = { if ($_.DaysStale -eq 'never') { [double]::MaxValue } else { [double]$_.DaysStale } } } -Descending
