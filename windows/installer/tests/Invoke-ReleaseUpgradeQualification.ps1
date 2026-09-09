[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $BaselineMsiPath,
    [Parameter(Mandatory)][string] $CandidateMsiPath,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [switch] $AllowInstalledProductMutation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MsiQualification.psm1') -Force

if ($env:GITHUB_ACTIONS -ne 'true') {
    throw 'Exact-byte upgrade qualification is restricted to a disposable GitHub Actions runner.'
}
if (-not $AllowInstalledProductMutation) { throw 'Explicit mutation opt-in is required.' }

$baselinePath = (Resolve-Path -LiteralPath $BaselineMsiPath).Path
$candidatePath = (Resolve-Path -LiteralPath $CandidateMsiPath).Path
$baseline = Get-JazzMsiIdentity $baselinePath
$candidate = Get-JazzMsiIdentity $candidatePath
$config = Get-JazzInstallerConfiguration
if ($baseline.productName -ne $config.ProductName -or
    $candidate.productName -ne $config.ProductName -or
    $baseline.upgradeCode -ne $candidate.upgradeCode -or
    [version] $baseline.productVersion -ge [version] $candidate.productVersion) {
    throw 'Baseline/candidate identity is not a newer upgrade in one production family.'
}

$started = [DateTimeOffset]::UtcNow
$phase = 'preflight'
$failurePhase = $null
$failed = $false
$checks = [System.Collections.Generic.List[object]]::new()
$logs = @{}
$proof = [ordered] @{}
$sentinels = [System.Collections.Generic.List[object]]::new()
$snapshots = [ordered] @{}
$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $config.DataFolderName
$installRoot = Join-Path $root $config.InstallFolderName
$tempLogs = Join-Path ([IO.Path]::GetTempPath()) ('jazz-release-upgrade-' + [Guid]::NewGuid().ToString('N'))

function Add-Check([string] $Id, [string] $Status, [string] $Detail) {
    $checks.Add([pscustomobject] @{ id = $Id; status = $Status; detail = $Detail })
}

function Require([string] $Id, [bool] $Condition, [string] $Detail) {
    Add-Check $Id $(if ($Condition) { 'passed' } else { 'failed' }) $Detail
    if (-not $Condition) { throw "Release upgrade check failed: $Id" }
}

function New-Log([string] $Name) {
    $path = Join-Path $tempLogs ($Name + '.log')
    $logs[$Name + '.sanitized.log'] = $path
    return $path
}

function Invoke-MatrixMsi([string] $Name, [string] $Operation, [string] $Path = '', [string] $Code = '') {
    return Invoke-QualificationMsiExec -Operation $Operation -MsiPath $Path `
        -ProductCode $Code -LogPath (New-Log $Name)
}

function Get-State([string] $Code) {
    return Get-JazzInstalledState -ProductCode $Code -InstallerConfiguration $config
}

function Get-Snapshot([string] $Code) {
    $state = Get-State $Code
    return [pscustomobject] [ordered] @{
        registered = $state.registered
        registrationCount = @($baseline.productCode, $candidate.productCode |
                Where-Object { (Get-State $_).registered }).Count
        executableSha256 = if ($state.executableExists) {
            Get-QualificationSha256 $state.executablePath
        } else { $null }
        inventory = if ($state.installRootExists) {
            Get-QualificationDirectoryInventory $installRoot
        } else { $null }
        runValue = $state.runValue
        shortcutTarget = $state.shortcutTarget
    }
}

function Assert-SnapshotEqual([string] $Id, $Expected, $Actual) {
    Require "$Id-registration" ($Actual.registered -and $Actual.registrationCount -eq 1) `
        'Exactly the expected production ProductCode is registered.'
    Require "$Id-inventory" ($Expected.inventory.sha256 -eq $Actual.inventory.sha256) `
        'Installed inventory is byte-identical.'
    Require "$Id-exe" ($Expected.executableSha256 -eq $Actual.executableSha256) `
        'Executable SHA-256 is unchanged.'
    Require "$Id-run" ($Expected.runValue -eq $Actual.runValue) 'Run value is unchanged.'
    Require "$Id-shortcut" ($Expected.shortcutTarget -eq $Actual.shortcutTarget) `
        'Shortcut target is unchanged.'
}

function Add-Sentinel([string] $Kind, [string] $Path, [string] $Text) {
    [void] [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
    $sentinels.Add([pscustomobject] @{
            Kind = $Kind
            Path = $Path
            Hash = Get-QualificationSha256 $Path
        })
}

function Assert-Data([string] $At) {
    $row = [ordered] @{}
    foreach ($sentinel in $sentinels) {
        $actual = if (Test-Path $sentinel.Path) {
            Get-QualificationSha256 $sentinel.Path
        } else { 'missing' }
        $row[$sentinel.Kind] = @{ before = $sentinel.Hash; after = $actual }
        Require "data-$At-$($sentinel.Kind)" ($actual -eq $sentinel.Hash) `
            "$($sentinel.Kind) bytes remain unchanged."
    }
    $proof[$At] = $row
}

