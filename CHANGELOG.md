# Changelog

All notable changes to PSConsole. Versions follow the `VERSION` file.

## [1.8.0] - 2026-07-10

### Added
- **Veeam report export & email.** The Veeam page now has **Export CSV** (downloads the current view — the
  all-jobs summary, or a selected job's runs) and **Email** (sends that view to an address, via the existing
  results-email path; requires SMTP). Both work client-side off the already-rendered data, so there's no
  second query.
- **Schedulable Veeam status report.** New catalog script `30-Get-VeeamJobStatus.ps1` (admin-only, **Veeam**
  category, `-Days` window) — one row per job with last result plus success/warning/failure counts. Pick it on
  the **Reports** tab to email Veeam status on a daily/weekly schedule. Hidden until the Veeam add-on is
  configured: the Run/Reports catalog now has a **Veeam** group with a `Test-VeeamConfigured` gate (mirrors Intune).
- **`graph-setup\Set-VeeamTrust.ps1`** — one-time helper that makes the Veeam query account trust the backup
  server's self-signed Identity-service certificate (see Fixed, below).

### Changed
- **Veeam add-on no longer needs CredSSP.** The query connects to the Veeam server's own (localhost) services,
  so plain Kerberos is sufficient; `-UseCredSsp` on `Set-VeeamConfig.ps1` is kept only for rare onward-hop
  scenarios and its help no longer claims it fixes the Identity-service error.

### Fixed
- **Veeam "Failed to connect to Identity service" (service account).** Not an auth or network failure — it's
  Veeam 12.1's per-user certificate-trust prompt, which cannot be answered non-interactively. The add-on now
  works for a non-interactive service account once trust is established with `Set-VeeamTrust.ps1` (run once;
  re-run only if the Veeam certificate is regenerated). Documented in ADMIN-GUIDE §8b + troubleshooting.
- **Admin pages could intermittently time out (HTTP 408) on slow queries.** Pode's default 30s request timeout
  raced the Veeam "all jobs" query (~30s for the 30/60/90-day windows). Added `app\web\server.psd1` raising the
  request timeout to 120s so slow admin queries complete; normal pages (login, dashboard, run) are unaffected.

## [1.7.0] - 2026-07-10

### Added
- **Intune reporting** (**optional add-on**) — 8 read-only Microsoft Graph reports under a new **Intune**
  category on the Run-scripts page: managed-device inventory, non-compliant devices, stale devices,
  compliance summary, encryption status, connector status board (Exchange / NDES / Managed Google Play /
  MTD / partners), Apple token expirations (APNs push cert + VPP + ADE/DEP), and Windows Autopilot.
  Available to helpdesk and admin. Reuses the existing Entra Graph app registration — needs these
  application permissions added + admin consent: `DeviceManagementManagedDevices.Read.All`,
  `DeviceManagementConfiguration.Read.All`, `DeviceManagementServiceConfig.Read.All`. Gated by
  `data\intune.config.json` (`graph-setup\Set-IntuneConfig.ps1`); ships dormant until enabled. Verified
  against a live Intune tenant.
- **Run-scripts page grouped by category.** Scripts are now organised into **Active Directory**,
  **Entra ID**, and **Intune** groups (via a `.CATEGORY` header tag, with a numeric-prefix fallback), so
  the catalog stays navigable as it grows. Applies to the scheduled-reports script picker too.
- **Veeam per-job view.** The Veeam page now has a **job selector** — pick a job to see its individual
  runs (end time, result, duration) over the window, or keep "All jobs" for the existing per-job
  last-result + aggregate success/warning/failure view. Window options are now **7 / 30 / 60 / 90 days**.

### Changed
- **`.ROLE` is now enforced**, not just documentation. The Run page shows helpdesk only `HelpDesk`-tagged
  scripts (admins see everything), and the `/run` route rejects out-of-role or disabled-add-on scripts
  server-side (403), not just by hiding them. The Intune scripts are tagged `HelpDesk`, so helpdesk and
  admin both get the Intune group (still gated by the add-on); Veeam remains admin-only.

