[CmdletBinding()]
param([Parameter(Mandatory)][string]$MsiPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $MsiPath)) { throw 'Candidate MSI is missing.' }
$manifestPath = "$MsiPath.manifest.json"; $checksumPath = "$MsiPath.sha256"
if (-not (Test-Path -LiteralPath $manifestPath) -or -not (Test-Path -LiteralPath $checksumPath)) { throw 'Candidate triplet is incomplete.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$actualHash = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
$actualLength = (Get-Item -LiteralPath $MsiPath).Length
if ($manifest.filename -cne (Split-Path -Leaf $MsiPath) -or $manifest.sha256 -cne $actualHash -or [int64]$manifest.byteLength -ne $actualLength) { throw 'Candidate manifest does not bind exact bytes.' }
if ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -cne "$actualHash  $(Split-Path -Leaf $MsiPath)") { throw 'Candidate checksum does not bind exact bytes.' }
$version = (dotnet msbuild (Join-Path $PSScriptRoot 'Jazz.Version.props') -getProperty:JazzProductVersion -nologo).Trim()
if ($manifest.version -cne $version -or $manifest.productVersion -cne $version) { throw 'Candidate version does not match canonical props.' }
if ($manifest.unsigned -ne $true) { throw 'Candidate must be declared unsigned.' }
Write-Host 'Candidate manifest binds canonical version and exact bytes.'
