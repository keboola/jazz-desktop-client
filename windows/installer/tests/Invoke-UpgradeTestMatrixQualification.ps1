[CmdletBinding()]
param(
    [string] $MatrixDirectory = (Join-Path $PSScriptRoot '..\artifacts\test-only-upgrade\generated'),
    [string] $EvidenceDirectory = (Join-Path $PSScriptRoot '..\artifacts\test-only-upgrade\qualification'),
    [switch] $AllowInstalledProductMutation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MsiQualification.psm1') -Force

if ($env:GITHUB_ACTIONS -ne 'true') {
    throw 'The mutating upgrade matrix is restricted to a disposable GitHub Actions runner.'
}
if (-not $AllowInstalledProductMutation) { throw 'Explicit mutation opt-in is required.' }

$startedAt = [DateTimeOffset]::UtcNow
$phase = 'preflight'
$failed = $false
$failurePhase = $null
$root = (Resolve-Path -LiteralPath $MatrixDirectory).Path
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
$names = @(
    'jazz-test-only-n',
    'jazz-test-only-n-same-bytes-changed',
    'jazz-test-only-n-plus-1',
    'jazz-test-only-n-plus-1-failing'
)
$paths = @{}
$identities = @{}
foreach ($name in $names) {
    $paths[$name] = (Resolve-Path -LiteralPath (
            Join-Path (Join-Path $root $name) ($name + '.msi'))).Path
    $identities[$name] = Get-JazzMsiIdentity $paths[$name]
}
$baseline = $identities[$names[0]]
$candidate = $identities[$names[2]]
$fixture = [pscustomobject] @{
    ProductName = 'Jazz Capture Upgrade Fixture'
    DataFolderName = 'JazzUpgradeFixture'
    InstallFolderName = 'App'
    RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
    RunValueName = 'JazzUpgradeFixture'
    ExecutableName = 'JazzCapture.exe'
    ProcessName = 'JazzCapture'
    StartMenuFolderName = 'Jazz Upgrade Fixture'
    ShortcutName = 'Jazz Capture Upgrade Fixture'
}
$production = Get-JazzInstallerConfiguration
$runtimeRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Jazz'
$fixtureRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'JazzUpgradeFixture'
$fixtureInstallRoot = Join-Path $fixtureRoot 'App'
$checks = [System.Collections.Generic.List[object]]::new()
$logs = @{}
$sentinels = [System.Collections.Generic.List[object]]::new()
$sentinelProof = [ordered] @{}
$snapshots = [ordered] @{}
$tempLogs = Join-Path ([IO.Path]::GetTempPath()) ('jazz-upgrade-matrix-' + [Guid]::NewGuid().ToString('N'))

function Add-Check([string] $Id, [string] $Status, [string] $Detail) {
    $checks.Add([pscustomobject] @{ id = $Id; status = $Status; detail = $Detail })
}

function Require([string] $Id, [bool] $Condition, [string] $Detail) {
    Add-Check $Id $(if ($Condition) { 'passed' } else { 'failed' }) $Detail
    if (-not $Condition) { throw "Upgrade matrix check failed: $Id" }
}

function New-Log([string] $Name) {
    $path = Join-Path $tempLogs ($Name + '.log')
    $logs[$Name + '.sanitized.log'] = $path
    return $path
}

function Invoke-MatrixMsi([string] $Name, [string] $Operation, [string] $Package = '', [string] $ProductCode = '') {
    return Invoke-QualificationMsiExec -Operation $Operation -MsiPath $Package `
        -ProductCode $ProductCode -LogPath (New-Log $Name)
}

function Get-State([string] $ProductCode) {
    return Get-JazzInstalledState -ProductCode $ProductCode -InstallerConfiguration $fixture
}

function Add-Sentinel([string] $Kind, [string] $Path, [string] $Value) {
    [void] [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
    $sentinels.Add([pscustomobject] @{
            Kind = $Kind
            Path = $Path
            Sha256 = Get-QualificationSha256 $Path
        })
}

function Assert-Sentinels([string] $At) {
    $proof = [ordered] @{}
    foreach ($sentinel in $sentinels) {
        $actual = if (Test-Path -LiteralPath $sentinel.Path) {
            Get-QualificationSha256 $sentinel.Path
        } else { 'missing' }
        $proof[$sentinel.Kind] = @{ before = $sentinel.Sha256; after = $actual }
        Require "data-$At-$($sentinel.Kind)" ($actual -eq $sentinel.Sha256) `
            "$($sentinel.Kind) bytes remain byte-identical."
    }
    $sentinelProof[$At] = $proof
}