### Fixed
- **User creation now reports a bad operator credential clearly.** An invalid operator AD username/password
  no longer surfaces the cryptic "You cannot call a method on a null-valued expression"; `New-OnPremUser`
  detects the failed bind and returns an actionable message (enter your own AD credentials, confirm the OU).

## [1.6.0] - 2026-07-09

### Added
- **Scheduled reports** (standard, admin-only) — new **Reports** tab. Define a report that runs a
  catalog script on a schedule (daily/weekly/monthly at a chosen time, optional `Name=Value` params)
  and emails the result as an HTML table to a recipient list. Includes enable/disable, **Run now**, and
  delete. A dispatcher (`Invoke-DueReports`, `app/lib/Reports.ps1`) fires every 15 min and sends any
  report whose scheduled time has passed for its current occurrence (tracked via `lastRun`). Requires
  SMTP configured (`Set-SmtpConfig.ps1`); the page warns if it isn't.
- **Veeam backup reports** (admin-only, **optional add-on**) — new **Veeam** tab, shown only when
  `data\veeam.config.json` is present and enabled. Two read-only views: **last backup result per job**
  and **success/warning/failure counts** over a selectable window (7/30/90 days). Queries Veeam Backup
  & Replication over PowerShell remoting into the Veeam server (`app/lib/Veeam.ps1`), so this host needs
  no Veeam console; bounded WinRM timeout, graceful failure. Configure with
  `graph-setup\Set-VeeamConfig.ps1` (optional DPAPI-stored credential; otherwise the service account).
- New RBAC actions `manage-reports` and `veeam-reports` (admin-only by default-deny). Nav icons for both.

### Notes
- The Veeam layer is verified against a live B&R 12 server. Last-run uses `Get-VBRJob` +
  `FindLastSession()`; history uses the per-job session store — both fast (~30s page load). The
  unfiltered `Get-VBRBackupSession` is deliberately avoided (minutes on busy servers).
- The query runs as the PSConsole service account unless `-Username` is set; a separate backup server
  will usually deny that account WinRM ("Access is denied"). Configure a dedicated reader credential and
  grant it remote WinRM + the Veeam Backup Viewer role. See ADMIN-GUIDE §8b.

## [1.5.1] - 2026-07-09

### Changed
- **Dashboard is now the default landing** after sign-in for both admin and helpdesk (login redirects
  to `/dashboard` instead of the Run page). Run Scripts remains its own tab at `/`.
- **Dashboard "Passwords expiring within 7 days" now excludes already-expired accounts** (shows only
  positive days-left). Already-expired users still appear when `02-Get-PasswordsExpiring.ps1` is run
  manually from the Run page - the filter is dashboard-only.

## [1.5.0] - 2026-07-09

### Changed
- **Helpdesk access broadened.** Helpdesk now sees every left-nav tab **except Config and Audit**:
  Dashboard, Run Scripts, Create User, Onboarding, Decommission. RBAC updated to match - helpdesk gains
  `create-user` (covers Create + Onboarding) and now reaches the Dashboard; it still has **no**
  `view-history` (Audit) or `configure` (Config), so those stay admin-only and are blocked at the route,
  not just hidden.
