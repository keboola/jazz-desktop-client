[CmdletBinding()]
param([Parameter(Mandatory)][string]$MsiPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $MsiPath)) { throw 'Candidate MSI is missing.' }
$manifestPath = "$MsiPath.manifest.json"; $checksumPath = "$MsiPath.sha256"
if (-not (Test-Path -LiteralPath $manifestPath) -or -not (Test-Path -LiteralPath $checksumPath)) { throw 'Candidate triplet is incomplete.' }
$manifestJson = Get-Content -LiteralPath $manifestPath -Raw
$schemaJson = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'candidate-manifest.schema.json') -Raw
if (-not (Test-Json -Json $manifestJson -Schema $schemaJson -ErrorAction Stop)) { throw 'Candidate manifest fails its JSON schema.' }
$manifest = $manifestJson | ConvertFrom-Json
if ($env:GITHUB_ACTIONS -eq 'true') {
  if ($manifest.commit -cne $env:GITHUB_SHA -or $manifest.workflowRun -cne $env:GITHUB_RUN_ID -or
      $manifest.workflowAttempt -cne $env:GITHUB_RUN_ATTEMPT -or $manifest.workflowRun -eq '0' -or
      $manifest.workflowAttempt -eq '0') { throw 'Candidate provenance differs from the current GitHub Actions run.' }
}
$actualHash = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
$actualLength = (Get-Item -LiteralPath $MsiPath).Length
if ($manifest.filename -cne (Split-Path -Leaf $MsiPath) -or $manifest.sha256 -cne $actualHash -or [int64]$manifest.byteLength -ne $actualLength) { throw 'Candidate manifest does not bind exact bytes.' }
if ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -cne "$actualHash  $(Split-Path -Leaf $MsiPath)") { throw 'Candidate checksum does not bind exact bytes.' }
$version = (dotnet msbuild (Join-Path $PSScriptRoot 'Jazz.Version.props') -getProperty:JazzProductVersion -nologo).Trim()
$productCodeProp = (dotnet msbuild (Join-Path $PSScriptRoot 'Jazz.Version.props') -getProperty:JazzProductCode -nologo).Trim()
$upgradeCodeProp = (dotnet msbuild (Join-Path $PSScriptRoot 'Jazz.Version.props') -getProperty:JazzUpgradeCode -nologo).Trim()
if ($manifest.version -cne $version -or $manifest.productVersion -cne $version -or
    $manifest.productCode -ine $productCodeProp -or $manifest.upgradeCode -ine $upgradeCodeProp) { throw 'Candidate identities do not match canonical props.' }
if ($manifest.unsigned -ne $true) { throw 'Candidate must be declared unsigned.' }
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $null; $summary = $null
try {
  $database = $installer.OpenDatabase($MsiPath, 0); $summary = $database.SummaryInformation(0)
  function Get-MsiProperty([string]$name) {
    $view = $database.OpenView("SELECT `Value` FROM `Property` WHERE `Property`='$name'"); [void]$view.Execute(); $record = $view.Fetch()
    try { if ($null -eq $record) { throw "MSI property $name is missing." }; return [string]$record.StringData(1) }
    finally { if ($null -ne $record) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }; [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
  }
  $productCode = Get-MsiProperty 'ProductCode'; $upgradeCode = Get-MsiProperty 'UpgradeCode'; $productVersion = Get-MsiProperty 'ProductVersion'; $packageCode = [string]$summary.Property(9)
  if (([string]$manifest.productCode).Trim('{}') -ine ([string]$productCode).Trim('{}') -or
      ([string]$manifest.upgradeCode).Trim('{}') -ine ([string]$upgradeCode).Trim('{}') -or
      [string]$manifest.productVersion -cne [string]$productVersion -or
      [string]$manifest.packageCode -ine [string]$packageCode) { throw 'Manifest package identities differ from MSI database.' }
} finally {
  if ($null -ne $summary) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
  if ($null -ne $database) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
  [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
}
Write-Host 'Candidate manifest binds canonical version and exact bytes.'