function Get-ResourceSnapshot([string] $ProductCode) {
    $state = Get-State $ProductCode
    return [pscustomobject] [ordered] @{
        productCode = $ProductCode
        registered = $state.registered
        registrationCount = @($baseline.productCode, $candidate.productCode |
                Where-Object { (Get-State $_).registered }).Count
        installRootExists = $state.installRootExists
        executableExists = $state.executableExists
        executableSha256 = if ($state.executableExists) {
            Get-QualificationSha256 $state.executablePath
        } else { $null }
        inventory = if ($state.installRootExists) {
            Get-QualificationDirectoryInventory $fixtureInstallRoot
        } else { $null }
        runValue = $state.runValue
        shortcutExists = $state.shortcutExists
        shortcutTarget = $state.shortcutTarget
    }
}

function Assert-SnapshotEqual([string] $Id, $Expected, $Actual) {
    Require "$Id-registration" ($Actual.registered -and $Actual.registrationCount -eq 1) `
        'Exactly one expected test product is registered.'
    Require "$Id-inventory" `
        ($Actual.inventory.sha256 -eq $Expected.inventory.sha256 -and
            $Actual.inventory.byteLength -eq $Expected.inventory.byteLength) `
        'Installed inventory is byte-identical.'
    Require "$Id-executable" ($Actual.executableSha256 -eq $Expected.executableSha256) `
        'Installed executable SHA-256 is byte-identical.'
    Require "$Id-run" ($Actual.runValue -eq $Expected.runValue) `
        'Run value is exact and unchanged.'
    Require "$Id-shortcut" ($Actual.shortcutTarget -eq $Expected.shortcutTarget) `
        'Shortcut target is exact and unchanged.'
}

