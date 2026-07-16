# PSConsole Developer Guide

How to **change** PSConsole without breaking it. This is the hands-on companion to the other docs:

| Doc | Answers |
|---|---|
| [`../HANDOFF.md`](../HANDOFF.md) | How the project is laid out, and the security invariants you must not break. **Read it first.** |
| [`ADMIN-GUIDE.md`](ADMIN-GUIDE.md) | How to *operate* the deployed app (config, credentials, provisioning). |
| **This file** | How to add a page, a script, a toggle, an add-on, or a write action — and the traps that bite. |
| [`../CHANGELOG.md`](../CHANGELOG.md) | What changed when. |

Everything here is specific to this codebase. Where it says "this bit the author", it's a real
incident, not a hypothetical.

---

## 1. The three execution contexts

**The single most important thing to internalise.** Code in this repo runs in one of three places, and
they have different PowerShell versions and different things in scope. Most confusing bugs are code
running somewhere other than where you assumed.

### (a) The service runspace — where routes live
- **Windows PowerShell 5.1**, as `example\zpsconsole`, started by WinSW.
- `app\lib\PSConsoleLib.psm1` is imported, so **every library function is in scope**: `Get-Store`,
  `Test-Authorized`, `Write-Audit`, `ConvertTo-PSCEncoded`, `Get-AppChrome`, `Invoke-HyperVMigration`, …
- This is `Start-PSConsole.ps1`, everything in `app\lib\`, and the `.pode` views.
- Changes here need a **service restart**.

### (b) The managed-script runspace — where catalog scripts live
- Created per run by `Invoke-ManagedScript` (`Start-PSConsole.ps1:29`) via `[PowerShell]::Create()`.
- **A fresh runspace with default session state — `PSConsoleLib` is NOT loaded.** None of the library
  functions exist. This is the #1 source of "but that function works everywhere else" bugs.
- A catalog script must therefore be **self-contained**, or dot-source what it needs explicitly:
  ```powershell
  . (Join-Path $PSScriptRoot '..\lib\Veeam.ps1')   # what 30-Get-VeeamJobStatus.ps1 does
  ```
  Note the lib files are written to be dot-sourceable standalone (they resolve their own config paths),
  which is *why* the config-path pattern in §6 looks the way it does.
- Still Windows PowerShell 5.1.
- Scripts are read **fresh from disk on every run** — no restart needed to change one.

### (c) Your tool/terminal shell
- On this box an agent's shell is **pwsh 7**, and shell state does **not** persist between calls.
- Consequences that have actually bitten:
  - `Get-WmiObject` / `Invoke-WmiMethod` **do not exist in pwsh 7**. Scripts using them (e.g.
    `graph-setup\Set-HyperVReadAccess.ps1`) must be run via `powershell.exe`, and they defensively
    `throw` if `$PSVersionTable.PSVersion.Major -ge 6`.
  - Setting `$env:X` in one call and reading it in the next **fails silently** — the variable is gone.
    Do multi-step work (especially credential handling) in a **single** call.

---

## 2. The restart matrix

| You changed | Restart needed? | Why |
|---|---|---|
| `app\scripts\*.ps1` | **No** | Read from disk per run by `Invoke-ManagedScript`. |
| `data\*.json` (config, users, add-on configs) | **No** | Read per request (`Get-Store`, `Get-<AddOn>Config`). |
| `app\lib\*.ps1`, `app\Start-PSConsole.ps1` | **Yes** | Loaded into the service runspace at start. |
| `app\web\views\*.pode` | **Yes** | Same. |

```powershell
Restart-Service PSConsole -Force
```
Binding to 443 takes **~17–31s**. The service being `Running` does **not** mean it's listening — poll
the port, don't trust the service state:
```powershell
Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue
```

> **Parse-check before you restart.** A syntax error in `Start-PSConsole.ps1` means the service starts
> and then dies, and you get an outage instead of an error message. This has happened:
> ```powershell
> $errs=$null
> [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errs)
> $errs   # empty = good
> ```

---

## 3. Anatomy of a request

```
browser
  -> Pode route            Add-PodeRoute -Method Get -Path '/admin/hyperv'
     -> Require 'action'   session check -> 302 /login ; RBAC check -> 403 Forbidden
     -> $u = $WebEvent.Session.Data.user      @{ username; role; type }  <- NO password, ever
     -> gather data        Get-Store / lib functions / Invoke-ManagedScript
     -> build HTML         in the ROUTE, with ConvertTo-PSCEncoded on every value
     -> Get-AppChrome      sidebar + theme -> $chrome.head / .open / .close
     -> Write-PodeViewResponse -Path 'hyperv' -Data @{ ... }
        -> app\web\views\hyperv.pode   dumb template: $($data.head) ... $($data.close)
