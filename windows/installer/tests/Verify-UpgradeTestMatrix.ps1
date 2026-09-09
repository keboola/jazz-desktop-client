[CmdletBinding()]
param([string] $MatrixDirectory = (Join-Path $PSScriptRoot '..\artifacts\test-only-upgrade\generated'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MsiQualification.psm1') -Force

$root = (Resolve-Path -LiteralPath $MatrixDirectory).Path
$names = @('jazz-test-only-n', 'jazz-test-only-n-same-bytes-changed', 'jazz-test-only-n-plus-1', 'jazz-test-only-n-plus-1-failing')
$packages = @{}

function Read-MsiTable([string] $MsiPath, [string] $Sql, [string[]] $Columns) {
    $installer = $null; $database = $null; $view = $null; $record = $null
    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))
        try {
            $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($Sql))
        } catch {
            # MSI omits empty tables entirely. Callers still assert every required row.
            return @()
        }
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        while ($null -ne ($record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null))) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $Columns.Count; $i++) {
                $row[$Columns[$i]] = [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @($i + 1))
            }
            $rows.Add([pscustomobject]$row)
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record); $record = $null
        }
        return @($rows)
    } finally {
        if ($null -ne $view) { try { $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null } catch {} }
        foreach ($value in @($record, $view, $database, $installer)) {
            if ($null -ne $value -and [Runtime.InteropServices.Marshal]::IsComObject($value)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($value) }
        }
    }
}

function Require([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; Write-Host "PASS $Message" }

foreach ($name in $names) {
    $path = Join-Path (Join-Path $root $name) ($name + '.msi')
    Require (Test-Path -LiteralPath $path -PathType Leaf) "$name exists at its exact output path"
    $identity = Get-JazzMsiIdentity -MsiPath $path
    $properties = @{}
    foreach ($row in @(Read-MsiTable $path 'SELECT `Property`,`Value` FROM `Property`' @('Name','Value'))) { $properties[$row.Name] = $row.Value }
    $sequence = @(Read-MsiTable $path 'SELECT `Action`,`Condition`,`Sequence` FROM `InstallExecuteSequence`' @('Action','Condition','Sequence'))
    $actions = @(Read-MsiTable $path 'SELECT `Action`,`Type`,`Source`,`Target` FROM `CustomAction`' @('Action','Type','Source','Target'))
    $components = @(Read-MsiTable $path 'SELECT `Component`,`ComponentId`,`Directory_` FROM `Component`' @('Name','Guid','Directory'))
    $packages[$name] = [pscustomobject]@{ Path=$path; Identity=$identity; Properties=$properties; Sequence=$sequence; Actions=$actions; Components=$components }
    Require ($identity.productName -eq 'Jazz Capture Upgrade Fixture') "$name belongs to the isolated test product family"
    Require ($identity.upgradeCode -eq '{A40F0000-40A0-4A00-8000-000000000040}') "$name uses the fixed test-only UpgradeCode"
    Require ($properties.ContainsKey('JAZZ_TEST_ONLY_PAYLOAD_VARIANT')) "$name carries the compile-time test-only marker"
    $initialize = @($sequence | Where-Object Action -eq InstallInitialize)
    $remove = @($sequence | Where-Object Action -eq RemoveExistingProducts)
    $finalize = @($sequence | Where-Object Action -eq InstallFinalize)
    Require ($initialize.Count -eq 1 -and $remove.Count -eq 1 -and $finalize.Count -eq 1 -and [int]$initialize[0].Sequence -lt [int]$remove[0].Sequence -and [int]$remove[0].Sequence -lt [int]$finalize[0].Sequence) "$name sequences removal inside the rollback transaction"
}

$n = $packages['jazz-test-only-n']; $same = $packages['jazz-test-only-n-same-bytes-changed']; $next = $packages['jazz-test-only-n-plus-1']; $failing = $packages['jazz-test-only-n-plus-1-failing']
Require ($n.Identity.productVersion -eq $same.Identity.productVersion -and $n.Identity.productCode -eq $same.Identity.productCode) 'changed-same-version preserves ProductVersion and ProductCode'
Require ($n.Identity.packageCode -ne $same.Identity.packageCode -and $n.Identity.sha256 -ne $same.Identity.sha256) 'changed-same-version has a different PackageCode and SHA-256'
Require ($n.Properties.JAZZ_TEST_ONLY_PAYLOAD_VARIANT -eq 'baseline-n' -and $same.Properties.JAZZ_TEST_ONLY_PAYLOAD_VARIANT -eq 'changed-same-version') 'changed-same-version difference is an explicit payload variant'
Require ([version]$n.Identity.productVersion -lt [version]$next.Identity.productVersion) 'N is lower than N+1'
Require (@($next.Actions | Where-Object Action -eq 'FailAfterRemoveExisting').Count -eq 0) 'normal N+1 contains no failure action'
$failureAction = @($failing.Actions | Where-Object Action -eq 'FailAfterRemoveExisting')
$failureSequence = @($failing.Sequence | Where-Object Action -eq 'FailAfterRemoveExisting')
$removeSequence = @($failing.Sequence | Where-Object Action -eq 'RemoveExistingProducts')
Require ($failureAction.Count -eq 1 -and $failureSequence.Count -eq 1) 'failing N+1 contains exactly one type-19 failure action'
Require ([int]$failureSequence[0].Sequence -gt [int]$removeSequence[0].Sequence -and $failureSequence[0].Condition -eq 'WIX_UPGRADE_DETECTED') 'failure action runs after RemoveExistingProducts only for a detected upgrade'
Require ($failing.Properties.ContainsKey('JAZZ_TEST_ONLY_ROLLBACK_FIXTURE')) 'failing N+1 carries the rollback-fixture marker'

$fixedGuids = @('{A40F0002-40A0-4A00-8000-000000000040}','{A40F0003-40A0-4A00-8000-000000000040}')
foreach ($package in @($packages.Values)) {
    foreach ($guid in $fixedGuids) { Require ($package.Components.Guid -contains $guid) "$([IO.Path]::GetFileName($package.Path)) contains isolated fixed component $guid" }
    Require ($package.Components.Guid -notcontains '{8C67FA76-EC23-41BE-90B1-8C081A7DC5D8}' -and $package.Components.Guid -notcontains '{597CFBCD-818B-4016-8829-E264B8603A96}') "$([IO.Path]::GetFileName($package.Path)) reuses no production fixed component GUID"
}

Write-Host 'Upgrade test matrix structure and identities are valid. No installer mutation was performed.'