function Get-OwnedProcesses {
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $fixtureInstallRoot $fixture.ExecutableName))
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $owned = [System.Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name $fixture.ProcessName -ErrorAction SilentlyContinue |
            Where-Object SessionId -eq $session)) {
        try { $path = [IO.Path]::GetFullPath($process.Path) } catch {
            throw 'Candidate process path could not be inspected; cleanup fails closed.'
        }
        if ($path.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            $owned.Add([pscustomobject] @{
                    Id = $process.Id
                    Path = $path
                    StartTicks = $process.StartTime.ToUniversalTime().Ticks
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
    if (-not $samePath -or $process.StartTime.ToUniversalTime().Ticks -ne $Identity.StartTicks) {
        throw 'Refusing to stop a process whose exact identity changed.'
    }
    Stop-Process -Id $Identity.Id -ErrorAction Stop
    if (-not $process.WaitForExit(10000)) { throw 'Exact candidate process did not stop within 10 seconds.' }
}

function Start-Or-AdoptRecoveryHost {
    $owned = @(Get-OwnedProcesses)
    if ($owned.Count -eq 0) {
        $state = Get-State $candidate.productCode
        $process = Start-Process -FilePath $state.executablePath -PassThru
        $owned = @([pscustomobject] @{
                Id = $process.Id
                Path = [IO.Path]::GetFullPath($state.executablePath)
                StartTicks = $process.StartTime.ToUniversalTime().Ticks
            })
    }
    Start-Sleep -Seconds 3
    foreach ($identity in $owned) {
        $process = Get-Process -Id $identity.Id -ErrorAction SilentlyContinue
        Require 'n-plus-1-recovery-process-survives' ($null -ne $process) `
            'N+1 recovery host survives observation.'
        Require 'n-plus-1-recovery-process-path' `
            ([IO.Path]::GetFullPath($process.Path).Equals(
                $identity.Path, [StringComparison]::OrdinalIgnoreCase)) `
            'N+1 recovery PID belongs to the exact installed path.'
    }
    return $owned
}

try {
    $productionClean = Test-JazzProfileClean -InstallerConfiguration $production
    $fixtureClean = Test-JazzProfileClean -CandidateProductCode $baseline.productCode `
        -InstallerConfiguration $fixture
    Require 'production-profile-clean' $productionClean.IsClean `
        'Production product, runtime root, process and resources are absent.'
    Require 'fixture-profile-clean' $fixtureClean.IsClean `
        'Test family and resource root are absent.'
    [void] [IO.Directory]::CreateDirectory($tempLogs)

    Add-Sentinel settings (Join-Path $runtimeRoot 'settings.json') '{"schemaVersion":1}'
    Add-Sentinel capture (Join-Path $runtimeRoot 'captures\.upgrade-matrix-capture') 'capture-sentinel'
    Add-Sentinel journal `
        (Join-Path $runtimeRoot 'captures\.capture-journal\fixture\checkpoint.json') `
        '{"lifecycle":"committed"}'
    Add-Sentinel queue `
        (Join-Path $runtimeRoot 'queue\.upgrade-matrix-package.jazz-archive') `
        'immutable-queue-bytes'
    Add-Sentinel fixtureData `
        (Join-Path $fixtureRoot 'captures\.upgrade-matrix-fixture') `
        'fixture-data-sentinel'
    $sentinelProof.before = [ordered] @{}
    foreach ($sentinel in $sentinels) {
        $sentinelProof.before[$sentinel.Kind] = $sentinel.Sha256
    }

    $phase = 'install-n'
    Require 'install-n' `
        ((Invoke-MatrixMsi '01-install-n' Install $paths[$names[0]]) -eq 0) `
        'Baseline N installs.'
    $snapshots.afterInstallN = Get-ResourceSnapshot $baseline.productCode
    Require 'n-single-registration' ($snapshots.afterInstallN.registrationCount -eq 1) `
        'Exactly N is registered.'
    Assert-Sentinels installN

    $marker = Assert-QualificationChildPath -Root $fixtureInstallRoot `
        -Path (Join-Path $fixtureInstallRoot 'JAZZ_TEST_ONLY_PAYLOAD.txt')
    Require 'repair-marker-present' (Test-Path -LiteralPath $marker) `
        'Owned payload marker exists.'
    Remove-Item -LiteralPath $marker
    $phase = 'repair-n'
    Require 'repair-n' `
        ((Invoke-MatrixMsi '02-repair-n' Repair $paths[$names[0]]) -eq 0) `
        'Exact N repair succeeds.'
    Require 'repair-restores-marker' (Test-Path -LiteralPath $marker) `
        'Exact repair restores deleted owned marker.'
    $snapshots.afterRepair = Get-ResourceSnapshot $baseline.productCode
    Assert-SnapshotEqual repair $snapshots.afterInstallN $snapshots.afterRepair
    Assert-Sentinels repair

    $phase = 'changed-same-version'
    $sameExit = Invoke-MatrixMsi '03-changed-same-version' Install $paths[$names[1]]
    $snapshots.afterChangedSameVersion = Get-ResourceSnapshot $baseline.productCode
    $installedVariant = if (Test-Path $marker) { [IO.File]::ReadAllText($marker).Trim() } else { 'missing' }
    Add-Check changed-same-version-result observed `
        "exit=$sameExit; installedVariant=$installedVariant; inventory=$($snapshots.afterChangedSameVersion.inventory.sha256); packageCode=$($identities[$names[1]].packageCode)."
    $noSideBySide = $snapshots.afterChangedSameVersion.registrationCount -eq 1 -and
        $snapshots.afterChangedSameVersion.registered -and
        -not (Get-State $candidate.productCode).registered
    Require 'changed-same-version-no-side-by-side' $noSideBySide `
        'Observed unsupported behavior creates no side-by-side registration.'
    Assert-Sentinels changedSameVersion

    $phase = 'running-idle-upgrade'
    $installedN = Get-State $baseline.productCode
    $original = Start-Process -FilePath $installedN.executablePath -PassThru
    Start-Sleep -Seconds 3
    Require 'n-host-running' (-not $original.HasExited) 'Exact installed N host is running.'
    Require 'upgrade-running-n' `
        ((Invoke-MatrixMsi '04-running-upgrade' Install $paths[$names[2]]) -eq 0) `
        'Running-idle N to N+1 upgrade succeeds.'
    [void] $original.WaitForExit(15000)
    Require 'restart-manager-closes-original' $original.HasExited `
        'Original exact N PID exits through Restart Manager.'
    $snapshots.afterUpgrade = Get-ResourceSnapshot $candidate.productCode
    $exactExe = Join-Path $fixtureInstallRoot $fixture.ExecutableName
    $exactResources = $snapshots.afterUpgrade.registrationCount -eq 1 -and
        $snapshots.afterUpgrade.registered -and
        $snapshots.afterUpgrade.executableExists -and
        $snapshots.afterUpgrade.runValue -eq ('"' + $exactExe + '"') -and
        $snapshots.afterUpgrade.shortcutTarget -eq $exactExe
    Require 'upgrade-exact-resources' $exactResources `
        'Only exact N+1 registration and resources remain.'
    $recoveryProcesses = @(Start-Or-AdoptRecoveryHost)
    foreach ($identity in $recoveryProcesses) { Stop-OwnedProcess $identity }
    Require 'no-recovery-orphan' (@(Get-OwnedProcesses).Count -eq 0) `
        'No candidate recovery process remains.'
    Assert-Sentinels upgrade

    $beforeDowngrade = Get-ResourceSnapshot $candidate.productCode
    $snapshots.beforeDowngrade = $beforeDowngrade
    $phase = 'downgrade'
    $downgradeExit = Invoke-MatrixMsi '05-downgrade' Install $paths[$names[0]]
    Require 'downgrade-rejected' ($downgradeExit -ne 0) `
        "Downgrade returns $downgradeExit."
    $afterDowngrade = Get-ResourceSnapshot $candidate.productCode
    $snapshots.afterDowngrade = $afterDowngrade
    Assert-SnapshotEqual downgrade $beforeDowngrade $afterDowngrade
    Require 'downgrade-no-n-residue' (-not (Get-State $baseline.productCode).registered) `
        'Rejected downgrade leaves no N registration.'
    Assert-Sentinels downgrade

    $phase = 'rollback-reset'
    Require 'remove-n-plus-1' `
        ((Invoke-MatrixMsi '06-uninstall-next' Uninstall '' $candidate.productCode) -eq 0) `
        'N+1 uninstalls for rollback isolation.'
    Require 'reinstall-n' `
        ((Invoke-MatrixMsi '07-reinstall-n' Install $paths[$names[0]]) -eq 0) `
        'N reinstalls.'
    $beforeRollback = Get-ResourceSnapshot $baseline.productCode
    $snapshots.beforeRollback = $beforeRollback
    Assert-Sentinels rollbackBaseline

    $phase = 'injected-rollback'
    $rollbackExit = Invoke-MatrixMsi '08-injected-rollback' Install $paths[$names[3]]
    Require 'injected-upgrade-fails' ($rollbackExit -ne 0) `
        "Deliberate upgrade returns $rollbackExit."
    $rawLog = [IO.File]::ReadAllText($logs['08-injected-rollback.sanitized.log'])
    $removeEnded = [regex]::Match(
        $rawLog, '(?im)^Action ended.*RemoveExistingProducts.*Return value 1')
    $failureStarted = [regex]::Match(
        $rawLog, '(?im)^Action start.*FailAfterRemoveExisting')
    Require 'rollback-log-completion-order' `
        ($removeEnded.Success -and $failureStarted.Success -and
            $removeEnded.Index -lt $failureStarted.Index) `
        'Log proves successful completion of RemoveExistingProducts before failure action start.'
    $afterRollback = Get-ResourceSnapshot $baseline.productCode
    $snapshots.afterRollback = $afterRollback
    Assert-SnapshotEqual rollback $beforeRollback $afterRollback
    Require 'rollback-no-next-residue' (-not (Get-State $candidate.productCode).registered) `
        'Rollback leaves no N+1 registration.'
    Assert-Sentinels rollback

    $phase = 'recovery-upgrade'
    Require 'upgrade-after-rollback' `
        ((Invoke-MatrixMsi '09-recovery-upgrade' Install $paths[$names[2]]) -eq 0) `
        'Normal upgrade succeeds after rollback.'
    Assert-Sentinels recoveryUpgrade

    $phase = 'final-uninstall'
    Require 'final-uninstall' `
        ((Invoke-MatrixMsi '10-final-uninstall' Uninstall '' $candidate.productCode) -eq 0) `
        'Final uninstall succeeds.'
    $removed = Get-State $candidate.productCode
    $ownedResourcesGone = -not $removed.registered -and
        -not $removed.installRootExists -and
        -not $removed.shortcutExists -and
        $null -eq $removed.runValue
    Require 'final-owned-resources-removed' $ownedResourcesGone `
        'Only installer-owned resources are removed.'
    Assert-Sentinels finalUninstall
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
                if ($cleanupExit -ne 0) { throw "Candidate cleanup returned $cleanupExit." }
            }
        }
        $cleaned = @(Get-OwnedProcesses).Count -eq 0 -and
            -not (Get-State $baseline.productCode).registered -and
            -not (Get-State $candidate.productCode).registered
        Require 'candidate-cleanup' $cleaned `
            'Bounded cleanup removed only exact test candidate processes and ProductCodes.'
    } catch {
        $failed = $true
        Add-Check candidate-cleanup failed (Protect-QualificationText $_.Exception.Message)
    }

    $report = [pscustomobject] [ordered] @{
        '$schema' = '../../qualification/qualification-report.schema.json'
        schemaVersion = 1
        kind = 'automated-msi-upgrade-matrix'
        status = if ($failed) { 'failed' } else { 'passed' }
        generatedAt = [DateTimeOffset]::UtcNow.ToString('O')
        durationMilliseconds = [int64] ([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        source = @{
            commit = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { 'local' }
            runId = $env:GITHUB_RUN_ID
            runAttempt = $env:GITHUB_RUN_ATTEMPT
        }
        package = $baseline
        environment = @{
            osVersion = [Environment]::OSVersion.VersionString
            architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
            processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
            privilege = 'administrator'
            userInteractive = [Environment]::UserInteractive
            sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        }
        failurePhase = $failurePhase
        inventory = @{ packages = @($identities.Values); resourceSnapshots = $snapshots }
        sentinels = $sentinelProof
        checks = @($checks)
        limitations = @(
            'Active-capture and visible review suppression remain interactive clean-profile rows.',
            'Deliberate rollback exists only in isolated test packages and is forbidden in releases.',
            'No backend endpoint or captured content is used.'
        )
    }
    try {
        Write-QualificationEvidence -Report $report -EvidenceDirectory $evidence `
            -RawLogs $logs -AdditionalReplacements @{
                '<MATRIX-DIR>' = $root
                '<TEMP-LOG-DIR>' = $tempLogs
            }
        $json = Get-Content (Join-Path $evidence 'qualification.json') -Raw
        $schema = Get-Content `
            (Join-Path $PSScriptRoot '..\..\qualification\qualification-report.schema.json') -Raw
        if (-not (Test-Json -Json $json -Schema $schema -ErrorAction Stop)) {
            throw 'Upgrade qualification report failed schema validation.'
        }
        Assert-QualificationEvidencePrivacy $evidence
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
        if (Test-QualificationFileHash $sentinel.Path $sentinel.Sha256) {
            Remove-Item -LiteralPath $sentinel.Path
        }
    }
}

if ($failed) { exit 1 }
Write-Host 'Upgrade lifecycle matrix passed on a disposable runner.'
