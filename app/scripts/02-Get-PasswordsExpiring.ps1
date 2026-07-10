<#
.SYNOPSIS  Users whose passwords expire within N days (default 14).
.CATEGORY  Active Directory
.NOTES     Pure ADSI. Honors domain maxPwdAge. Skips never-expire & disabled. Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param(
    [int]$Days = 14
)
$rootDse = [ADSI]"LDAP://RootDSE"
$domainDN = $rootDse.defaultNamingContext.Value
$domain = [ADSI]"LDAP://$domainDN"
$maxPwdAgeTicks = [Math]::Abs([int64]($domain.ConvertLargeIntegerToInt64($domain.maxPwdAge.Value)))
if ($maxPwdAgeTicks -eq 0) { Write-Warning "Domain max password age is 0 (passwords never expire)."; return }
$maxPwdAgeDays = [TimeSpan]::FromTicks($maxPwdAgeTicks).TotalDays
$now = Get-Date

$ds = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$domainDN")
# enabled users, with a real pwdLastSet, NOT flagged DONT_EXPIRE_PASSWD (bit 65536)
$ds.Filter = "(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(!(userAccountControl:1.2.840.113556.1.4.803:=65536))(pwdLastSet>=1))"
$ds.PageSize = 1000
@('sAMAccountName','displayName','mail','pwdLastSet') | ForEach-Object { [void]$ds.PropertiesToLoad.Add($_) }
$ds.FindAll() | ForEach-Object {
    $p = $_.Properties
    $pls = [int64]"$($p.pwdlastset)"
    if ($pls -le 0) { return }
    $lastSet = [DateTime]::FromFileTimeUtc($pls).ToLocalTime()
    $expires = $lastSet.AddDays($maxPwdAgeDays)
    $daysLeft = [math]::Round(($expires - $now).TotalDays, 1)
    if ($daysLeft -le $Days) {
        [PSCustomObject]@{
            SamAccountName = "$($p.samaccountname)"
            DisplayName    = "$($p.displayname)"
            Email          = "$($p.mail)"
            PasswordSet    = $lastSet
            Expires        = $expires
            DaysLeft       = $daysLeft
        }
    }
} | Where-Object { $_.DaysLeft -ge 0 -or $true } | Sort-Object DaysLeft
