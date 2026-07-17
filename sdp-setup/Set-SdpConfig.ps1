<#
.SYNOPSIS
    Configure the PSConsole ServiceDesk Plus (read-only reporting) add-on. Run ON the PSConsole host.

.DESCRIPTION
    Writes data\sdp.config.json. Default auth is Windows Integrated (PSConsole connects as its own service
    account, zpsconsole) - no secret is stored. Pass -Username to use a dedicated SQL login instead; the
    password is prompted (SecureString) and DPAPI-encrypted at LocalMachine scope.

    The connecting principal needs only db_datareader on the SDP database (grant script: see the add-on
    notes / your DBA). Reporting is strictly read-only - PSConsole never writes to the live desk DB.

    -Test does a basic connectivity + version check AS WHOEVER RUNS THIS SCRIPT. For Integrated auth the
    definitive check is that zpsconsole can read, which shows up when you open a Service Desk report in the
    app (that runs as the service account) - this -Test only confirms the server/db/firewall are reachable.

.EXAMPLE
    .\Set-SdpConfig.ps1 -Server 'SQLHOST\SDP' -Database 'servicedesk' -Test
    # Integrated auth (recommended); test reachability

.EXAMPLE
    .\Set-SdpConfig.ps1 -Server 'SQLHOST,1433' -Database 'servicedesk' -Username 'psc_sdpread'
    # dedicated SQL login; prompts for the password, DPAPI-encrypts it

.EXAMPLE
    .\Set-SdpConfig.ps1 -Disable        # keep the config but turn the add-on off
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$Database,
    [string]$Username,                       # omit for Windows Integrated auth (no stored secret)
    [bool]$Encrypt = $true,
    [bool]$TrustServerCertificate = $true,   # true = accept the SQL server's self-signed cert (typical internal)
    [switch]$Test,
    [switch]$Disable,
    [string]$OutFile = (Join-Path $PSScriptRoot '..\data\sdp.config.json')
)
$OutFile = [IO.Path]::GetFullPath($OutFile)

if ($Disable) {
    if (-not (Test-Path $OutFile)) { throw "No config at $OutFile to disable." }
    $c = Get-Content $OutFile -Raw | ConvertFrom-Json
    $c.enabled = $false
    $c | ConvertTo-Json -Depth 6 | Set-Content $OutFile -Encoding UTF8
    Write-Host 'ServiceDesk Plus add-on disabled (config kept).' -ForegroundColor Yellow
    return
}

if (-not $Server -or -not $Database) { throw 'Both -Server and -Database are required.' }

$cfg = [ordered]@{
    enabled  = $true
    server   = $Server
    database = $Database
    encrypt  = $Encrypt
    trustServerCertificate = $TrustServerCertificate
}
if ($Username) {
    $sec  = Read-Host -AsSecureString "SQL password for '$Username'"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ([string]::IsNullOrWhiteSpace($pw)) { throw 'No password entered.' }
    try { Add-Type -AssemblyName System.Security } catch {}
    $cfg['username'] = $Username
    $cfg['secret']   = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($pw), $null, 'LocalMachine'))
    $pw = $null
}

if ($Test) {
    Write-Host "Testing connectivity to [$Server].[$Database] as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) ..." -ForegroundColor Cyan
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Server'] = $Server; $b['Database'] = $Database; $b['Application Name'] = 'PSConsole-SDP'; $b['Connect Timeout'] = 15
    if ($Username) { $b['User ID'] = $Username; $b['Password'] = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))) } else { $b['Integrated Security'] = $true }
    $b['Encrypt'] = $Encrypt; $b['TrustServerCertificate'] = $TrustServerCertificate
    $conn = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand(); $cmd.CommandText = 'SELECT @@VERSION AS v, DB_NAME() AS db'
        $rdr = $cmd.ExecuteReader(); [void]$rdr.Read()
        Write-Host "  Connected. DB: $($rdr['db'])" -ForegroundColor Green
        Write-Host "  $((($rdr['v'] -split "`n")[0]).Trim())" -ForegroundColor Gray
        $rdr.Close()
    } catch { throw "Connection test FAILED: $($_.Exception.Message)" } finally { $conn.Dispose() }
}

([pscustomobject]$cfg) | ConvertTo-Json -Depth 6 | Set-Content $OutFile -Encoding UTF8
Write-Host "Wrote $OutFile" -ForegroundColor Green
Write-Host "The 'Service Desk' category appears on the Run page for admins once report scripts are added." -ForegroundColor Cyan
