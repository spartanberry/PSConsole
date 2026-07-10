<#
.SYNOPSIS  Computer objects with no logon in N days (default 90).
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
        LastLogon     = $last
        DaysStale     = if ($last) { [math]::Round(((Get-Date) - $last).TotalDays,0) } else { 'never' }
        DN            = "$($p.distinguishedname)"
    }
} | Sort-Object LastLogon