- **Role-aware Dashboard.** Admins keep the "Recent activity" (audit) panel. Helpdesk instead get two
  read-only panels: **Passwords expiring within 7 days** (`02-Get-PasswordsExpiring.ps1`) and **Recent
  failed Entra sign-ins (last 10)** (`18-Get-EntraSignInFailures.ps1`). The summary cards (onboarding
  queue, script count, quick actions) stay for both. Widgets render server-side with a short timeout and
  degrade gracefully (e.g. if the Graph read app isn't configured); viewing the dashboard writes no audit
  record.

### Fixed
- The Entra report scripts (10-19) pointed to a non-existent `Set-GraphCredentials.ps1` in their
  "Graph config not found" error; corrected to `Set-GraphCredential.ps1` (the helper added in 1.4.0).

## [1.4.0] - 2026-07-09

UI facelift toward a PowerShell-Universal-style look: a light/dark theme with a persistent toggle and
a left sidebar shell applied across every page. No functional/security changes - routes, RBAC, and the
read-only service-account model are unchanged.

### Added
- **Left sidebar navigation shell** on every authenticated page (Run, Dashboard, Create User,
  Onboarding, Decommission, Config, Audit). Nav items gate by role: helpdesk sees Run + Decommission;
  admin sees all. A top bar shows the page title/subtitle, signed-in user, theme toggle, and sign-out.
- **Light / dark theme toggle.** Persists in `localStorage['psc-theme']`; an inline head script applies
  the saved theme before first paint (no flash). All colors are CSS variables under `:root` /
  `html[data-theme="dark"]`.
- **Admin Dashboard** (`GET /dashboard`): onboarding-queue count, script count, quick actions, and a
  recent-activity table.
- `app/lib/Layout.ps1` - the chrome engine: `Get-AppChrome` (composed in each route, returns
  `head`/`open`/`close`), `Get-AppStyles`, `Get-LoginHead`, and an ASCII-only inline-SVG icon set.
- **`graph-setup/Set-TlsCertificate.ps1`** - guided helper to add/replace the site's TLS certificate
  without editing code: optionally imports a `.pfx`, validates it (private key, expiry, hostname/SAN),
  grants the service account read on the private key, sets `certThumbprint`, restarts the service, and
  verifies the served cert. Documented under *ADMIN-GUIDE - Replacing the TLS certificate*.
- **`Setup-PSConsole.ps1`** - guided first-run setup at the install root. Creates the local admin login
  (PBKDF2, same scheme as the app), and writes `config.json` (AD/LDAP auth + role groups + optional cert
  thumbprint) and `provision.json` (UPN suffix + disabled OU + a safe `enabled:false` skeleton), backing
  up any existing files. Points to the remaining helpers (cert, cloud, EXO, SMTP, service).
- **`graph-setup/Set-GraphCredential.ps1`** - the previously-missing helper for the Graph **read** app
  (`graph.config.json`), mirroring the write/EXO/SMTP helpers (DPAPI LocalMachine, prompts for the secret,
  verifies the decrypt round-trips).
- **Distribution scrubbing** (`tools/Get-DistScrub.ps1`, `tools/Build-DistZip.ps1`): shipped artifacts
  (the dist zip and the repo publish) now pass text files through a scrubber that replaces this org's
  real domain/host names with generic placeholders, so new users on another domain never see them. The
  working tree keeps real values (it's the live install + the admin runbook). `Build-DistZip.ps1` and
  `Publish-ToRepo.ps1` both fail-closed on a post-scrub leak gate; `Publish-ToRepo.ps1 -NoScrub` opts
  out. `data/` (real config + secrets) is excluded from both, as before.

### Changed
- All views (`login`, `dashboard`, `admin-dashboard`, `user-new`, `user-decommission`, `onboarding`,
  `config`, `deptmap`) rewritten to wrap their content in the shared shell + `.card` components and
  shared CSS classes; per-page inline `<style>` blocks removed.
- **Audit log** now sorts newest-first and adds a **date/time range filter** (`GET /admin/audit`
  accepts `from`/`to`; `Get-AuditRange`). Timestamps display as `MM/DD/YYYY h:mm AM/PM`.

### Fixed
- Top-bar theme/sign-out button text is now readable in light mode (top bar stays dark, so those
  buttons use a fixed light text color).
- Email-results now renders the actual result rows as an HTML table instead of array metadata
  (`Count`/`Length`/...): the parsed JSON is captured to a variable before `@()` to avoid WinPS 5.1
  non-enumerated-array wrapping.
- Removed mojibake in the theme button by keeping `Layout.ps1` ASCII-only (WinPS reads `.ps1` source
  as ANSI); the theme button uses an inline SVG + text label.

## [1.3.1] - 2026-07-09

### Changed
- **Per-event notification recipients.** `smtp.config.json` now supports `createTo` (user-created
  emails) and `decommissionTo` (user-decommissioned emails), each falling back to the general `to`
  list when empty. `Notify.ps1` gains `Get-NotifyRecipients`; `Set-SmtpConfig.ps1` gains `-CreateTo`
  and `-DecommissionTo`.

## [1.3.0] - 2026-07-08

Adds user **decommissioning** and **email notifications**, takes provisioning **live**, and fixes the
onboarding license race, an EXO re-add bug, and a latent JSON-store data-corruption bug. Follows the
first live end-to-end validation of the create + onboarding workflow.

### Added - Decommission user
- **Decommission User** workflow (`GET /users/decommission`, `POST /users/decommission/preview`,
  `POST /users/decommission/run`) available to **helpdesk and admin**: look up an account, confirm
  with a checkbox + the operator's own AD credentials, then disable it, strip its on-prem group
  memberships, and move it to the **Disabled Accounts OU** (`disabledOu`, default
  `OU=Disabled Accounts,DC=example,DC=org`). Moving it out of the sync scope lets ADSync remove it
  from Entra (and cloud groups) automatically - no cloud calls needed.
- `app/lib/Decommission.ps1`: `Find-AdUserForDecomm` (read-only lookup), `Test-DecommPlan` (blocks
  not-found / already-in-Disabled-OU / **protected & admin group members**), `Invoke-Decommission`
  (binds as the operator - `zpsconsole` stays read-only). LDAP filter values are escaped.
- New RBAC action `decommission-user`, granted to helpdesk + admin.

### Added - Email
- `app/lib/Notify.ps1`: SMTP email helper. Configured via `data\smtp.config.json` (helper
  `graph-setup\Set-SmtpConfig.ps1`; supports anonymous/direct-send relay or authenticated/TLS with a
  DPAPI-encrypted password). Best-effort: sending never blocks or fails the triggering action;
  failures go to `data\notify.log`. Inert until configured.
- **Email results** button on the dashboard, next to *Export CSV*: type an address and email the
  current script-run results as an HTML table (`POST /email-results`, run-level permission).
- Optional **create / decommission notifications** to the default recipients in `smtp.config.json`
  (`to`); inert if no default recipients are set.

### Changed
- Provisioning is now **live**: `enabled: true` and `onboardingAutoRun: true` (cloud onboarding runs
  every 5 min). The provisioning master switch also gates decommission (preview-only while off).
- **Audit view** now shows events **newest-first** and adds a **date/time range filter** (From/To);
  filtered queries scan the whole log (`Get-AuditRange`, capped at 2000), unfiltered shows the last 500.

### Fixed
- **Onboarding license race:** the processor set `usageLocation` then assigned the license in the
  same run, before Entra committed it ("invalid usage location"), needing a manual re-run. It now
  retries the license assignment on that specific error while usageLocation propagates.
- **Onboarding EXO groups re-added on every run:** the "already added" check only consulted the Graph
  list, so mail-enabled groups were reprocessed and duplicated in the record. It now also skips
  already-added EXO groups, keeps only genuine failures flagged for manual follow-up, and de-dupes.
- **JSON store data corruption (`Store.ps1`).** Windows PowerShell 5.1 `ConvertTo-Json` serialized a
  single-element collection as a bare object (`{...}`) and an empty collection (via `-InputObject`)
  as a `{"value":[],"Count":0}` wrapper; reading the wrapper back produced a phantom record, and the
  every-5-min onboarding sweep re-corrupted the file each cycle. `Set-Store` now serializes 0/1/many
  elements as proper JSON arrays, and `Get-Store` self-heals any pre-existing wrapper file.

## [1.2.0] - 2026-07-08

Adds the automated **user-provisioning** workflow (on-prem AD create + hybrid Entra onboarding) and
hardens directory login. No breaking changes to existing script-running/RBAC behavior.

### Added - User provisioning
- **Create User** workflow (`GET/POST /users/new`, `/users/new/preview`, `/users/new/create`) with a
  PowerShell-Universal-style form: first/last name, auto-suggested username (first-initial + last
  name convention), department dropdown, per-department **job-title checkboxes**, **supervisor
  dropdown**, and **mobile phone** field. Live preview of the resolved plan before create.
- `app/lib/UserProvision.ps1`: `Get/Set-ProvisionSettings`, `Get-ProvisionPlan` (pure derivation of
  sam/UPN/OU/title/groups), `Test-ProvisionPlan`, `New-OnPremUser` (ADSI create, binds as the
  operator - `zpsconsole` stays read-only), `Add-OnboardingPending`, `Get-Supervisors` (cached).
- `provision.json` mapping schema: `baseGroups`, `onCallGroup` + `onCallExceptDepartments`,
  per-department `ou`/`cloudGroups`/`jobTitles` (each with `addGroups`/`removeGroups`),
  `supervisorGroup`/`supervisorGroups`, `licenseSkuId`, `usageLocation`, `onboardingAutoRun`.
- Checked job title is written to the AD **title** attribute; mobile to **mobile**; supervisor to
  **manager**.
- Department-mapping JSON editor at `/admin/deptmap` (Config -> Department mapping).
- Real department/group/job-title mapping built from the live directory (9 departments; per-title
  group rules for Case Managers and Autism/Behavior Technician).

### Added - Phase 2 cloud onboarding
- `app/lib/Onboarding.ps1`: processor that, once a user has synced to Entra, sets `usageLocation`,
  assigns the license (M365 E5 by SKU), and adds cloud group memberships. Classifies each group and
  handles it correctly: **dynamic** (skip - automatic), **Graph-writable**, **mail-enabled/DL**
  (via EXO). Idempotent; safe to re-run.
- `app/lib/GraphWrite.ps1`: app-only Graph **write** helper (`GroupMember.ReadWrite.All`,
  `User.ReadWrite.All`) - add group member, set usageLocation, assign license.
- `app/lib/ExchangeOnline.ps1`: app-only (certificate) EXO helper using `Add-DistributionGroupMember`
  for mail-enabled security groups and distribution lists.
- `/users/onboarding` admin page + `Run onboarding now`; optional every-5-min auto-processor
  (`onboardingAutoRun`, default off).
- Credential helpers `graph-setup\Set-GraphWriteCredential.ps1` and `Set-ExoConfig.ps1`.

### Added - misc
- `app/lib/Graph.ps1`: shared app-only Graph **read** helper (token caching, paging,
  `Get-EntraGroupUsers`), reused by the web app and scripts.
- `app/scripts/19-Get-EntraGroupMembers.ps1`: list an Entra group's members + job titles
  (group name via the params box; `Group=`/`GroupName=` aliases).
- `docs/ADMIN-GUIDE.md`, this changelog.

### Fixed
- **Directory login 500 / failures.** Explicitly load `System.DirectoryServices.Protocols` in the
  module (Pode route runspaces didn't auto-load it, so the first LDAP call threw a 500). Wrapped
  `Test-LdapCredential` and `Resolve-LdapRole` so directory errors can never surface as a 500.
- **LDAP bind "invalid credential" for `DOMAIN\user`.** `NetworkCredential` now splits the domain
  into its own field (was passed as one string with an empty domain, which Negotiate rejects), with
  a simple/Basic LDAPS bind fallback for UPN/DN. Added `data\ldap-debug.log` for failed-bind reasons.
- **Group OData filters with `&`** (e.g. "Training & Events") corrupted the query string; group-name
  filters are now `[uri]::EscapeDataString`-encoded (Graph.ps1, Onboarding.ps1, script 19).
- **Graph write error handling:** capture the response body (`ErrorDetails.Message`) so idempotent
  cases ("already a member", "already licensed") are recognized and real errors are legible.
- **`Set-Store` couldn't persist empty arrays** (`@() | ConvertTo-Json` -> nothing -> failed
  Move-Item); now writes `[]`.
- Corrected the Clerical mapping group name `Portland Staff` -> `Portland Office`.
- Removed the obsolete read-only "New User" runbook (replaced by the automated workflow).

### Configuration / operational notes
- New app registrations required for provisioning: **PSConsole-Graph-Write** (Graph write) and
  **PSConsole-EXO-Write** (Exchange Online, certificate-based). See the admin guide.
- Enabled AD login (`ldapEnabled`) and set the admin role group to the CN `PSConsole-Admin`.
- Provisioning ships **disabled** (`enabled: false`) - preview-only until AD create-delegation and a
  live test are done.

## [1.1.0] - 2026-06 (previous)
- Stability + fixes baseline (threads/freeze fix, upload fix, logo, Entra reporting scripts 10-18,
  Graph read app). First "clean deployable" package.