function Get-OwnedProcesses {
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $installRoot $config.ExecutableName))
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $owned = [System.Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name $config.ProcessName -ErrorAction SilentlyContinue |
            Where-Object SessionId -eq $session)) {
        try { $path = [IO.Path]::GetFullPath($process.Path) } catch {
            throw 'Process ownership inspection failed closed.'
        }
        if ($path.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            $owned.Add([pscustomobject] @{
                    Id = $process.Id
                    Path = $path
                    Ticks = $process.StartTime.ToUniversalTime().Ticks
                })
        }
    }
    return @($owned)
}

function Stop-OwnedProcess($Identity) {
    $process = Get-Process -Id $Identity.Id -ErrorAction SilentlyContinue
    if ($null -eq $process) { return }
    $samePath = [IO.Path]::GetFullPath($process.Path).Equals(
        $Identity.Path, [StringComparison]::OrdinalIgnoreCase)
    if (-not $samePath -or $process.StartTime.ToUniversalTime().Ticks -ne $Identity.Ticks) {
        throw 'Refusing to stop an unowned process.'
    }
    Stop-Process -Id $Identity.Id -ErrorAction Stop
    if (-not $process.WaitForExit(10000)) { throw 'Owned process stop timed out.' }
}

try {
    $clean = Test-JazzProfileClean -CandidateProductCode $baseline.productCode `
        -InstallerConfiguration $config
    Require 'clean-profile' $clean.IsClean `
        'No production Jazz product, process, resource, or data root exists.'
    [void] [IO.Directory]::CreateDirectory($tempLogs)

    Add-Sentinel settings (Join-Path $root 'settings.json') '{"schemaVersion":1}'
    Add-Sentinel capture (Join-Path $root 'captures\.release-upgrade-capture') 'capture'
    Add-Sentinel journal (Join-Path $root 'captures\.capture-journal\fixture\checkpoint.json') `
        '{"lifecycle":"committed"}'
    Add-Sentinel queue (Join-Path $root 'queue\.release-upgrade.jazz-archive') 'queue'
    $proof.before = [ordered] @{}
    foreach ($sentinel in $sentinels) { $proof.before[$sentinel.Kind] = $sentinel.Hash }

    $phase = 'baseline-install'
    Require 'baseline-install' `
        ((Invoke-MatrixMsi '01-baseline-install' Install $baselinePath) -eq 0) `
        'Exact baseline bytes install.'
    $snapshots.baseline = Get-Snapshot $baseline.productCode
    Require 'baseline-registration' ($snapshots.baseline.registrationCount -eq 1) `
        'Exactly baseline is registered.'
    Assert-Data baselineInstall

    $phase = 'baseline-repair'
    Require 'baseline-repair' `
        ((Invoke-MatrixMsi '02-baseline-repair' Repair $baselinePath) -eq 0) `
        'Exact baseline repair succeeds.'
    Assert-SnapshotEqual baselineRepair $snapshots.baseline (Get-Snapshot $baseline.productCode)
    Assert-Data baselineRepair

    $phase = 'running-upgrade'
    $baselineState = Get-State $baseline.productCode
    $oldProcess = Start-Process $baselineState.executablePath -PassThru
    Start-Sleep -Seconds 3
    Require 'baseline-host-running' (-not $oldProcess.HasExited) 'Exact baseline host runs.'
    Require 'candidate-upgrade' `
        ((Invoke-MatrixMsi '03-running-upgrade' Install $candidatePath) -eq 0) `
        'Exact candidate upgrades running baseline.'
    [void] $oldProcess.WaitForExit(15000)
    Require 'old-host-closed' $oldProcess.HasExited 'Restart Manager closes baseline PID.'

    $snapshots.candidate = Get-Snapshot $candidate.productCode
    $exactExe = Join-Path $installRoot $config.ExecutableName
    $exactResources = $snapshots.candidate.registrationCount -eq 1 -and
        $snapshots.candidate.runValue -eq ('"' + $exactExe + '"') -and
        $snapshots.candidate.shortcutTarget -eq $exactExe
    Require 'candidate-resources' $exactResources `
        'Only exact candidate registration and resources remain.'

    $owned = @(Get-OwnedProcesses)
    if ($owned.Count -eq 0) {
        $process = Start-Process $exactExe -PassThru
        $owned = @([pscustomobject] @{
                Id = $process.Id
                Path = [IO.Path]::GetFullPath($exactExe)
                Ticks = $process.StartTime.ToUniversalTime().Ticks
            })
    }
    Start-Sleep -Seconds 3
    foreach ($identity in $owned) {
        Require 'recovery-host' ($null -ne (Get-Process -Id $identity.Id -ErrorAction SilentlyContinue)) `
            'Candidate recovery host survives.'
        Stop-OwnedProcess $identity
    }
    Require 'no-orphan' (@(Get-OwnedProcesses).Count -eq 0) `
        'No exact candidate process remains.'
    Assert-Data candidateUpgrade

    $beforeDowngrade = Get-Snapshot $candidate.productCode
    $phase = 'downgrade'
    $downgradeExit = Invoke-MatrixMsi '04-downgrade' Install $baselinePath
    Require 'downgrade-rejected' ($downgradeExit -ne 0) `
        "Downgrade returns $downgradeExit."
    Assert-SnapshotEqual downgrade $beforeDowngrade (Get-Snapshot $candidate.productCode)
    Require 'no-baseline-residue' (-not (Get-State $baseline.productCode).registered) `
        'Rejected downgrade leaves no baseline registration.'
    Assert-Data downgrade

    $phase = 'candidate-repair'
    $ownedResource = Assert-QualificationChildPath -Root $installRoot `
        -Path (Join-Path $installRoot 'Assets\tray-idle.ico')
    Require 'candidate-repair-resource-present' (Test-Path -LiteralPath $ownedResource) `
        'Verified installer-owned tray resource exists before repair fixture.'
    $ownedResourceHash = Get-QualificationSha256 $ownedResource
    Remove-Item -LiteralPath $ownedResource
    Require 'candidate-repair' `
        ((Invoke-MatrixMsi '05-candidate-repair' Repair $candidatePath) -eq 0) `
        'Exact candidate repair succeeds after removing one verified owned resource.'
    Require 'candidate-repair-restores-resource' `
        (Test-QualificationFileHash $ownedResource $ownedResourceHash) `
        'Candidate repair restores the exact owned resource bytes.'
    Assert-SnapshotEqual candidateRepair $beforeDowngrade (Get-Snapshot $candidate.productCode)
    Assert-Data candidateRepair

    $phase = 'uninstall'
    Require 'candidate-uninstall' `
        ((Invoke-MatrixMsi '06-candidate-uninstall' Uninstall '' $candidate.productCode) -eq 0) `
        'Candidate uninstall succeeds.'
    $removed = Get-State $candidate.productCode
    Require 'owned-resources-removed' `
        (-not $removed.registered -and -not $removed.installRootExists -and
            $null -eq $removed.runValue -and -not $removed.shortcutExists) `
        'Only installer-owned resources are removed.'
    Assert-Data uninstall
} catch {
    $failed = $true
    $failurePhase = $phase
    Add-Check uncaught-failure failed (Protect-QualificationText $_.Exception.Message)
} finally {
    try {
        foreach ($identity in @(Get-OwnedProcesses)) { Stop-OwnedProcess $identity }
        foreach ($code in @($candidate.productCode, $baseline.productCode)) {
            if ((Get-State $code).registered) {
                $cleanupExit = Invoke-MatrixMsi ('cleanup-' + $code.Trim('{}')) Uninstall '' $code
                if ($cleanupExit -ne 0) { throw "Cleanup returned $cleanupExit." }
            }
        }
        $cleaned = @(Get-OwnedProcesses).Count -eq 0 -and
            -not (Get-State $candidate.productCode).registered -and
            -not (Get-State $baseline.productCode).registered
        Require cleanup $cleaned `
            'Cleanup targets only exact release ProductCodes and owned PIDs.'
    } catch {
        $failed = $true
        Add-Check cleanup failed (Protect-QualificationText $_.Exception.Message)
    }

    $report = [pscustomobject] [ordered] @{
        '$schema' = '../../qualification/qualification-report.schema.json'
        schemaVersion = 1
        kind = 'automated-msi-lifecycle'
        status = if ($failed) { 'failed' } else { 'passed' }
        generatedAt = [DateTimeOffset]::UtcNow.ToString('O')
        durationMilliseconds = [int64] ([DateTimeOffset]::UtcNow - $started).TotalMilliseconds
        source = @{ commit = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID; runAttempt = $env:GITHUB_RUN_ATTEMPT }
        package = $candidate
        environment = @{
            osVersion = [Environment]::OSVersion.VersionString
            architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
            processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
            privilege = 'administrator'
            userInteractive = [Environment]::UserInteractive
            sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        }
        failurePhase = $failurePhase
        inventory = @{ baseline = $baseline; candidate = $candidate; snapshots = $snapshots }
        sentinels = $proof
        checks = @($checks)
        limitations = @(
            'Closing a running v0.26.2 baseline is an idle compatibility row, not proof of the candidate safe-drain protocol.',
            'Active-capture candidate shutdown and visible review suppression remain interactive rows.',
            'No deliberate rollback hook exists in either release package.',
            'No backend endpoint or captured content is used.'
        )
    }
    try {
        Write-QualificationEvidence $report ([IO.Path]::GetFullPath($EvidenceDirectory)) $logs @{
            '<BASELINE-DIR>' = Split-Path $baselinePath
            '<CANDIDATE-DIR>' = Split-Path $candidatePath
            '<TEMP-LOG-DIR>' = $tempLogs
        }
        $json = Get-Content (Join-Path $EvidenceDirectory 'qualification.json') -Raw
        $schema = Get-Content (Join-Path $PSScriptRoot '..\..\qualification\qualification-report.schema.json') -Raw
        if (-not (Test-Json -Json $json -Schema $schema -ErrorAction Stop)) {
            throw 'Release upgrade report failed schema validation.'
        }
        Assert-QualificationEvidencePrivacy $EvidenceDirectory
    } finally {
        if (Test-Path $tempLogs) {
            foreach ($file in @(Get-ChildItem -LiteralPath $tempLogs -File)) {
                Remove-Item -LiteralPath $file.FullName
            }
            if (@(Get-ChildItem -LiteralPath $tempLogs -Force).Count -eq 0) {
                Remove-Item -LiteralPath $tempLogs
            }
        }
    }
    foreach ($sentinel in $sentinels) {
        if (Test-QualificationFileHash $sentinel.Path $sentinel.Hash) {
            Remove-Item -LiteralPath $sentinel.Path
        }
    }
}

if ($failed) { exit 1 }
Write-Host 'Exact baseline-to-candidate release upgrade qualification passed.'
