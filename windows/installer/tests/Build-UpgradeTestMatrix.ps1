[CmdletBinding()]
param([string] $Configuration = 'Release')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installer = Split-Path -Parent $PSScriptRoot
$windows = Split-Path -Parent $installer
$fixedBoundary = [IO.Path]::GetFullPath((Join-Path $installer 'artifacts\test-only-upgrade'))
$output = [IO.Path]::GetFullPath((Join-Path $fixedBoundary 'generated'))
$publish = Join-Path $output 'publish\win-x64'
$project = Join-Path $installer 'Jazz.UpgradeTests.wixproj'
$hostProject = Join-Path $windows 'Sources\JazzCapture\JazzCapture.csproj'
$testUpgradeCode = 'A40F0000-40A0-4A00-8000-000000000040'
$testComponentSeed = 'A40F0001-40A0-4A00-8000-000000000040'
$testAutoStartComponent = 'A40F0002-40A0-4A00-8000-000000000040'
$testShortcutComponent = 'A40F0003-40A0-4A00-8000-000000000040'

if (-not $output.StartsWith($fixedBoundary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Computed matrix output escaped the canonical test-only boundary.'
}
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
New-Item -ItemType Directory -Path $publish -Force | Out-Null
$builtPackages = [System.Collections.Generic.List[string]]::new()
dotnet publish $hostProject --configuration $Configuration --runtime win-x64 --self-contained true `
    -p:SatelliteResourceLanguages=en --output $publish --nologo
if ($LASTEXITCODE -ne 0) { throw 'Test-only payload publish failed.' }

function Assert-Version([string] $Version) {
    if ($Version -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,5})$') { throw "Invalid MSI test version: $Version" }
    $parts = $Version.Split('.') | ForEach-Object { [int]$_ }
    if ($parts[0] -gt 255 -or $parts[1] -gt 255 -or $parts[2] -gt 65535) { throw "MSI test version out of range: $Version" }
}

function Build-Fixture([string] $Name, [string] $Version, [string] $ProductCode, [bool] $Fail, [string] $PayloadMarker) {
    Assert-Version $Version
    $packageOutput = Join-Path $output $Name
    New-Item -ItemType Directory -Path $packageOutput -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $publish 'JAZZ_TEST_ONLY_PAYLOAD.txt') -Value $PayloadMarker -Encoding ascii
    dotnet build $project --configuration $Configuration --nologo `
        -p:TestOnlyBuild=true -p:TestOutputName=$Name -p:TestOutputDirectory="$packageOutput\" `
        -p:TestOutputBoundary="$fixedBoundary" `
        -p:BaseIntermediateOutputPath="$packageOutput\obj\" `
        -p:PublishDir="$publish\" -p:TestProductVersion=$Version -p:TestProductCode=$ProductCode `
        -p:TestUpgradeCode=$testUpgradeCode -p:TestComponentGuidSeed=$testComponentSeed `
        -p:TestAutoStartComponentGuid=$testAutoStartComponent -p:TestShortcutComponentGuid=$testShortcutComponent `
        -p:TestPayloadVariant=$PayloadMarker `
        -p:TestOnlyFailure=$($Fail.ToString().ToLowerInvariant())
    if ($LASTEXITCODE -ne 0) { throw "Could not build test-only package $Name." }
    $builtPackages.Add((Join-Path $packageOutput ($Name + '.msi')))
}

Build-Fixture 'jazz-test-only-n' '1.0.0' 'A40F1000-40A0-4A00-8000-000000010000' $false 'baseline-n'
Build-Fixture 'jazz-test-only-n-same-bytes-changed' '1.0.0' 'A40F1000-40A0-4A00-8000-000000010000' $false 'changed-same-version'
Build-Fixture 'jazz-test-only-n-plus-1' '1.1.0' 'A40F1100-40A0-4A00-8000-000000010100' $false 'candidate-n-plus-1'
Build-Fixture 'jazz-test-only-n-plus-1-failing' '1.1.0' 'A40F1100-40A0-4A00-8000-000000010100' $true 'candidate-failing-after-remove'

@($builtPackages) | ForEach-Object {
    $item = Get-Item -LiteralPath $_
    [pscustomobject]@{ name = $item.Name; length = $item.Length; sha256 = (Get-FileHash $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
} | ConvertTo-Json | Set-Content (Join-Path $output 'matrix.json') -Encoding utf8