```

Two conventions worth honouring because the whole codebase assumes them:

1. **Build HTML in the route, not the view.** Views stay near-dumb (`$($data.bodyHtml)`). This keeps
   the quoting sane (§7) and makes the logic testable.
2. **`Require` is the gate.** Hiding a nav item or a card is *cosmetic*. If a route isn't behind
   `Require`, it isn't protected — someone can POST to it directly.

`Require` (`Start-PSConsole.ps1:72`) returns `$false` after having already written the response, hence
the ubiquitous:
```powershell
if (-not (Require 'hyperv-view' $WebEvent)) { return }
```

---

## 4. RBAC

`Test-Authorized $role $action` (`app\lib\Auth.ps1`) is the whole model:

- **admin** → everything, unconditionally.
- **helpdesk** → `configure` / `view-history` / `upload` are **never** allowed (hard-coded, not
  toggleable). Everything else is **config-driven**: the action must be in `Get-HelpdeskFeatures`,
  which reads `helpdeskFeatures` from `data\config.json` and clamps it to `Get-HelpdeskFeatureCatalog`.
- Any other role → nothing.

### Adding a helpdesk toggle (worked example: `hyperv-migrate`)

1. **Add it to the catalog** — this alone makes the checkbox appear in Config:
   ```powershell
   # app\lib\Auth.ps1 - Get-HelpdeskFeatureCatalog
   [pscustomobject]@{ action = 'hyperv-migrate';    label = 'Hyper-V VM migration' }
   ```
   Order in the array = display order on the Config page.
2. **Gate the route** with the new action:
   ```powershell
   if (-not (Require 'hyperv-migrate' $WebEvent)) { return }
   ```
3. **Gate the UI** so the control isn't shown to someone who'd get a 403 anyway:
   ```powershell
   if ($rolesR.ok -and (Test-Authorized $u.role 'hyperv-migrate')) { $migHtml = "..." }
   ```
4. **Gate the nav item** in `Layout.ps1 Get-AppChrome`. `$hd` is the helpdesk feature set, computed
   once per render:
   ```powershell
   show=(($isAdmin -or ($hd -contains 'hyperv-view')) -and (Test-HyperVConfigured))
   ```
5. Restart, then test **all** the combinations (§10). The row that matters is *granted view, not
   migrate*: the card must be hidden **and** the POST must 403.

`$script:HelpdeskDefaultFeatures` is the fallback for installs with no `helpdeskFeatures` key. **Don't
add new actions to it** — that would silently widen access on upgrade. New toggles default to off.

### Two RBAC subtleties

- **Nav visibility ≠ authorisation.** They're computed in different files and can disagree. The route
  is the truth; nav is cosmetic. Always set both, but never rely on nav alone.
- **A tab permission does not grant the matching Run-page scripts.** Run-page visibility is a
  *separate* mechanism: `Test-RoleSeesScript` (`Catalog.ps1`) shows helpdesk only `.ROLE HelpDesk`
  scripts, **plus** categories listed in `$script:PSCHelpdeskGrantableCategories`:
  ```powershell
  $script:PSCHelpdeskGrantableCategories = @{ 'UniFi' = 'unifi' }
  ```
  So granting `hyperv-view` gives helpdesk the **Hyper-V tab** but *not* scripts `60`–`62` on the Run
  page, because `'Hyper-V'` isn't in that map. That's deliberate (the tab is the intended surface), but
  it's a real asymmetry — if you ever want the scripts exposed too, add
  `'Hyper-V' = 'hyperv-view'` to the map.

---

## 5. Recipe: add a page with a nav tab

1. **Icon** — `Layout.ps1 $script:PSCIcons`, an inline SVG. **`Layout.ps1` must stay ASCII-only**:
   WinPS 5.1 reads `.ps1` as ANSI, so a stray non-ASCII glyph mojibakes the whole sidebar.
2. **Nav item** — `Layout.ps1 Get-AppChrome $items`, with a `show=` expression (§4).
3. **Route** — in `Start-PSConsole.ps1`:
   ```powershell
   Add-PodeRoute -Method Get -Path '/admin/thing' -ScriptBlock {
       if (-not (Require 'thing-view' $WebEvent)) { return }
       $u = $WebEvent.Session.Data.user
       $chrome = Get-AppChrome -Active 'thing' -User $u -Title 'Thing' -Subtitle '...' `
                    -HasLogo ([bool]((Get-Store config).logoFile))
       # ... build $bodyHtml ...
       Write-PodeViewResponse -Path 'thing' -Data @{
           user=$u; bodyHtml=$bodyHtml; err=$err
           head=$chrome.head; open=$chrome.open; close=$chrome.close }
   }
   ```
   `-Active 'thing'` must match the nav item's `key` for the tab to highlight.
4. **View** — `app\web\views\thing.pode`:
   ```
   $($data.head)
   $($data.open)
   $($data.bodyHtml)
   $($data.close)
   ```
5. **Restart** and test.

---

## 6. Recipe: add an add-on (the dormant-gate pattern)

Every optional integration (Veeam, Intune, UniFi, Hyper-V, SharePoint) follows the same shape, so that
**shipping the code doesn't ship the capability**. Copy `app\lib\HyperV.ps1` — it's the smallest example.

```powershell
function Get-ThingConfigPath {
    if ($env:PSCONSOLE_DATA) { Join-Path $env:PSCONSOLE_DATA 'thing.config.json' }
    else { Join-Path $PSScriptRoot '..\..\data\thing.config.json' }
}
function Get-ThingConfig {
    $p = Get-ThingConfigPath
    if (-not (Test-Path $p)) { return $null }
    try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null }
}
function Test-ThingConfigured {
    $c = Get-ThingConfig
    return ([bool]$c -and [bool]$c.enabled)
}
```

The `$env:PSCONSOLE_DATA`-else-`$PSScriptRoot` dance exists so the file resolves **both** when loaded as
part of the module *and* when dot-sourced standalone from a catalog script (§1b).

Wire the gate into all four surfaces:
- `PSConsoleLib.psm1` — dot-source the new lib (**order matters**: before `Catalog.ps1` if the catalog
  references it).
- `Layout.ps1` — `show=(... -and (Test-ThingConfigured))`.
- The route — `if (-not (Test-ThingConfigured)) { ...render a "not configured" card...; return }`.
- `Catalog.ps1 Get-ScriptCatalog` — `-and ($_.Category -ne 'Thing' -or $thingOn)` so the scripts hide too.

**Secrets:** if the add-on needs one, DPAPI-encrypt it via a `graph-setup\Set-*.ps1` helper and
**never** write the secret back from a config-save path. Hyper-V deliberately has **no** secret — it
uses the service account's own Windows identity — which is why it's the cleanest template.

> **DPAPI reality check.** All secrets here use `Protect(bytes, $null, 'LocalMachine')`. That defeats
> *offline file theft* only. Any process running as any user on this box can `Unprotect` them, and
> `$null` entropy adds nothing. Don't describe it to anyone as protection against malware on the host.

---

## 7. Recipe: add a catalog script

Drop a `.ps1` in `app\scripts\`. **No restart.** The header drives everything
(`Get-ScriptMeta` reads only the **first 14 lines**):

```powershell
<#
.SYNOPSIS
    One line shown on the Run page.
.CATEGORY
    AD Hygiene
.ROLE
    HelpDesk
.RUNEXAMPLE
    Days=30
#>
param([int]$Days = 30)
```

- `.CATEGORY` → grouping. Add new categories to `$script:PSCCategoryOrder` (`Catalog.ps1`) or they sort
  to the end. Add-on categories must also be gated in `Get-ScriptCatalog`.
- `.ROLE` → `HelpDesk` or `Admin`. **Fail-closed: no `.ROLE` = Admin-only.** Enforced in the catalog
  *and* on the `/run` route.
- Without `.CATEGORY`, it falls back to the numeric prefix: `0x`=Active Directory, `1x`=Entra ID,
  `2x`=Intune. Current allocation: `0x` AD · `1x` Entra · `2x` Intune · `3x` Veeam · `5x` AD Hygiene ·
  `6x` Hyper-V.

### Three traps specific to catalog scripts

**1. Any error-stream output marks the whole run failed.** `Invoke-ManagedScript` does:
```powershell
@{ ok=($errs.Count -eq 0); error=($errs -join "`n"); data=@($out) }
```
So a `Write-Error` — or a *non-terminating* error you ignored — makes `ok=$false` even if the script
produced perfectly good output. Suppress expected noise (`-ErrorAction SilentlyContinue`) or the Run
page reports failure on success.

**2. Format dates in the script, never in the UI.** WinPS 5.1's `ConvertTo-Json` renders `DateTime` in
the legacy `/Date(1333728371000)/` format, and the Run page renders cells raw. Emit **preformatted local
strings** — that fixes the table, the CSV export, and the emailed report at once:
```powershell
function Format-Stamp { param($Value) if ($Value) { ([datetime]$Value).ToString('MM/dd/yyyy h:mm tt') } else { '' } }
```

**3. Sort *before* you format.** Formatting to a string first sorts lexicographically —
`"12/01/2025"` ranks as newer than `"01/02/2026"`. Sort on the real `[datetime]`, then project:
```powershell
... | Sort-Object LockedOutAt -Descending |
      Select-Object Name, @{Name='LockedOutAt'; Expression={ Format-Stamp $_.LockedOutAt }}
```

### And a directory-data trap

ADSI `whenCreated` / `whenChanged` are **UTC but tagged `Kind=Unspecified`**, while
`lastLogonTimestamp` / `pwdLastSet` are FILETIMEs that convert correctly via
`FromFileTimeUtc().ToLocalTime()`. Mix them and you get a silent 4-hour disagreement between columns.
```powershell
function ConvertFrom-AdUtc {
    param($Value)
    if (-not $Value) { return $null }
    [datetime]::SpecifyKind([datetime]$Value, [DateTimeKind]::Utc).ToLocalTime()
}
```
CIM datetimes, by contrast, are **already `Kind=Local`** — format them, don't shift them.

---

## 8. Recipe: add a write action

Read **HANDOFF invariants #1 and #2** first. The rules are absolute: `zpsconsole` stays read-only, and
writes run as the **operator's own credentials**, entered per request, never stored, never logged.

`Invoke-HyperVMigration` (`app\lib\HyperV.ps1`) and `New-OnPremUser` (`UserProvision.ps1`) are the two
reference implementations. The pattern:

```powershell
# 1. MASTER SWITCH - the code can ship, deployed and reviewable, unable to do anything.
if (-not (Test-ThingWriteEnabled)) {
    Write-Audit $u.username $u.role 'thing-preview' $target @{ ... } 'preview' 0 'writes disabled'
    Write-PodeJsonResponse -Value @{ ok=$true; preview=$true; message='Preview only - nothing changed.' }
    return
}

# 2. VALIDATE AGAINST REALITY, not against what the browser posted.
$role = @($roles | Where-Object { $_.Name -eq $vm }) | Select-Object -First 1
if (-not $role) { ...reject... }

# 3. CONFIRM GATE.
if ("$($b.confirm)" -notmatch '^(true|on|1|yes)$') { ...reject... }

# 4. DO IT as the operator.
$res = Invoke-ThingWrite -OperatorUser ([string]$b.opUser) -OperatorPassword ([string]$b.opPassword) ...

# 5. AUDIT - username only. NEVER the password.
# Audit params deliberately EXCLUDE opPassword - only the operator's USERNAME is recorded.
Write-Audit $u.username $u.role 'thing-write' $target @{ by=[string]$b.opUser; ... } $status $ms $detail
```

Also:
- **Clear the password field in the browser** right after the POST — on the success *and* error paths
  (`hyperv.pode hvMigrate()`).
- **Never interpolate user input into a remote scriptblock.** Pass it as `-ArgumentList`:
  ```powershell
  Invoke-Command -ComputerName $h -Credential $cred -ArgumentList $VMName, $TargetNode -ScriptBlock {
      param($vm, $node)
      Move-ClusterVirtualMachineRole -Name $vm -Node $node ...
  }
  ```
  Interpolating `$VMName` into the scriptblock body would make a crafted VM name executable on the host.
- **Don't put credential-taking actions on the Run page.** It audits its `Key=Value` params verbatim, so
  a password typed there lands in `audit.jsonl`. A dedicated tab is the only safe surface.
- **Master switches stay file-only** where the blast radius warrants it (`migrationEnabled` in
  `data\hyperv.config.json`, `enabled` in `provision.json`). A Config checkbox would put production VM
  migration one click from anyone holding `configure`. The Config page *displays* the state read-only so
  it stays discoverable.

### Verifying a secret never leaks: the canary test

Don't reason about it — prove it. POST a unique string as the password, then grep:
```powershell
$CANARY = 'ZZ-CANARY-PW-' + [guid]::NewGuid().ToString('N').Substring(0,10)
# ...POST it as opPassword...
Select-String -Path 'E:\apps\PSConsole\data\audit.jsonl' -SimpleMatch $CANARY -Quiet   # must be $false
$body -match [regex]::Escape($CANARY)                                                   # must be $false
```
Test the **failure** path too, not just the happy one — exception messages and stack traces are where
credentials usually escape. Use a **nonexistent** operator account (`DOMAIN\ZZ-nosuchuser`) so auth
fails before anything happens and no real account risks lockout.

---

## 9. Writing `.pode` views

A view is evaluated as an **expandable PowerShell string**. So:

- `$(...)` **executes**. A literal `$` in prose will try to interpolate — escape it.
- Attribute quoting: prefer `'single'` inside `"double"` blocks, mirroring the existing views.
- **Don't nest double quotes two levels deep** inside a `$()` subexpression. It sometimes parses and
  sometimes doesn't, and the failure is a 500 at render time, not at parse time. If you need a
  conditional fragment, compute it **in the route** and pass it in (`$data.hypervMigPill`).

> **`\"` is not a PowerShell escape.** The escape character is the **backtick**. Writing `\"` inside a
> double-quoted string **terminates the string** — this exact mistake produced a parse error in
> `Start-PSConsole.ps1` and **took the service down**. In HTML, use `&quot;`. In PowerShell, use
> `` `" ``.

Views can call module functions (they render in the service runspace), but resist — see §3.

### Encoding: every value, every time

`ConvertTo-PSCEncoded` (`Render.ps1`) encodes the full OWASP set **including the single quote**
(`&#39;`), so values are safe inside single-quoted attributes too:
```powershell
"<td>$(ConvertTo-PSCEncoded ([string]$_.Name))</td>"
```
Anything originating from AD, a cluster, Graph, or a form is attacker-influenceable. Encode it.
`ConvertTo-PSCInline` adds `` `code` ``/`**bold**`/links on top, and deliberately allows only
`http(s)://` links (blocking `javascript:`).

---

## 10. Testing an authenticated page

`Write-PodeViewResponse` output can only really be checked by asking the server for it. The harness
(full recipe in the `testing-pode-auth-cookie` memory; summary in HANDOFF §Testing):

1. Back up `data\users.json`; inject a throwaway user. **The root is a JSON array**, and login reads it
   fresh — **no restart needed**:
   ```powershell
   $arr = [System.Collections.ArrayList]@(Get-Content $users -Raw | ConvertFrom-Json)
   $null = $arr.Add([pscustomobject]@{ username='ZZ-psc-test'; hash=(New-Hash $pw); role='admin'; type='local' })
   $arr.ToArray() | ConvertTo-Json -Depth 8 | Set-Content $users -Encoding UTF8
   ```
2. `HttpClientHandler` with `AllowAutoRedirect=$false`, `UseCookies=$false`, and
   `ServerCertificateCustomValidationCallback = [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator`.
3. POST `FormUrlEncodedContent` to `/login`; scrape `pode.sid` from the 302's `Set-Cookie`; resend it as
   a manual `Cookie:` header.
4. **Restore from the backup in `finally`.** Always.

Conventions that keep tests from becoming incidents:
- **Throwaway records are `ZZ-`-prefixed.** Never test against real users, VMs, or inventory.
- **Test before *and* after every change**, so you know a failure is yours.
- **Test the branch you actually changed.** A test that only exercises the "not present / not
  configured" path proves nothing. A `-WhatIf` run of `Set-HyperVReadAccess.ps1` once passed on a host
  with no `root\virtualization\v2` namespace — only the skip branch ran, and a real bug shipped.
- **Don't edit `audit.jsonl` to remove test traffic.** An honest `ZZ-psc-test … status: preview` record
  is better than a quietly doctored audit log.

---

## 11. Windows PowerShell 5.1 traps

Beyond the date/JSON items in §7:

- **`@($list)` on a `List[object]` throws** *"Argument types do not match"*. Use `.ToArray()`.
- **Nested `[ordered]@{...}` literals** throw the same. Assign keys individually.
- **`.ps1` files are read as ANSI.** Keep dot-sourced libs — `Layout.ps1` especially — ASCII-only.
- **`ConvertTo-Json` collapses single-element arrays** and has depth traps; see the notes in `Store.ps1`.
  Where the wire format must be exact (SharePoint multi-choice columns, `Set-EntraLicense`), raw JSON
  strings are used instead.
- **`Invoke-Graph` auto-pages** every `@odata.nextLink`, so `$top` does **not** cap results. For "last N",
  use `Get-GraphToken` plus a single non-paged `Invoke-RestMethod` with a server-side filter.
- **WMI singletons**: `Get-WmiObject -Class __SystemSecurity` returns a bare object with **no methods**.
  Address it by path: `Invoke-WmiMethod -Path '__systemsecurity=@' -Name GetSecurityDescriptor`.
- **`Invoke-WmiMethod` honours `-WhatIf` on *reads* too**, silently skipping them and returning an empty
  result. Pass `-WhatIf:$false` on reads, `-Confirm:$false` on writes.
- **`CreateInstance()` returns a PSObject wrapper.** Appending it to a `$sd.DACL` makes
  `SetSecurityDescriptor` return **rc=0 having stored nothing** — a grant that reports success and does
  nothing. Use `.psobject.immediateBaseObject`, and cast filtered ACE arrays back with
  `[System.Management.ManagementBaseObject[]]`.
- **Never trust `rc=0` from `SetSecurityDescriptor`.** Re-read and prove the ACE is there.
- **Security descriptors do not marshal over *remote* WMI.** The read succeeds and comes back
  structurally intact with **empty ACE fields** — indistinguishable from "no ACEs exist". This produced a
  confident, completely wrong diagnosis. **Read descriptors locally on the host.**

---

## 12. Debugging

- **Service won't start after an edit** → parse error. Parse-check the file (§2). WinSW logs are in
  `service\*.log` (gitignored).
- **A page 500s** → usually a `.pode` quoting bug (§9) or a null `$data.*` the view dereferences.
- **A Run-page script "fails" but the output looks right** → error-stream pollution (§7 trap 1).
- **Dates look like `/Date(…)/`** → fix at the source script, not the renderer (§7 trap 2).
- **Helpdesk sees something they shouldn't** → check `Get-HelpdeskFeatureCatalog`,
  `$HelpdeskDefaultFeatures`, **and** `Layout.ps1`; they're three separate places (§4).
- **A health/status panel reports "all good"** → make sure it distinguishes *no problems* from *couldn't
  read*. Falling through to a green banner on a failed query is the worst failure mode a health panel
  has; `$roleRows` in the Hyper-V route shows the correct shape.

---

## 13. Before you commit

1. Parse-check everything you touched.
2. Restart if §2 says so; confirm the port is **listening**, not just the service `Running`.
3. Re-run the auth harness for the pages you touched — and the RBAC matrix if you touched permissions.
4. Update `CHANGELOG.md`, bump `VERSION` (fold unpublished work into the pending version rather than
   double-bumping).
5. `.\tools\Build-DistZip.ps1` — the scrub + **fail-closed leak gate** runs here. The working tree keeps
   real names on purpose; only shipped copies are scrubbed. **Never scrub the source.**
6. Keep genuinely private notes in the working tree with paired markers — the leak gate fails the build
   if a marker is unbalanced, rather than leaking the block:
   ```
   ```
