# Onboarding.ps1 - Phase-2 processor. For each queued new user that has now synced up to Entra,
# set usageLocation, assign the license, and add the cloud-only group memberships. Then mark the
# record complete/partial. Fully idempotent and safe to re-run (group adds + license are no-ops if
# already applied), so it can be driven on a timer or by the "Run now" button.
#
# Group-name -> id resolution uses the READ-only app (Invoke-Graph); the actual writes use the
# WRITE app (GraphWrite.ps1). That keeps the write app's permissions minimal.

function Set-RecProp($rec,$name,$value) { $rec | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }

function Invoke-Onboarding {
    param([switch]$WhatIf)
    $s     = Get-ProvisionSettings
    $skuId = [string]$s.licenseSkuId
    $usage = if ($s.usageLocation) { [string]$s.usageLocation } else { 'US' }
    $queue = @(Get-Store onboarding)
    $writeReady = Test-GraphWriteConfigured
    $summary = [ordered]@{ processed=0; completed=0; waiting=0; partial=0; skipped=0; errors=@() }

    try {
    foreach ($rec in $queue) {
        if ($null -eq $rec.cloudStatus) { Set-RecProp $rec 'cloudStatus' 'pending-sync' }
        if ($rec.cloudStatus -eq 'complete') { $summary.skipped++; continue }
        $summary.processed++

        # Is the user synced to Entra yet?
        $u = $null
        try {
            $q = @(Invoke-Graph "/users?`$filter=userPrincipalName eq '$(($rec.upn) -replace "'","''")'&`$select=id,userPrincipalName,usageLocation")
            if ($q.Count) { $u = $q[0] }
        } catch {}
        if (-not $u) { Set-RecProp $rec 'note' 'waiting for Entra sync'; Set-RecProp $rec 'lastRun' (Get-Date).ToString('o'); $summary.waiting++; continue }

        if (-not $writeReady) { Set-RecProp $rec 'note' 'graph-write app not configured'; $summary.errors += "$($rec.upn): write app not configured"; continue }
        if ($WhatIf)          { Set-RecProp $rec 'note' 'ready to process (WhatIf)'; continue }

        Set-RecProp $rec 'userId' $u.id
        $added    = @($rec.groupsAdded)                              # Graph-writable groups already added
        $exoAdded = @(@($rec.groupsExo) | Select-Object -Unique)     # EXO groups already added (de-duped)
        $auto     = @()                 # dynamic groups - membership is automatic, nothing to do
        $manual   = @()                 # mail-enabled security / distribution - Graph can't write these
        $failed   = @()                 # genuine errors

        # 1) usageLocation (required before licensing)
        $ul = if ($u.usageLocation) { @{ ok=$true } } else { Set-EntraUsageLocation -UserId $u.id -UsageLocation $usage }
        # 2) license (direct assignment, e.g. M365 E5). usageLocation must be committed on Entra's side
        #    before a license can be assigned, and it can lag a few seconds behind the PATCH above, so
        #    retry the specific "invalid usage location" failure a few times before giving up. (Other
        #    errors - and success - break out immediately.)
        $lic = @{ ok=$true; note='no license configured' }
        if ($skuId) {
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                $lic = Set-EntraLicense -UserId $u.id -SkuId $skuId
                if ($lic.ok -or ($lic.error -notmatch 'usage location')) { break }
                Start-Sleep -Seconds 8
            }
        }
        # 3) cloud group memberships - classify each group, act only on what Graph can write. Skip any
        #    group already added (Graph OR EXO) so re-runs never reprocess or duplicate memberships.
        foreach ($gn in @($rec.cloudGroups)) {
            if (($added -contains $gn) -or ($exoAdded -contains $gn)) { continue }
            # URL-encode the whole filter value so names with & / # etc. don't corrupt the query string
            $flt = [uri]::EscapeDataString("displayName eq '$($gn -replace "'","''")'")
            $grp = @()
            try { $grp = @(Invoke-Graph "/groups?`$filter=$flt&`$select=id,groupTypes,mailEnabled,membershipRule") } catch {}
            if (-not $grp.Count) { $failed += "$gn (not found in Entra)"; continue }
            $x = $grp[0]; $types = @($x.groupTypes)
            if ($x.membershipRule -or ($types -contains 'DynamicMembership')) { $auto += $gn; continue }          # dynamic -> automatic
            if ($x.mailEnabled -and ($types -notcontains 'Unified'))          { $manual += $gn; continue }        # mail-enabled/DL -> not writable via Graph
            $r = Add-EntraGroupMember -GroupId $x.id -UserId $u.id
            if ($r.ok) { $added += $gn } else { $failed += "$gn ($($r.error))" }
        }

        # 4) mail-enabled security / distribution groups -> Exchange Online (if configured).
        #    ($exoAdded was seeded above so already-added groups were skipped in step 3.)
        if ($manual.Count -gt 0 -and (Test-ExoConfigured)) {
            try {
                Connect-Exo | Out-Null
                $stillManual = @()
                foreach ($gn in $manual) {
                    $r = Add-ExoGroupMember -GroupName $gn -UserUpn $rec.upn
                    if ($r.ok) { $exoAdded += $gn } else { $failed += "$gn (EXO: $($r.error))"; $stillManual += $gn }
                }
                $manual = $stillManual   # only genuine failures remain flagged for manual follow-up
            } catch { $failed += "EXO connect failed: $($_.Exception.Message)" }
        }
        $exoAdded = @($exoAdded | Select-Object -Unique)

        # 5) Intune primary user (optional) - make this new user the primary user of the named device.
        #    Resolve the device via the READ app; set primary user via the WRITE app (needs
        #    DeviceManagementManagedDevices.ReadWrite.All). Retries next run if the device isn't enrolled yet.
        $idev = [string]$rec.intuneDevice
        if ($idev -and -not $rec.intunePrimaryDone) {
            try {
                $dflt = [uri]::EscapeDataString("deviceName eq '$($idev -replace "'","''")'")
                $md   = @(Invoke-Graph "/deviceManagement/managedDevices?`$filter=$dflt&`$select=id,deviceName")
                if (-not $md.Count)      { $failed += "Intune device '$idev' not found (not enrolled yet?)" }
                elseif ($md.Count -gt 1) { $failed += "Intune device '$idev' matches $($md.Count) devices - set primary user manually" }
                else {
                    $pr = Set-IntuneDevicePrimaryUser -DeviceId ([string]$md[0].id) -UserId $u.id
                    if ($pr.ok) { Set-RecProp $rec 'intunePrimaryDone' $true; Set-RecProp $rec 'intuneDeviceId' ([string]$md[0].id) }
                    else        { $failed += "Intune primary user for '$idev': $($pr.error)" }
                }
            } catch { $failed += "Intune device '$idev': $($_.Exception.Message)" }
        }

        Set-RecProp $rec 'groupsAdded'      @($added)
        Set-RecProp $rec 'groupsExo'        @($exoAdded)
        Set-RecProp $rec 'groupsAuto'       @($auto)
        Set-RecProp $rec 'groupsManual'     @($manual)
        Set-RecProp $rec 'groupsFailed'     @($failed)
        Set-RecProp $rec 'usageLocationSet' ([bool]$ul.ok)
        Set-RecProp $rec 'licenseStatus'    ($(if ($lic.ok) { if ($lic.note) { $lic.note } else { 'assigned' } } else { "error: $($lic.error)" }))
        Set-RecProp $rec 'lastRun'          (Get-Date).ToString('o')
        Set-RecProp $rec 'attempts'         (([int]$rec.attempts) + 1)

        if (-not ($ul.ok -and $lic.ok) -or $failed.Count -gt 0) {
            Set-RecProp $rec 'cloudStatus' 'partial'; Set-RecProp $rec 'note' 'partial - see failures'; $summary.partial++
        } elseif ($manual.Count -gt 0) {
            Set-RecProp $rec 'cloudStatus' 'manual-needed'; Set-RecProp $rec 'note' 'cloud done; mail-enabled groups need manual add'; $summary.partial++
        } else {
            Set-RecProp $rec 'cloudStatus' 'complete'; Set-RecProp $rec 'note' 'complete'; $summary.completed++
            if (-not $rec.completedAt) { Set-RecProp $rec 'completedAt' (Get-Date).ToString('o') }
        }

        # Email the outcome ONCE (createdByRole picks admin vs helpdesk recipient). complete/manual-needed
        # -> success notice; partial -> failure notice, but only after >=3 attempts so transient lags
        # (usageLocation commit, Intune access propagation) get a chance to self-heal first.
        if (-not $rec.notified) {
            $st = [string]$rec.cloudStatus
            $nrole = if ($rec.createdByRole) { [string]$rec.createdByRole } else { 'admin' }
            if ($st -eq 'complete' -or $st -eq 'manual-needed') {
                try { Send-OnboardingOutcomeNotification -Rec $rec -Role $nrole -Outcome 'complete' | Out-Null } catch {}
                Set-RecProp $rec 'notified' $true
            } elseif ($st -eq 'partial' -and ([int]$rec.attempts) -ge 3) {
                try { Send-OnboardingOutcomeNotification -Rec $rec -Role $nrole -Outcome 'failed' | Out-Null } catch {}
                Set-RecProp $rec 'notified' $true
            }
        }
    }
    } finally { Disconnect-Exo }

    Set-Store onboarding $queue
    [pscustomobject]$summary
}

# Drop COMPLETE onboarding records older than $Days from the queue so the page doesn't accumulate
# finished users (the completion email is the record of them). Only 'complete' is pruned - partial /
# manual-needed / waiting stay put because they still need attention. Returns the count removed.
function Clear-CompletedOnboarding {
    param([int]$Days = 7)
    $q = @(Get-Store onboarding)
    if (-not $q.Count) { return 0 }
    $cutoff = (Get-Date).AddDays(-[math]::Abs($Days))
    $keep = @($q | Where-Object {
        if ([string]$_.cloudStatus -ne 'complete') { return $true }           # keep anything not complete
        $stamp = if ($_.completedAt) { [string]$_.completedAt } else { [string]$_.lastRun }
        if (-not $stamp) { return $true }                                      # no timestamp -> keep (safety)
        $ts = [datetime]::MinValue
        if (-not [datetime]::TryParse($stamp, [ref]$ts)) { return $true }      # unparseable -> keep
        return ($ts -gt $cutoff)                                               # keep only if within the window
    })
    $removed = $q.Count - $keep.Count
    if ($removed -gt 0) { Set-Store onboarding $keep }
    $removed
}
