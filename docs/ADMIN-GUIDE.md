# PSConsole Admin Guide

PSConsole is a self-hosted [Pode](https://badgerati.github.io/Pode/) (PowerShell 5.1) web app for
running curated PowerShell scripts through a browser with role-based access control, plus an
automated Active Directory / Entra **user-provisioning** workflow.

- **Host:** `PSCONSOLE01`, Windows service **PSConsole** (WinSW), HTTPS on port **443**
- **Service account:** `example\zpsconsole` (read-only to AD by design)
- **App root:** `E:\apps\PSConsole`
- **Repo:** `spartanberry/PSScripts` under `psconsole/` (data/secrets are gitignored)

---

## 1. Architecture

```
E:\apps\PSConsole
  app\
    Start-PSConsole.ps1     # Pode server: routes, schedules, auth wiring
    lib\                    # dot-sourced module (PSConsoleLib.psm1)
      Store.ps1             #   flat JSON persistence under data\
      Auth.ps1             #   local (PBKDF2) + LDAPS login, RBAC
      Audit.ps1            #   append-only audit log
      Render.ps1           #   view/encoding helpers
      Graph.ps1            #   app-only Graph READ helper (+ Get-EntraGroupUsers)
      GraphWrite.ps1       #   app-only Graph WRITE helper (groups + license)
      ExchangeOnline.ps1   #   app-only EXO helper (mail-enabled groups / DLs)
      UserProvision.ps1    #   plan derivation, on-prem create, onboarding queue
      Onboarding.ps1       #   Phase-2 cloud processor
    scripts\               # the curated .ps1 catalog shown in the dashboard
    web\views\             # .pode HTML views
  data\                    # runtime state + SECRETS (gitignored) - see section 3
  graph-setup\             # one-time credential helpers
  modules\Pode\            # vendored Pode framework
  service\                 # WinSW exe + PSConsole.xml + logs
  docs\, VERSION, CHANGELOG.md
```

**Threads:** the server runs with `-Threads 5`. This matters — Pode defaults to a single request
runspace, so one slow/hung request would freeze the whole site (login included).

---

## 2. Hosting & service control

```powershell
Get-Service PSConsole
Restart-Service PSConsole -Force      # ~15s to re-bind port 443
```

The service runs `powershell.exe -NoProfile -File app\Start-PSConsole.ps1 -Port 443 -CertThumbprint <thumb>`.
Logs are under `service\` (WinSW). The TLS cert thumbprint can also be set in `data\config.json`
(`certThumbprint`), which overrides the install argument.

**If the site freezes** (all routes hang, 0% CPU): `Stop-Service PSConsole -Force`; if the child
`powershell.exe` is wedged, kill it; `Start-Service PSConsole`; wait ~15s for 443 to listen.

### Replacing the TLS certificate

PSConsole serves HTTPS from a cert in the machine's Personal store (`LocalMachine\My`), read by
**thumbprint** at startup. To add or swap the site certificate (e.g. a CA-issued or wildcard cert to
replace the self-signed default, or a renewed cert), run the guided helper **on the server, elevated**:

```powershell
# import a new .pfx (with its private key) and make it live:
cd E:\apps\PSConsole\graph-setup
.\Set-TlsCertificate.ps1 -PfxPath C:\temp\wildcard.pfx -Hostname psconsole.example.org

# or use a cert already installed in LocalMachine\My:
.\Set-TlsCertificate.ps1 -Thumbprint <thumbprint>

# or pick one interactively:
.\Set-TlsCertificate.ps1
```

The helper imports the PFX (if given), validates the cert (private key present, not expired, hostname
covered by a SAN), **grants the service account (`zpsconsole`) read on the private key**, writes the
thumbprint to `config.json`, restarts the service, and verifies the new cert is being served. A
restart is required for a cert change — the helper does it for you. A wildcard `*.example.org`
covers a single-label host like `psconsole.example.org`; DNS for that host is a CNAME to the
server's FQDN (the endpoint binds `-Address '*'`, so no rebind is needed for a new hostname).

> If HTTPS fails to come up after a cert change, the usual cause is the service account not being able
> to read the new key — re-run the helper, or grant it manually via `certlm.msc` -> the cert -> All
> Tasks -> Manage Private Keys -> add `zpsconsole` = Read.

---

## 3. Data & secrets (`data\` - gitignored)

| File | Contents | Sensitive |
|---|---|---|
| `config.json` | LDAP settings, role-group map, cert thumbprint, logo | low |
| `users.json` | local accounts (PBKDF2 hashes) | **yes (hashes)** |
| `provision.json` | department/group/job-title mapping + provisioning settings | low |
| `onboarding.json` | queued cloud-onboarding records | low |
| `supervisors-cache.json` | cached Supervisors-group members (4h TTL) | low |
| `graph.config.json` | Graph READ app creds (DPAPI-encrypted secret) | **yes** |
| `graph-write.config.json` | Graph WRITE app creds (DPAPI-encrypted secret) | **yes** |
| `exo.config.json` | EXO app id/org/cert thumbprint (no secret; cert-based) | low |
| `audit.jsonl` | append-only audit log | low |
| `ldap-debug.log` | failed LDAP bind reasons (no passwords) | low |
| `smtp.config.json` | email-notification settings (optional DPAPI-encrypted SMTP password) | **yes (if password set)** |
| `notify.log` | email-send failures | low |

**DPAPI note:** the Graph secrets are encrypted with **LocalMachine** scope and can only be
decrypted on the machine that encrypted them (`PSCONSOLE01`). They do **not** transfer to another
server - on rebuild you must re-run the credential helpers there (see section 10).

---

## 4. Authentication & roles

Login tries **local accounts first** (`users.json`), then **LDAPS** if `ldapEnabled` is true.

- **Local admin:** the `admin` account always works (break-glass).
- **AD login:** enabled via Config; users authenticate with `UPN` (`user@example.com`) or
  `DOMAIN\user` (`example\user`). Role is resolved from AD group membership against the
  role-group map.
- **Role-group map** (Config page → "admin/helpdesk AD group CNs"): enter the group **CN only**
  (e.g. `PSConsole-Admin`), *not* the full DN. Admin group members get the `admin` role.

**Roles:** `admin` = everything (config, upload, run, create-user, onboarding, decommission-user);
`helpdesk` = run + view-history + **decommission-user**. To also let helpdesk create users, add
`'create-user'` to the helpdesk actions in `Auth.ps1` (`Test-Authorized`).

---

## 5. Running & uploading scripts

- **Run:** pick a script from the dashboard dropdown, optionally pass params as
  `Key=Value;Key2=Value2`, click Run. Output renders as a table with CSV export.
- **Upload (admin):** the file picker uploads a `.ps1` into `app\scripts\` (appears immediately;
  no restart). Scripts declare `.ROLE HelpDesk` (or Admin) in their header comment.

### Entra reporting scripts (`10`-`19`)
Read-only Microsoft Graph reports (disabled users, MFA registration, license summary, group members,
etc.). They authenticate app-only via `data\graph.config.json` (the **read** app). Example:
`19-Get-EntraGroupMembers.ps1` lists a group's members + job titles - type `Group=<name>` (or
`GroupName=<name>`) in the params box; spaces are fine.

---

## 6. User provisioning (the automated Create User workflow)

Helpdesk/admin fills a form (first/last name, username, department, job title, supervisor, mobile);
PSConsole creates the on-prem AD user, then - after Entra Connect syncs it - assigns the license and
cloud group memberships.

### Master switch
`provision.json` -> `"enabled"`. **While `false`, Create User is preview-only and writes nothing.**
Keep it false until AD create-delegation is in place.

### Security model
- **On-prem create** binds to AD with the **operator's own credentials** (entered per request,
  never stored, never logged, excluded from audit). `zpsconsole` stays read-only.
- **Cloud group/license** happen after sync, from the cloud, via dedicated write apps (section 8).

### Department mapping (`provision.json`, edit via Config -> Department mapping)
Group membership for a new user resolves as, in order, de-duplicated:
1. `baseGroups` - added to everyone
2. `onCallGroup` - added unless the department is in `onCallExceptDepartments`
3. the department's `cloudGroups`
4. each checked job title's `addGroups`, minus its `removeGroups`
5. plus `supervisorGroups` if the (currently hidden) "Add to Supervisors" option is used

Other keys: `upnSuffix` (sign-in domain), `supervisorGroup` (source of the Supervisor dropdown),
`licenseSkuId` (license assigned during onboarding), `usageLocation` (set before licensing),
`onboardingAutoRun` (true = process onboarding every 5 min). Each department has `ou` (target OU DN),
`cloudGroups`, `licenseGroup` (unused - licensing is by SKU), and `jobTitles[]`
(`name`/`addGroups`/`removeGroups`). The checked job title is written to the AD **title** attribute.

### Group types matter (checked automatically by the processor)
- **Dynamic** groups (rule-based, e.g. AllStaff, TRD_Staff) - membership is automatic; the processor
  skips them.
- **Static M365 / security** groups - added via Graph.
- **Mail-enabled security groups / distribution lists** - Graph can't write these; added via
  Exchange Online (section 8) if configured, otherwise flagged "needs manual".

### Phase 1 - on-prem create
`GET /users/new` form -> Preview (validates, shows resolved plan) -> Create (operator enters their AD
creds + an initial password). Requires **AD delegation** on the target OU: *Create User objects* +
*Reset Password* + write the needed attributes, granted to the operator account(s).

### Phase 2 - cloud onboarding (`/users/onboarding`)
Queued after a successful create. Once the user syncs to Entra, the processor sets `usageLocation`,
assigns the license, adds Graph-writable groups, and (if EXO configured) adds mail-enabled groups.
Idempotent and safe to re-run. Run manually with **Run onboarding now**, or enable `onboardingAutoRun`.
Status per record: `pending-sync` -> `complete` / `partial` / `manual-needed`.

### Decommissioning a user (`/users/decommission`)
Available to **helpdesk and admin** (nav: **Decommission User**). Flow: type the username
(sAMAccountName / UPN / display name) → **Look up** (read-only preview of the account, its OU, and its
on-prem group memberships) → tick the confirmation box + enter your **own AD credentials** → run.
PSConsole then, binding as **you**:
1. disables the account (sets `ACCOUNTDISABLE`) and stamps a `description`,
2. removes it from its on-prem groups (best-effort, per group),
3. moves it to the **Disabled Accounts OU** (`disabledOu` in `provision.json`, default
   `OU=Disabled Accounts,DC=example,DC=org`).

Because that OU is **outside the Entra Connect sync scope**, the next ADSync cycle removes the user
from Entra (and thus all cloud groups) automatically - no cloud calls are made here. The tool
**refuses** to decommission members of protected/administrative groups (Domain Admins, etc.); do those
by hand. Gated by the same provisioning `enabled` master switch (preview-only while off).

---

## 6b. Email notifications (optional)

If `data\smtp.config.json` is present and `enabled`, PSConsole emails a summary on every user
**create** and **decommission**. Configure with `graph-setup\Set-SmtpConfig.ps1` (on PSCONSOLE01):

```powershell
# anonymous internal relay:
.\Set-SmtpConfig.ps1 -Server smtp.example.org -Port 25 -From psconsole@example.com -To it@example.com
# authenticated + TLS (prompts for the password, DPAPI-encrypted):
.\Set-SmtpConfig.ps1 -Server smtp.office365.com -Port 587 -UseSsl -From psconsole@example.com -To it@example.com -Username psconsole@example.com
```

Sending is best-effort: a missing config or a send failure never blocks or fails the create/
decommission - failures are logged to `data\notify.log`.

---

## 7. Hybrid sync dependency

New users are created on the on-prem DC and must land in an OU **inside Entra Connect's sync scope**
(current target: `OU=Users,OU=Example,DC=example,DC=org`; test: `OU=Test,...`). They appear in
Entra on the next sync (~30 min, or force a delta sync on the Connect server). Cloud onboarding can
only run **after** the user has synced.

---

## 8. App registrations & credentials

| App | Config file | Permissions | Auth |
|---|---|---|---|
| **PSConsole (Graph read)** | `graph.config.json` | User.Read.All, Group.Read.All, Directory.Read.All, AuditLog.Read.All (read-only) | client secret |
| **PSConsole-Graph-Write** | `graph-write.config.json` | GroupMember.ReadWrite.All, User.ReadWrite.All | client secret |
| **PSConsole-EXO-Write** | `exo.config.json` | Office 365 Exchange Online: Exchange.ManageAsApp + **Exchange Administrator** role | **certificate** |

Set them up with the helpers in `graph-setup\` (run **on PSCONSOLE01**):
- `Set-GraphCredential.ps1 -TenantId <g> -ClientId <g>` (READ app; prompts for the secret; DPAPI-encrypts).
- `Set-GraphWriteCredential.ps1 -TenantId <g> -ClientId <g>` (prompts for the secret; DPAPI-encrypts).
- `Set-ExoConfig.ps1 -AppId <g> -Organization contoso.onmicrosoft.com -CertThumbprint <t>`.
  Requires the `ExchangeOnlineManagement` module (`Install-Module ExchangeOnlineManagement -Scope
  AllUsers`) and the cert's **private key readable by `zpsconsole`** (certlm.msc -> Manage Private Keys).

---

## 8b. Reports & Veeam (admin)

**Scheduled reports** (standard) - the **Reports** tab. Define a report that runs a catalog script on
a schedule (daily/weekly/monthly at a set time, optional `Name=Value` params) and emails the result as
an HTML table to a recipient list. Enable/disable, **Run now**, and delete are on the page. A dispatcher
fires every 15 min and sends any report whose time has passed for its current occurrence. Requires SMTP
(`Set-SmtpConfig.ps1`); the page warns if email isn't configured.

**Veeam backup reports** (optional add-on) - the **Veeam** tab, shown only when `data\veeam.config.json`
is present and enabled. Two read-only views: last backup result per job, and success/warning/failure
counts over 7/30/90 days. Configure with:

```powershell
cd graph-setup
.\Set-VeeamConfig.ps1 -Server backupserver.example.org -Username DOMAIN\svc-veeamread   # or omit -Username to use the service account
```

How it works: PSConsole opens a WinRM session to the Veeam server (Windows PowerShell 5.1) and shells
out to **pwsh 7** there to load the PS7-targeted `Veeam.Backup.PowerShell` module - so this host needs no
Veeam console, and the Veeam server needs no PS7 remoting endpoint. It reads the last run per job
(`Get-VBRJob` + `FindLastSession()`) and per-job success/warning/failure counts over the window
(the per-job session store) - both fast; the whole page loads in ~30s. The account used must (1) be able
to WinRM into the Veeam server and (2) have Veeam read rights (a "Backup Viewer" / "Restore Operator"
role). Read-only - no backup is ever started or changed.

By default (no `-Username`) the query runs as the **PSConsole service account**, which usually is *not*
allowed to WinRM into a separate backup server - so the page shows "Access is denied". The clean fix is a
dedicated least-privilege reader account: `Set-VeeamConfig.ps1 -Server ... -Username DOMAIN\svc-veeamread`
(the password is stored DPAPI-encrypted, machine-bound). Grant that account remote WinRM + the Veeam
Backup Viewer role on the backup server.

**First-time certificate trust (Veeam 12.1+) - required one-time step.** The modern Veeam PowerShell
client pins the backup server's self-signed certificate *per Windows user*: the very first connection
must interactively **accept** it. A query account driven non-interactively never sees that prompt, so the
page fails with **"Failed to connect to Identity service"** even when WinRM, the credential, and the Veeam
role are all correct. Establish the trust once for the configured account:

```powershell
cd graph-setup
.\Set-VeeamTrust.ps1        # accepts the certificate on the query account's behalf (read-only)
```

Re-run it only if the Veeam server's certificate is regenerated (e.g. after a Veeam upgrade). This is a
Veeam-side trust, unrelated to any host hardening/GPO - no security policy needs to change.

**Export & email.** The Veeam page has **Export CSV** (downloads the current view - all-jobs summary or the
selected job's runs) and **Email** (sends that view to one address; needs SMTP via `Set-SmtpConfig.ps1`). For
recurring delivery, schedule the **`30-Get-VeeamJobStatus.ps1`** report on the **Reports** tab (e.g. Daily
07:00, `Days=7`) - one row per job with last result + success/warning/failure counts, emailed automatically.

---

## 8c. Intune reports (admin add-on)

**Intune reports** (optional add-on) add an **Intune** category to the Run-scripts page (admin-only):
managed-device inventory, non-compliant / stale devices, compliance summary, encryption status, a
connector status board (Exchange / NDES / Managed Google Play / MTD / partners), Apple token expirations
(APNs push cert + VPP + ADE/DEP), and Windows Autopilot. All are read-only Microsoft Graph queries.

They reuse the **same Graph app registration** as the Entra reports (`data\graph.config.json`) - no new
credential. Two steps to turn it on:

1. In Entra, add these **application** permissions to that app and **grant admin consent** (no
   secret/clientId change is needed - client-credentials tokens use `scope=.default`, so newly consented
   permissions apply automatically):
   - `DeviceManagementManagedDevices.Read.All`
   - `DeviceManagementConfiguration.Read.All`
   - `DeviceManagementServiceConfig.Read.All`
2. On the server, enable the add-on and restart:
   ```powershell
   cd graph-setup
   .\Set-IntuneConfig.ps1        # writes data\intune.config.json (enabled). -Disabled to keep it dormant.
   Restart-Service PSConsole
   ```

Until enabled, the Intune category is hidden and its scripts refuse to run (so the public build ships it
dormant). The connector/expiration reports handle "not configured" endpoints cleanly (e.g. no on-prem
Exchange connector, or no Apple VPP) - they show *not applicable* / *not configured* rather than an error.

The expiration and connector reports (e.g. `26-Get-IntuneAppleExpirations`, `25-Get-IntuneConnectorStatus`)
can be scheduled and emailed like any catalog script - see 8b - handy for catching an APNs certificate
before it lapses.

### Run-scripts categories & roles
The Run page groups scripts into **Active Directory**, **Entra ID**, and **Intune** via each script's
`.CATEGORY` header tag (falling back to the numeric prefix: 0x = AD, 1x = Entra, 2x = Intune). The
`.ROLE` header is enforced: helpdesk sees and can run only `HelpDesk`-tagged scripts; admins run
everything. A script that omits these tags defaults to category *Other* and role *HelpDesk*.

---

## 9. Troubleshooting

- **Login 500:** check `data\ldap-debug.log`. Directory-auth failures are now caught and logged
  (no 500). "The supplied credential is invalid" = wrong password or domain qualifier.
- **AD login fails, local admin works:** `ldapEnabled` is false, or the admin group is entered as a
  full DN instead of its CN.
- **Onboarding stuck at `pending-sync`:** the user hasn't synced to Entra yet (wait / force a delta
  sync). Confirm the create OU is in the sync scope.
- **Onboarding `manual-needed`:** mail-enabled groups and EXO isn't configured - set up
  PSConsole-EXO-Write, or add those members by hand.
- **Veeam "Could not reach Veeam: ... Access is denied":** the query account (the service account when
  no `-Username` is set) can't WinRM into the Veeam server. Configure a dedicated reader with
  `Set-VeeamConfig.ps1 -Username DOMAIN\svc-veeamread` and grant it remote WinRM + the Veeam Backup Viewer
  role there. Other "Could not reach Veeam" causes: `pwsh 7` isn't installed on the Veeam server, or the
  account lacks Veeam read rights. The page always shows the exact underlying error.
- **Veeam "Failed to connect to Identity service":** despite the wording this is **not** an auth or
  network failure - it's the per-user certificate-trust prompt (Veeam 12.1+) that can't be answered
  non-interactively. Run `graph-setup\Set-VeeamTrust.ps1` once to accept the Veeam server's certificate on
  the query account's behalf, then reload the page. (Verify from the Veeam server that the account is not
  simply missing the Backup Viewer role or remote WinRM first.)
- **Scheduled report didn't send:** SMTP not configured, no recipients, or the report is disabled. Use
  **Run now** to test; the result banner reports the row count and any email error.
- **Intune category missing / Intune script won't run:** the add-on isn't enabled - run
  `graph-setup\Set-IntuneConfig.ps1` and restart. If it's enabled but scripts error with an auth/permission
  message, the three `DeviceManagement*.Read.All` application permissions aren't consented on the Graph app
  yet (see 8c). Intune scripts are admin-only, so they never appear for helpdesk.
- **Site frozen:** see section 2.

---

## 10. Rebuilding on a new server

1. Install prerequisites: Windows Server, PowerShell 5.1, and the Pode module (vendored in
   `modules\Pode`, or `Install-Module Pode`). Install `ExchangeOnlineManagement` if using EXO.
2. Copy the repo's `psconsole\` contents to `E:\apps\PSConsole` (or the versioned zip).
3. Install a TLS cert; note its thumbprint. Register the WinSW service (`service\PSConsole.xml`) with
   the port + cert thumbprint. Grant `zpsconsole` "Log on as a service".
4. **Create `data\`** (gitignored, so not in the repo). The fastest path is the guided first-run
   script from the install root: **`.\Setup-PSConsole.ps1`** - it creates the local admin login and
   writes `config.json` + `provision.json` (backing up any existing files). Then finish the pieces it
   points you to:
   - **Re-run the credential helpers on the new box** to create `graph.config.json`,
     `graph-write.config.json`, `exo.config.json` - the DPAPI secrets are machine-bound and will
     **not** decrypt if copied from the old server. For EXO, install the cert + grant key access.
   - Install/replace the TLS cert with `graph-setup\Set-TlsCertificate.ps1` (step 3).
   - Finish the department map in the app (Config > Department mapping), then flip provisioning on.
5. `Start-Service PSConsole`; verify port 443 and log in.
