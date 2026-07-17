<#
.SYNOPSIS Duplicate devices in Defender - same machine registered under more than one MDE record.
.DESCRIPTION Groups /api/machines by device name (case-insensitive) and lists every name that has more than
    one record, so you can spot the stale/Inactive duplicate to offboard. Duplicates usually come from
    reimaging or sensor reinstalls: same box, new machine Id. Rows are grouped by name, newest last-seen
    first, so within each name the Active record is at the top and the stale one(s) below. Also surfaces MDE's
    own signals: PotentialDup (Defender flagged it as a likely duplicate) and MergedInto (this record was
    already merged into another machine Id). -InactiveOnly keeps only duplicate sets that contain at least one
    Inactive record - i.e. the genuine reimage/reinstall stragglers - hiding all-Active shared-name devices
    (kiosk tablets/phones reusing a display name), which are usually not true duplicates. -LikelyReimage is
    tighter still: only sets with exactly ONE Active record and one or more Inactive - the signature of a box
    that was reimaged/re-enrolled (one live record, the rest stale). This drops generic/model-name collisions
    where many records are Active at once (e.g. dozens of VoIP phones all named the same model).
.CATEGORY Defender
.ROLE Admin
.RUNEXAMPLE -LikelyReimage
#>
[CmdletBinding()]
param([switch]$InactiveOnly,[switch]$LikelyReimage)

. (Join-Path $PSScriptRoot '..\lib\Graph.ps1')
. (Join-Path $PSScriptRoot '..\lib\Defender.ps1')
if (-not (Test-DefenderConfigured)) { Write-Error 'Defender add-on is not configured (data\defender.config.json + the shared Graph app needs WindowsDefenderATP Machine.Read.All).'; return }

$machines = @(Invoke-Mde '/api/machines')
if (-not $machines.Count) { [pscustomobject]@{ Name='(no devices returned)'; InSet=''; Health=''; Onboarding=''; LastSeen=''; PotentialDup=''; MergedInto=''; MachineId='' }; return }

# Group by name; keep only names with >1 record. Blank names are excluded (can't be judged a duplicate by name).
$dupGroups = $machines |
    Where-Object { "$($_.computerDnsName)".Trim() } |
    Group-Object { "$($_.computerDnsName)".ToLower() } |
    Where-Object { $_.Count -gt 1 } |
    Sort-Object Name

# -InactiveOnly: keep only sets where at least one record is Inactive (the real stragglers).
if ($InactiveOnly) { $dupGroups = @($dupGroups | Where-Object { @($_.Group | Where-Object { "$($_.healthStatus)" -eq 'Inactive' }).Count -gt 0 }) }
# -LikelyReimage: exactly ONE Active record + >=1 Inactive - the reimage/re-enroll signature. Drops generic/
# model-name collisions (many concurrently-Active records sharing a name).
if ($LikelyReimage) {
    $dupGroups = @($dupGroups | Where-Object {
        (@($_.Group | Where-Object { "$($_.healthStatus)" -eq 'Active'   }).Count -eq 1) -and
        (@($_.Group | Where-Object { "$($_.healthStatus)" -eq 'Inactive' }).Count -ge 1)
    })
}

if (-not @($dupGroups).Count) { [pscustomobject]@{ Name="(no duplicate device names found$(if($LikelyReimage){' matching the reimage pattern'}elseif($InactiveOnly){' with an inactive record'}))"; InSet=''; Health=''; Onboarding=''; LastSeen=''; PotentialDup=''; MergedInto=''; MachineId='' }; return }

foreach ($g in $dupGroups) {
    $ordered = @($g.Group | Sort-Object @{ e = { try { [DateTimeOffset]::Parse("$($_.lastSeen)") } catch { [DateTimeOffset]::MinValue } }; Descending = $true })
    foreach ($m in $ordered) {
        [pscustomobject]@{
            Name         = [string]$m.computerDnsName
            InSet        = $g.Count
            Health       = [string]$m.healthStatus
            Onboarding   = [string]$m.onboardingStatus
            LastSeen     = Format-MdeDate $m.lastSeen
            PotentialDup = if ($m.isPotentialDuplication) { 'yes' } else { '' }
            MergedInto   = [string]$m.mergedIntoMachineId
            MachineId    = [string]$m.id
        }
    }
}
