<#
.SYNOPSIS  Enabled user accounts with no logon in N days (default 90), including never-logged-on.
.RUNEXAMPLE  Days=90
.CATEGORY  AD Hygiene
.NOTES     Pure ADSI. Uses lastLogonTimestamp, which AD only replicates every ~9-14 days, so
           DaysStale can overstate staleness by up to two weeks. Fine for cleanup triage; do not
           treat it as a precise last-logon. Read-only.
.ROLE      HelpDesk
#>
[CmdletBinding()]
param(
    [int]$Days = 90,
    [string]$SearchBase  # optional DN. Blank = whole domain.
)
$root = if ($SearchBase) { [ADSI]"LDAP://$SearchBase" } else { [ADSI]"LDAP://RootDSE" | ForEach-Object { [ADSI]"LDAP://$($_.defaultNamingContext)" } }
$cutoffFileTime = (Get-Date).AddDays(-$Days).ToFileTimeUtc()

# AD hands back whenCreated/whenChanged as UTC but tagged Kind=Unspecified, so converting without
# stamping them UTC first leaves them hours off - and silently disagreeing with the FileTime columns
# (lastLogonTimestamp), which DO convert to local. Both go through these so one table = one timezone.
function ConvertFrom-AdUtc { param($Value) if (-not $Value) { return $null }; [datetime]::SpecifyKind([datetime]$Value, [DateTimeKind]::Utc).ToLocalTime() }
# Emit dates as preformatted local strings: WinPS 5.1 ConvertTo-Json renders a DateTime as
# "/Date(1333728371000)/", which is what reaches the results table, CSV export and emailed reports.
function Format-Stamp { param($Value) if ($Value) { ([datetime]$Value).ToString('MM/dd/yyyy h:mm tt') } else { '' } }

$ds = New-Object System.DirectoryServices.DirectorySearcher($root)
# Enabled users (NOT UAC bit 2) that are either stale OR have never logged on (no lastLogonTimestamp).
$ds.Filter = "(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(|(lastLogonTimestamp<=$cutoffFileTime)(!(lastLogonTimestamp=*))))"
$ds.PageSize = 1000
@('sAMAccountName','displayName','mail','lastLogonTimestamp','whenCreated','department','distinguishedName') | ForEach-Object { [void]$ds.PropertiesToLoad.Add($_) }

$now = Get-Date
$ds.FindAll() | ForEach-Object {
    $p = $_.Properties
    $llt = [int64]"$($p.lastlogontimestamp)"
    $last = if ($llt -gt 0) { [DateTime]::FromFileTimeUtc($llt).ToLocalTime() } else { $null }
    $created = if ($p.whencreated) { ConvertFrom-AdUtc $p.whencreated[0] } else { $null }
    [PSCustomObject]@{
        SamAccountName = "$($p.samaccountname)"
        DisplayName    = "$($p.displayname)"
        Email          = "$($p.mail)"
        Department     = "$($p.department)"
        LastLogon      = Format-Stamp $last
        DaysStale      = if ($last) { [math]::Round(($now - $last).TotalDays, 0) } else { 'never' }
        Created        = Format-Stamp $created
        DN             = "$($p.distinguishedname)"
    }
} | Sort-Object @{ Expression = { if ($_.DaysStale -eq 'never') { [double]::MaxValue } else { [double]$_.DaysStale } } } -Descending
