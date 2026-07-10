# PSConsole

A self-hosted PowerShell execution platform for IT / helpdesk teams, built on [Pode](https://github.com/Badgerati/Pode).
It runs curated PowerShell scripts behind a web UI with role-based access, and includes guided AD/Entra
user **provisioning**, **decommissioning**, and cloud **onboarding** workflows. Runs as a Windows service
on Windows PowerShell 5.1.

## Getting started

1. **Unzip / clone** the release onto the server that will host it.
2. **Run the first-run setup** from the install root (creates your admin login and base config):
   ```powershell
   .\Setup-PSConsole.ps1
   ```
   It prompts for a local admin account, your AD/LDAP auth + role groups, and the user-provisioning
   basics, then lists the remaining guided helpers.
3. **Install a TLS certificate** and point the site at it:
   ```powershell
   .\graph-setup\Set-TlsCertificate.ps1 -PfxPath C:\path\to\cert.pfx -Hostname psconsole.example.org
   ```
4. **Register the Windows service** (`service\PSConsole.xml` via WinSW) or run `app\Start-PSConsole.ps1`,
   then browse to `https://<your-host>` and sign in with the admin account from step 2.
5. **Optional cloud features** (dashboards, onboarding, email) — configure the app registrations with the
   helpers in `graph-setup\`: `Set-GraphCredential.ps1` (read), `Set-GraphWriteCredential.ps1` (write),
   `Set-ExoConfig.ps1` (Exchange Online), `Set-SmtpConfig.ps1` (notifications).
6. **Finish provisioning setup** in the app under **Config > Department mapping**, then turn provisioning on.


## Requirements

- Windows Server with **Windows PowerShell 5.1**
- The **Pode** module (vendored under `modules\Pode`, or `Install-Module Pode`)
- `ExchangeOnlineManagement` only if you use the Exchange Online integration

## Documentation

See **[docs/ADMIN-GUIDE.md](docs/ADMIN-GUIDE.md)** for hosting, the data/secrets layout, the security
model (read-only service account, per-request operator credentials), cloud app registrations, and
rebuilding on a new server.

## Security model (brief)

Script execution runs as the service account's own (read-only) AD rights. Write actions — creating or
decommissioning users — require the operator's **own** credentials, entered per request and never stored.
Secrets under `data\` are DPAPI-encrypted (LocalMachine) and are excluded from distribution.
