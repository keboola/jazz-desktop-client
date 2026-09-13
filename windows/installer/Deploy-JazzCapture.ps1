<#
.SYNOPSIS
    Per-user Intune / GPO install of Jazz Capture with --capture-at-launch and device-bundle intake.

.DESCRIPTION
    Run in the **logged-on user's** context (Intune Win32: Install behavior = User). Do not run as SYSTEM.

    The MSI does not bake --capture-at-launch or the device bundle (secrets must not live in the
    package). This script:

      1. Installs the per-user MSI if -MsiPath is given (msiexec /i ... /qb)
      2. Points HKCU Run at JazzCapture.exe --capture-at-launch (and optional HKCU policy DWORD)
      3. Copies the company device-bundle.json to
         %LOCALAPPDATA%\Jazz\provisioning\device-bundle.json with a current-user-only ACL
      4. Starts Jazz if it is not already running

    The real bundle is never committed. Pass -BundlePath at deploy time from Intune Win32 source
    content or a company secret store.

    If the JSON arrives later while Jazz is already running, intake keeps retrying (backoff up to
    60s) after success or a hard refusal, so a new drop is consumed without a restart. Jazz wipes
    the JSON after a successful (or refused) consume.

.PARAMETER MsiPath
    Path to JazzCapture-*-win-x64-unsigned.msi. Skip if the MSI is already installed.

.PARAMETER BundlePath
    Path to the filled company device-bundle.json (same file on every PC).

.PARAMETER ExePath
    Override for JazzCapture.exe. Default: %LOCALAPPDATA%\Jazz\App\JazzCapture.exe

.PARAMETER StartNow
    Start Jazz after configuring (default: on).

.EXAMPLE
    pwsh -File Deploy-JazzCapture.ps1 -MsiPath .\JazzCapture-0.26.5-win-x64-unsigned.msi -BundlePath .\device-bundle.json
#>
[CmdletBinding()]
param(
    [string] $MsiPath,
    [string] $BundlePath,
    [string] $ExePath,
    [switch] $StartNow = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$jazzRoot = Join-Path $localAppData 'Jazz'
$appDir = Join-Path $jazzRoot 'App'
$provisionDir = Join-Path $jazzRoot 'provisioning'
$destBundle = Join-Path $provisionDir 'device-bundle.json'
if (-not $ExePath) {
    $ExePath = Join-Path $appDir 'JazzCapture.exe'
}

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'JazzCapture'
$policyKey = 'HKCU:\Software\Keboola\Jazz\Policy'
$captureFlag = '--capture-at-launch'

function Protect-CurrentUserFile([string] $Path) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if (-not $id) { throw 'Current user SID is unavailable.' }
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('SYSTEM', 'FullControl', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

if ($MsiPath) {
    if (-not (Test-Path -LiteralPath $MsiPath)) { throw "MSI not found: $MsiPath" }
    $msi = (Resolve-Path -LiteralPath $MsiPath).Path
    Write-Host "Installing $msi (per-user, no elevation)"
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi, '/qb', '/norestart') -Wait -PassThru
    if ($p.ExitCode -notin 0, 1641, 3010) {
        throw "msiexec exited $($p.ExitCode)"
    }
}

if (-not (Test-Path -LiteralPath $ExePath)) {
    throw "JazzCapture.exe not found at $ExePath. Install the MSI first or pass -ExePath."
}

New-Item -ItemType Directory -Force -Path (Split-Path $runKey) | Out-Null
$runValue = '"{0}" {1}' -f $ExePath, $captureFlag
New-Item -ItemType Directory -Force -Path $runKey | Out-Null
Set-ItemProperty -LiteralPath $runKey -Name $runName -Value $runValue
Write-Host "HKCU Run $runName = $runValue"

New-Item -ItemType Directory -Force -Path $policyKey | Out-Null
New-ItemProperty -LiteralPath $policyKey -Name 'CaptureAtLaunch' -PropertyType DWord -Value 1 -Force | Out-Null
Write-Host "HKCU policy CaptureAtLaunch = 1"

if ($BundlePath) {
    if (-not (Test-Path -LiteralPath $BundlePath)) { throw "Bundle not found: $BundlePath" }
    New-Item -ItemType Directory -Force -Path $provisionDir | Out-Null
    Copy-Item -LiteralPath $BundlePath -Destination $destBundle -Force
    Protect-CurrentUserFile $destBundle
    Write-Host "Bundle copied to provisioning (ACL = current user + SYSTEM). Jazz will consume and delete it."
}
else {
    Write-Host "No -BundlePath. Drop device-bundle.json later at $destBundle (current-user ACL)."
}

if ($StartNow) {
    $running = Get-Process -Name JazzCapture -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host "JazzCapture already running (PID $($running.Id -join ',')). New Run flag applies at next start; a new bundle is retried if intake is still waiting."
    }
    else {
        Start-Process -FilePath $ExePath -ArgumentList $captureFlag
        Write-Host "Started JazzCapture $captureFlag"
    }
}
