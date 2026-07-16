<#
.SYNOPSIS  Enabled accounts with risky password settings (never expires / not required / reversible encryption).
.RUNEXAMPLE  (no parameters)
.CATEGORY  AD Hygiene
.NOTES     Pure ADSI. Read-only - reads userAccountControl FLAGS only, never password data.
           Service accounts legitimately carry PasswordNeverExpires; treat this as a review list,
           not a defect list. ReversibleEncryption and PasswordNotRequired are almost never OK.
.ROLE      Admin
#>
[CmdletBinding()]
param(
    [string]$SearchBase  # optional DN. Blank = whole domain.
)
$root = if ($SearchBase) { [ADSI]"LDAP://$SearchBase" } else { [ADSI]"LDAP://RootDSE" | ForEach-Object { [ADSI]"LDAP://$($_.defaultNamingContext)" } }

# Preformat as local strings: WinPS 5.1 ConvertTo-Json renders a raw DateTime as
# "/Date(1333728371000)/", which is what would reach the table, CSV export and emailed reports.
function Format-Stamp { param($Value) if ($Value) { ([datetime]$Value).ToString('MM/dd/yyyy h:mm tt') } else { '' } }

# UAC bits: 32 = PASSWD_NOTREQD, 128 = ENCRYPTED_TEXT_PWD_ALLOWED, 65536 = DONT_EXPIRE_PASSWD.
# Bit 2 (ACCOUNTDISABLE) is negated so this reports only accounts that can actually be used.
$ds = New-Object System.DirectoryServices.DirectorySearcher($root)
$ds.Filter = "(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(|(userAccountControl:1.2.840.113556.1.4.803:=65536)(userAccountControl:1.2.840.113556.1.4.803:=32)(userAccountControl:1.2.840.113556.1.4.803:=128)))"
$ds.PageSize = 1000
@('sAMAccountName','displayName','mail','userAccountControl','pwdLastSet','lastLogonTimestamp','distinguishedName') | ForEach-Object { [void]$ds.PropertiesToLoad.Add($_) }

$now = Get-Date
$ds.FindAll() | ForEach-Object {
    $p = $_.Properties
    $uac = [int]"$($p.useraccountcontrol)"
    $flags = New-Object System.Collections.Generic.List[string]
    if ($uac -band 65536) { $flags.Add('PasswordNeverExpires') }
    if ($uac -band 32)    { $flags.Add('PasswordNotRequired') }
    if ($uac -band 128)   { $flags.Add('ReversibleEncryption') }

    $pls = [int64]"$($p.pwdlastset)"
    $pwdSet = if ($pls -gt 0) { [DateTime]::FromFileTimeUtc($pls).ToLocalTime() } else { $null }
    $llt = [int64]"$($p.lastlogontimestamp)"
    $last = if ($llt -gt 0) { [DateTime]::FromFileTimeUtc($llt).ToLocalTime() } else { $null }

    [PSCustomObject]@{
        SamAccountName  = "$($p.samaccountname)"
        DisplayName     = "$($p.displayname)"
        Flags           = ($flags -join ', ')
        PasswordLastSet = Format-Stamp $pwdSet
        # 'future' = pwdLastSet is dated ahead of this host's clock (DC skew), not a brand-new password.
        PasswordAgeDays = if (-not $pwdSet) { 'never set' } elseif ($pwdSet -gt $now) { 'future' } else { [math]::Round(($now - $pwdSet).TotalDays, 0) }
        LastLogon       = Format-Stamp $last
        DN              = "$($p.distinguishedname)"
    }
} | Sort-Object @{ Expression = { if ($_.PasswordAgeDays -in @('never set','future')) { [double]::MaxValue } else { [double]$_.PasswordAgeDays } } } -Descending
