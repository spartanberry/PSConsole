# Render.ps1 - minimal, safe Markdown -> HTML for admin-authored runbooks.
# Content is HTML-encoded FIRST (so stored text can never inject markup), then a
# small, fixed Markdown subset is applied. Requires nothing else.

function ConvertTo-PSCEncoded {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

# Inline formatting, applied to already-encoded text: `code`, **bold**, [text](http(s)://url)
function ConvertTo-PSCInline {
    param([string]$Text)
    $t = ConvertTo-PSCEncoded $Text
    $t = [regex]::Replace($t, '`([^`]+)`', '<code>$1</code>')
    $t = [regex]::Replace($t, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    # only http/https links are allowed (blocks javascript: etc.)
    $t = [regex]::Replace($t, '\[([^\]]+)\]\((https?://[^\s)]+)\)', '<a href="$2" target="_blank" rel="noopener">$1</a>')
    return $t
}

function ConvertTo-RunbookHtml {
    param([string]$Markdown)
    if ([string]::IsNullOrWhiteSpace($Markdown)) { return '<p class="note">No runbook content yet.</p>' }
    $lines = ($Markdown -replace "`r`n", "`n" -replace "`r", "`n") -split "`n"
    $sb = New-Object System.Text.StringBuilder
    $listType = $null   # 'ul' | 'ol' | $null
    foreach ($raw in $lines) {
        $line = $raw.TrimEnd()

        $ul = [regex]::Match($line, '^\s*[-*]\s+(.*)$')
        $ol = [regex]::Match($line, '^\s*\d+\.\s+(.*)$')

        if ($ul.Success) {
            if ($listType -ne 'ul') { if ($listType) { [void]$sb.Append("</$listType>") }; [void]$sb.Append('<ul>'); $listType = 'ul' }
            [void]$sb.Append('<li>' + (ConvertTo-PSCInline $ul.Groups[1].Value) + '</li>'); continue
        }
        if ($ol.Success) {
            if ($listType -ne 'ol') { if ($listType) { [void]$sb.Append("</$listType>") }; [void]$sb.Append('<ol>'); $listType = 'ol' }
            [void]$sb.Append('<li>' + (ConvertTo-PSCInline $ol.Groups[1].Value) + '</li>'); continue
        }

        if ($listType) { [void]$sb.Append("</$listType>"); $listType = $null }

        $h = [regex]::Match($line, '^(#{1,3})\s+(.*)$')
        if ($h.Success) {
            $level = $h.Groups[1].Value.Length + 1   # # -> h2, ## -> h3, ### -> h4
            [void]$sb.Append("<h$level>" + (ConvertTo-PSCInline $h.Groups[2].Value) + "</h$level>"); continue
        }
        if ($line -match '^(-{3,}|\*{3,})\s*$') { [void]$sb.Append('<hr>'); continue }
        $bq = [regex]::Match($line, '^>\s?(.*)$')
        if ($bq.Success) { [void]$sb.Append('<blockquote>' + (ConvertTo-PSCInline $bq.Groups[1].Value) + '</blockquote>'); continue }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        [void]$sb.Append('<p>' + (ConvertTo-PSCInline $line) + '</p>')
    }
    if ($listType) { [void]$sb.Append("</$listType>") }
    return $sb.ToString()
}

# Seed content used when no runbook has been saved yet. Admins edit it in-app afterward.
function Get-DefaultRunbook {
    return [PSCustomObject]@{
        title = 'New User Creation'
        body  = @'
# New User Creation - Standard Process

Follow these steps for every new user account request.

## 1. Verify the request
- Confirm an approved onboarding ticket exists; record the ticket number.
- Confirm the user's start date, department, manager, and job title.

## 2. Account details
- **Username:** `first.last` (all lowercase). If taken, use `first.last2`.
- **Display name:** `First Last`
- **UPN / email:** `first.last@example.org`
- **OU:** `OU=Staff,DC=example,DC=org` (use the department sub-OU if one exists)

## 3. Group membership
- Add to **Staff-All**.
- Add to the department group: **Dept-<Department>**.
- Add any role-specific groups noted on the ticket.

## 4. Mailbox
- Enable the mailbox and apply the standard quota.
- Add to shared mailboxes / distribution lists per the ticket.

## 5. Finish up
- Set "User must change password at next logon".
- Record the temporary password in the ticket (do not email it in plain text).
- Notify the manager that the account is ready, then close the onboarding ticket.

> Reminder: PSConsole cannot create accounts - its service account is read-only in AD.
> Perform the actual creation in ADUC, or with an account that has write rights.
'@
    }
}
