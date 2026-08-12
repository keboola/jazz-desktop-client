<#
.SYNOPSIS
    Builds the per-user Jazz Capture MSI on Windows.

.DESCRIPTION
    The one documented command for producing the installer on a Windows machine or runner:

        pwsh windows/installer/build-msi.ps1

    It publishes the tray host self-contained for win-x64, then compiles the WiX v6 authoring in
    Package.wxs around that payload. Both steps write under windows/installer/artifacts/, so the
    tree is left clean apart from that one ignored directory, and the finished package always lands
    at the same path whether it was built here or by the `wixl` script for macOS/Linux.

    The MSI is NOT code signed. There is no certificate for this client, so Windows SmartScreen and
    Defender will warn the first time it is run. That is expected, not a symptom of a broken build.

.PARAMETER Configuration
    Build configuration for the payload. Release unless you are debugging the host itself.

.PARAMETER SkipPublish
    Reuse the payload already in artifacts/publish/win-x64 instead of republishing it. Useful when
    iterating on the WiX authoring, which takes seconds against a publish that takes minutes.
#>
[CmdletBinding()]
param(
    [string] $Configuration = 'Release',
    [switch] $SkipPublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installerDir = $PSScriptRoot
$windowsDir = Split-Path -Parent $installerDir
$artifactsDir = Join-Path $installerDir 'artifacts'
$publishDir = Join-Path $artifactsDir 'publish\win-x64'
$trayProject = Join-Path $windowsDir 'Sources\JazzCapture\JazzCapture.csproj'
$wixProject = Join-Path $installerDir 'Jazz.Installer.wixproj'

if (-not $SkipPublish) {
    Write-Host "==> Publishing the self-contained win-x64 tray host"
    if (Test-Path $publishDir) {
        # A publish into a dirty directory keeps files that a previous build produced and this one
        # does not, and the MSI would ship them.
        Remove-Item -Recurse -Force $publishDir
    }

    # SatelliteResourceLanguages trims the WPF framework's translated resource assemblies. The
    # client's own UI is English only, so the thirteen culture directories are payload nobody reads.
    dotnet publish $trayProject `
        --configuration $Configuration `
        --runtime win-x64 `
        --self-contained true `
        -p:SatelliteResourceLanguages=en `
        --output $publishDir `
        --nologo
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }
}

Write-Host "==> Building the per-user MSI"
dotnet build $wixProject `
    --configuration $Configuration `
    -p:PublishDir=$publishDir `
    --nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet build of the WiX project failed with exit code $LASTEXITCODE" }

$msi = Join-Path $artifactsDir 'Jazz.msi'
if (-not (Test-Path $msi)) {
    # The WiX SDK derives OutputPath the way the .NET SDK does, and a future version could put the
    # package under bin\Release\ regardless of what the project asks for. Rather than let the
    # canonical path silently stop existing, find what was built and put it where both the CI
    # upload and Verify-Msi.ps1 expect it.
    $built = @(Get-ChildItem -Path $installerDir -Filter 'Jazz.msi' -Recurse -File |
        Where-Object { $_.FullName -notlike "$publishDir*" } |
        Sort-Object LastWriteTime -Descending)
    if ($built.Count -eq 0) { throw "The WiX build reported success but produced no package under $installerDir" }
    Write-Host "==> The package was built at $($built[0].FullName); copying it to $msi"
    Copy-Item -Path $built[0].FullName -Destination $msi -Force
}

$sizeMb = [math]::Round((Get-Item $msi).Length / 1MB, 1)
Write-Host "==> $msi ($sizeMb MB, unsigned)"
