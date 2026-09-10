[CmdletBinding()]
param([Parameter(Mandatory)][string]$MsiPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $MsiPath)) { throw 'Candidate MSI is missing.' }
$manifestPath = "$MsiPath.manifest.json"; $checksumPath = "$MsiPath.sha256"
if (-not (Test-Path -LiteralPath $manifestPath) -or -not (Test-Path -LiteralPath $checksumPath)) { throw 'Candidate triplet is incomplete.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.schema -ne 1 -or $manifest.sha256 -notmatch '^[0-9a-f]{64}$' -or
    $manifest.filename -notmatch '^JazzCapture-[0-9]+\.[0-9]+\.[0-9]+-win-x64-unsigned\.msi$' -or
    $manifest.version -notmatch '^\d+\.\d+\.\d+$' -or $manifest.unsigned -ne $true -or
    [string]::IsNullOrWhiteSpace($manifest.commit) -or [string]::IsNullOrWhiteSpace($manifest.workflowRun) -or [string]::IsNullOrWhiteSpace($manifest.workflowAttempt)) { throw 'Candidate manifest fails required schema fields.' }
$actualHash = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
$actualLength = (Get-Item -LiteralPath $MsiPath).Length
if ($manifest.filename -cne (Split-Path -Leaf $MsiPath) -or $manifest.sha256 -cne $actualHash -or [int64]$manifest.byteLength -ne $actualLength) { throw 'Candidate manifest does not bind exact bytes.' }
if ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -cne "$actualHash  $(Split-Path -Leaf $MsiPath)") { throw 'Candidate checksum does not bind exact bytes.' }
$version = (dotnet msbuild (Join-Path $PSScriptRoot 'Jazz.Version.props') -getProperty:JazzProductVersion -nologo).Trim()
if ($manifest.version -cne $version -or $manifest.productVersion -cne $version) { throw 'Candidate version does not match canonical props.' }
if ($manifest.unsigned -ne $true) { throw 'Candidate must be declared unsigned.' }
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $null; $summary = $null
try {
  $database = $installer.OpenDatabase($MsiPath, 0); $summary = $database.SummaryInformation(0)
  function Get-MsiProperty([string]$name) {
    $view = $database.OpenView("SELECT `Value` FROM `Property` WHERE `Property`='$name'"); $view.Execute(); $record = $view.Fetch()
    try { if ($null -eq $record) { throw "MSI property $name is missing." }; return [string]$record.StringData(1) }
    finally { if ($null -ne $record) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }; [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
  }
  $productCode = Get-MsiProperty 'ProductCode'; $upgradeCode = Get-MsiProperty 'UpgradeCode'; $productVersion = Get-MsiProperty 'ProductVersion'; $packageCode = [string]$summary.Property(9)
  if ($manifest.productCode.Trim('{}') -cne $productCode.Trim('{}') -or $manifest.upgradeCode.Trim('{}') -cne $upgradeCode.Trim('{}') -or $manifest.productVersion -cne $productVersion -or $manifest.packageCode -cne $packageCode) { throw 'Manifest package identities differ from MSI database.' }
} finally {
  if ($null -ne $summary) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
  if ($null -ne $database) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
  [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
}
Write-Host 'Candidate manifest binds canonical version and exact bytes.'
