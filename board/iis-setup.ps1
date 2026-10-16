#Requires -RunAsAdministrator
<#
GUIDE SDD stage board as an IIS site: the ASP.NET Core Module v2 (out-of-process) launches serve.mjs
under node and proxies to it; the site binds 127.0.0.1 only and runs always. Idempotent; -Remove undoes it.
  powershell -NoProfile -ExecutionPolicy Bypass -File sdd\board\iis-setup.ps1 [-SiteName GuideBoard] [-Port 8780] [-SitePath C:\inetpub\guide-board] [-Remove]
Use Windows PowerShell: the WebAdministration IIS: drive is unreliable under pwsh 7.
Needs IIS, the .NET Hosting Bundle (AspNetCoreModuleV2) and node on PATH. The app pool identity gets
read on the spine and modify on exactly the directories `node board.mjs paths` names (board file,
backlog, meta) - nothing else in the repo.
#>
param(
    [string]$SiteName = 'GuideBoard',
    [int]$Port = 8780,
    [string]$SitePath = 'C:\inetpub\guide-board',
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'

$boardDir = $PSScriptRoot
$logDir   = Join-Path $SitePath 'logs'
$identity = "IIS AppPool\$SiteName"

function New-BoardWebConfig([string]$NodePath, [string]$ServePath) {
    $esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
    $proc = & $esc $NodePath
    # --preserve-symlinks(-main): node otherwise lstat()s every folder up the script path, and the app
    # pool identity may not read C:\Users\<user> attributes (EPERM at startup).
    $arg = & $esc ('--preserve-symlinks --preserve-symlinks-main "' + $ServePath + '"')
    @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
    </handlers>
    <aspNetCore processPath="$proc" arguments="$arg" hostingModel="OutOfProcess" stdoutLogEnabled="true" stdoutLogFile=".\logs\stdout" requestTimeout="23:00:00" startupTimeLimit="30" />
    <urlCompression doStaticCompression="false" doDynamicCompression="false" />
  </system.webServer>
</configuration>
"@
}

try { Import-Module WebAdministration -ErrorAction Stop }
catch { Write-Error "WebAdministration module unavailable (install IIS Management Scripts and Tools): $_"; exit 1 }

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd -and -not $Remove) { Write-Error 'node not found on PATH.'; exit 1 }

# (path, perm) grants in one place, so setup and -Remove stay in step.
$grants = @(@{ Path = $SitePath; Perm = 'RX' }, @{ Path = $logDir; Perm = 'M' })
if ($nodeCmd) {
    $p = & $nodeCmd.Source (Join-Path $boardDir 'board.mjs') paths | ConvertFrom-Json
    if (-not $p -or -not $p.read) { Write-Error 'board.mjs paths failed - is board.file set in gates.config.json?'; exit 1 }
    foreach ($r in $p.read)  { $grants += @{ Path = $r; Perm = 'RX' } }
    foreach ($w in $p.write) { $grants += @{ Path = $w; Perm = 'M' } }
}

if ($Remove) {
    if (Test-Path "IIS:\Sites\$SiteName") {
        if ((Get-WebsiteState -Name $SiteName).Value -ne 'Stopped') { Stop-Website -Name $SiteName }
        Remove-Website -Name $SiteName; Write-Host "removed site $SiteName"
    } else { Write-Host "site $SiteName not present" }
    if (Test-Path "IIS:\AppPools\$SiteName") {
        if ((Get-WebAppPoolState -Name $SiteName).Value -ne 'Stopped') { Stop-WebAppPool -Name $SiteName }
        Remove-WebAppPool -Name $SiteName; Write-Host "removed app pool $SiteName"
    } else { Write-Host "app pool $SiteName not present" }
    foreach ($g in $grants) {
        if (Test-Path $g.Path) { icacls $g.Path /remove $identity | Out-Null; Write-Host "removed ACL grant on $($g.Path)" }
    }
    if (Test-Path $SitePath) { Remove-Item -Recurse -Force $SitePath; Write-Host "deleted $SitePath" }
    exit 0
}

# --- preflight ---
if (-not (Get-WebGlobalModule -Name AspNetCoreModuleV2 -ErrorAction SilentlyContinue)) {
    Write-Error 'ASP.NET Core Module v2 is not registered in IIS. Install the .NET Hosting Bundle, then rerun.'; exit 1
}
$servePath = Join-Path $boardDir 'serve.mjs'
$ownSite = (Test-Path "IIS:\Sites\$SiteName")
if (-not $ownSite) {
    $inUse = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($inUse) { Write-Error "port $Port is already in use (pid $(($inUse | Select-Object -First 1).OwningProcess))."; exit 1 }
}
Write-Host "preflight ok (node $($nodeCmd.Source))"

# --- site folder + web.config ---
New-Item -ItemType Directory -Force -Path $SitePath, $logDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $SitePath 'web.config'), (New-BoardWebConfig $nodeCmd.Source $servePath), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "wrote $SitePath\web.config"

# --- app pool: no managed runtime, always running, never idles out ---
if (-not (Test-Path "IIS:\AppPools\$SiteName")) { New-WebAppPool -Name $SiteName | Out-Null; Write-Host "created app pool $SiteName" }
$poolPath = "IIS:\AppPools\$SiteName"
Set-ItemProperty $poolPath -Name managedRuntimeVersion -Value ''
Set-ItemProperty $poolPath -Name startMode -Value 'AlwaysRunning'
Set-ItemProperty $poolPath -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
Set-ItemProperty $poolPath -Name processModel.identityType -Value 'ApplicationPoolIdentity'

# --- site (loopback only) ---
$bindingInfo = "127.0.0.1:${Port}:"
if (-not $ownSite) {
    New-Website -Name $SiteName -PhysicalPath $SitePath -ApplicationPool $SiteName -Port $Port -IPAddress '127.0.0.1' -HostHeader '' | Out-Null
    Write-Host "created site $SiteName on $bindingInfo"
} else {
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $SitePath
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $SiteName
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name bindings -Value @{ protocol = 'http'; bindingInformation = $bindingInfo }
    Write-Host "site $SiteName exists, updated ($bindingInfo)"
}
Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationDefaults.preloadEnabled -Value $true

# --- ACLs ---
foreach ($g in $grants) {
    New-Item -ItemType Directory -Force -Path $g.Path | Out-Null
    icacls $g.Path /grant "${identity}:(OI)(CI)$($g.Perm)" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "icacls failed on $($g.Path)"; exit 1 }
    Write-Host "granted $($g.Perm) on $($g.Path)"
}

# --- start + probe ---
if ((Get-WebAppPoolState -Name $SiteName).Value -ne 'Started') { Start-WebAppPool -Name $SiteName }
if ((Get-WebsiteState -Name $SiteName).Value -ne 'Started') { Start-Website -Name $SiteName }
$deadline = (Get-Date).AddSeconds(20)
$resp = $null
while ((Get-Date) -lt $deadline) {
    try { $resp = Invoke-WebRequest "http://127.0.0.1:$Port/api/state" -UseBasicParsing -TimeoutSec 5; break }
    catch { Start-Sleep -Milliseconds 1000 }
}
if ($resp -and $resp.StatusCode -eq 200) { Write-Host "board: http://127.0.0.1:$Port"; exit 0 }
Write-Host "board did not answer on http://127.0.0.1:$Port/api/state within 20 s" -ForegroundColor Red
$log = Get-ChildItem $logDir -Filter 'stdout*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) { Write-Host "--- last 40 lines of $($log.FullName) ---"; Get-Content $log.FullName -Tail 40 }
exit 1
