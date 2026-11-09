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

# A candidate is promoted as these exact bytes, never rebuilt at release time. Keep the historic
# Jazz.msi convenience path for local verifier tooling, but emit the versioned delivery triplet.
$version = (dotnet msbuild (Join-Path $installerDir 'Jazz.Version.props') -getProperty:JazzProductVersion -nologo).Trim()
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^\d+\.\d+\.\d+$') { throw 'Could not read canonical product version.' }
$candidate = Join-Path $artifactsDir "JazzCapture-$version-win-x64-unsigned.msi"
Copy-Item -LiteralPath $msi -Destination $candidate -Force
$hash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
$length = (Get-Item -LiteralPath $candidate).Length
$commit = $env:GITHUB_SHA
if ([string]::IsNullOrWhiteSpace($commit)) {
    $commit = (git -C (Split-Path -Parent $windowsDir) rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the candidate source commit.' }
}
if ($commit -notmatch '^[0-9a-f]{40}$') { throw 'Candidate source commit is not a full lowercase SHA.' }
$workflowRun = if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) { '0' } else { $env:GITHUB_RUN_ID }
$workflowAttempt = if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ATTEMPT)) { '0' } else { $env:GITHUB_RUN_ATTEMPT }
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $null
$summary = $null
try {
    $database = $installer.OpenDatabase($candidate, 0)
    $summary = $database.SummaryInformation(0)
    $packageCode = [string]$summary.Property(9)
    if ($packageCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw 'Candidate MSI has no valid PackageCode.' }
} finally {
    if ($null -ne $summary) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
    if ($null -ne $database) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
}
Set-Content -LiteralPath "$candidate.sha256" -Value "$hash  $([IO.Path]::GetFileName($candidate))" -NoNewline
$manifest = [ordered]@{
    schema = 1; version = $version; filename = [IO.Path]::GetFileName($candidate); byteLength = $length
    sha256 = $hash; productCode = (dotnet msbuild (Join-Path $installerDir 'Jazz.Version.props') -getProperty:JazzProductCode -nologo).Trim()
    upgradeCode = (dotnet msbuild (Join-Path $installerDir 'Jazz.Version.props') -getProperty:JazzUpgradeCode -nologo).Trim()
    packageCode = $packageCode; productVersion = $version; unsigned = $true; commit = $commit; workflowRun = $workflowRun; workflowAttempt = $workflowAttempt
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath "$candidate.manifest.json" -NoNewline
Write-Host "==> Versioned candidate: $candidate"
