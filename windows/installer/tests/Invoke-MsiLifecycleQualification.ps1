<#
.SYNOPSIS
    Qualifies one exact Jazz MSI through install, launch, repair and uninstall.

.DESCRIPTION
    This is intentionally hostile to dirty profiles. It performs every read-only preflight before
    creating sentinels or invoking Windows Installer and has no force-clean option. The explicit
    mutation switch acknowledges that a clean disposable profile is being used; it never bypasses
    the clean-profile check.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $MsiPath,
    [Parameter(Mandatory)][string] $ExpectedVersion,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [switch] $AllowInstalledProductMutation,
    [ValidateRange(2, 60)][int] $ProcessObservationSeconds = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MsiQualification.psm1') -Force

$resolvedMsi = (Resolve-Path -LiteralPath $MsiPath).Path
$identity = Get-JazzMsiIdentity -MsiPath $resolvedMsi
$profile = Test-JazzProfileClean -CandidateProductCode $identity.productCode
$jazzRoot = $profile.Footprint.DataRoot
$resolvedEvidence = [IO.Path]::GetFullPath($EvidenceDirectory)
if ($resolvedEvidence -eq [IO.Path]::GetFullPath($jazzRoot) -or
    (Test-QualificationPathWithin -Root $jazzRoot -Path $resolvedEvidence)) {
    throw 'EvidenceDirectory must be outside the Jazz application-data root.'
}

$checks = [System.Collections.Generic.List[object]]::new()
$startedAt = [DateTimeOffset]::UtcNow
$phase = 'preflight'
$failed = $false
$failurePhase = $null
$mutationStarted = $false
$normalUninstallComplete = $false
$launchedProcesses = [System.Collections.Generic.List[object]]::new()
$ownedFiles = [System.Collections.Generic.List[object]]::new()
$ownedDirectories = [System.Collections.Generic.List[string]]::new()
$rawLogs = @{}
$tempLogRoot = $null
$inventory = $null
$postRepairInventory = $null
$sentinelProof = @{}

function Add-Check([string] $Id, [string] $Status, [string] $Detail) {
    $checks.Add([pscustomobject][ordered]@{ id = $Id; status = $Status; detail = $Detail })
}

function Require-Check([string] $Id, [bool] $Condition, [string] $PassDetail, [string] $FailureDetail) {
    if ($Condition) {
        Add-Check $Id 'passed' $PassDetail
        return
    }
    Add-Check $Id 'failed' $FailureDetail
    throw "Qualification check failed: $Id"
}

function Add-OwnedSentinel([string] $Path, [byte[]] $Bytes) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        [void][IO.Directory]::CreateDirectory($parent)
        $ownedDirectories.Add($parent)
    }
    [IO.File]::WriteAllBytes($Path, $Bytes)
    $ownedFiles.Add([pscustomobject]@{ Path = $Path; Sha256 = Get-QualificationSha256 -Path $Path })
}

function Stop-OwnedProcess([int] $Id, [string] $ExpectedPath, [long] $ExpectedStartTimeUtcTicks) {
    $process = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if ($null -eq $process) { return }
    $actualPath = $process.Path
    if ([string]::IsNullOrWhiteSpace($actualPath) -or
        -not [IO.Path]::GetFullPath($actualPath).Equals([IO.Path]::GetFullPath($ExpectedPath), [StringComparison]::OrdinalIgnoreCase) -or
        $process.StartTime.ToUniversalTime().Ticks -ne $ExpectedStartTimeUtcTicks) {
        throw 'Refusing to stop a process whose path/start identity is not the harness-launched candidate.'
    }
    Stop-Process -Id $Id -ErrorAction Stop
    if (-not $process.WaitForExit(10000)) { throw 'The harness-launched process did not exit after a targeted stop.' }
}

function Start-And-Observe([string] $ExecutablePath, [string] $CheckSuffix) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($startInfo)
    $processIdentity = [pscustomobject]@{
        Id = $process.Id
        Path = [IO.Path]::GetFullPath($ExecutablePath)
        StartTimeUtcTicks = $process.StartTime.ToUniversalTime().Ticks
    }
    $launchedProcesses.Add($processIdentity)
    Start-Sleep -Seconds $ProcessObservationSeconds
    $observed = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    Require-Check "process-$CheckSuffix-survives" ($null -ne $observed) `
        'Harness-launched process survived the observation interval.' `
        'Harness-launched process exited during the observation interval.'
    $observedPath = $observed.Path
    Require-Check "process-$CheckSuffix-path" `
        (-not [string]::IsNullOrWhiteSpace($observedPath) -and
            [IO.Path]::GetFullPath($observedPath).Equals([IO.Path]::GetFullPath($ExecutablePath), [StringComparison]::OrdinalIgnoreCase)) `
        'The observed PID belongs to the installed executable.' `
        'The observed PID does not belong to the installed executable.'
    Add-Check "process-$CheckSuffix-session" 'observed' `
        "Process creation and survival were observed in session $($observed.SessionId); this is not tray or UI evidence."
    Stop-OwnedProcess -Id $processIdentity.Id -ExpectedPath $processIdentity.Path `
        -ExpectedStartTimeUtcTicks $processIdentity.StartTimeUtcTicks
}

try {
    Require-Check 'package-name' ($identity.productName -eq 'Jazz Capture') `
        'MSI product name matches Jazz Capture.' 'MSI product name is unexpected.'
    Require-Check 'package-version' ($identity.productVersion -eq $ExpectedVersion) `
        'MSI ProductVersion matches the requested qualification version.' 'MSI ProductVersion differs from the requested version.'
    Require-Check 'package-hash-stable-before-mutation' `
        ((Get-QualificationSha256 -Path $resolvedMsi) -eq $identity.sha256) `
        'The package hash is stable before mutation.' 'The MSI changed while metadata was read.'
    Require-Check 'clean-profile' $profile.IsClean `
        'No Jazz product, process, install footprint, shortcut, Run entry or data root exists.' `
        ('Profile is not clean: ' + ($profile.Reasons -join ', ') + '. No mutation was attempted.')
    Require-Check 'explicit-mutation-opt-in' $AllowInstalledProductMutation.IsPresent `
        'The caller explicitly opted in to candidate install/uninstall mutation.' `
        'The required mutation opt-in switch was not supplied. No mutation was attempted.'

    $phase = 'sentinels'
    $mutationStarted = $true
    $tempLogRoot = Join-Path ([IO.Path]::GetTempPath()) ('jazz-msi-qualification-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($tempLogRoot)
    $rawLogs['msi-install.sanitized.log'] = Join-Path $tempLogRoot 'install.log'
    $rawLogs['msi-repair.sanitized.log'] = Join-Path $tempLogRoot 'repair.log'
    $rawLogs['msi-uninstall.sanitized.log'] = Join-Path $tempLogRoot 'uninstall.log'

    $captureSentinel = Join-Path $jazzRoot 'captures\.jazz-msi-qualification.capture-sentinel'
    $queueSentinel = Join-Path $jazzRoot 'queue\.jazz-msi-qualification.queue-sentinel'
    $settingsSentinel = Join-Path $jazzRoot 'settings.json'
    Add-OwnedSentinel $captureSentinel ([Text.Encoding]::UTF8.GetBytes("Jazz MSI qualification capture sentinel v1`n"))
    Add-OwnedSentinel $queueSentinel ([Text.Encoding]::UTF8.GetBytes("Jazz MSI qualification queue sentinel v1`n"))
    $settingsJson = '{"excludedApplications":["1password","bitwarden","consent.exe","credentialuibroker","dashlane","keepass","lastpass","logonui.exe"],"highlightClicks":false,"narrationEnabled":false,"schemaVersion":1,"screenshotsEnabled":false}'
    Add-OwnedSentinel $settingsSentinel ([Text.Encoding]::UTF8.GetBytes($settingsJson))
    Add-Check 'sentinels-created' 'passed' 'Three inert, harness-owned sentinels were hashed before installation.'

    $phase = 'install'
    $installExit = Invoke-QualificationMsiExec -Operation Install -MsiPath $resolvedMsi -LogPath $rawLogs['msi-install.sanitized.log']
    Require-Check 'install-exit-code' ($installExit -eq 0) "msiexec returned $installExit." "msiexec returned $installExit."

    $installed = Get-JazzInstalledState -ProductCode $identity.productCode
    Require-Check 'installed-registration' $installed.registered 'Candidate ProductCode is registered.' 'Candidate ProductCode is not registered.'
    Require-Check 'installed-executable' $installed.executableExists 'Installed executable exists.' 'Installed executable is missing.'
    $expectedRunValue = '"' + $installed.executablePath + '"'
    Require-Check 'installed-run-entry' ($installed.runValue -eq $expectedRunValue) 'HKCU Run value points exactly to the installed executable.' 'HKCU Run value is missing or incorrect.'
    Require-Check 'installed-shortcut' `
        ($installed.shortcutExists -and $installed.shortcutTarget -eq $installed.executablePath) `
        'Start Menu shortcut targets the installed executable.' 'Start Menu shortcut is missing or targets another path.'
    $versionInfo = (Get-Item -LiteralPath $installed.executablePath).VersionInfo
    Require-Check 'installed-version' `
        ($versionInfo.ProductVersion -like "$ExpectedVersion*" -and $versionInfo.FileVersion -like "$ExpectedVersion*") `
        'Installed file and product versions match the MSI version.' 'Installed executable version does not match the MSI.'
    $inventory = Get-QualificationDirectoryInventory -Root $profile.Footprint.InstallRoot
    Add-Check 'installed-inventory' 'observed' `
        "$($inventory.fileCount) files, $($inventory.byteLength) bytes, aggregate SHA-256 $($inventory.sha256)."

    $phase = 'initial-launch'
    Start-And-Observe -ExecutablePath $installed.executablePath -CheckSuffix 'after-install'

    $phase = 'repair'
    $repairExit = Invoke-QualificationMsiExec -Operation Repair -MsiPath $resolvedMsi -LogPath $rawLogs['msi-repair.sanitized.log']
    Require-Check 'repair-exit-code' ($repairExit -eq 0) "msiexec returned $repairExit." "msiexec returned $repairExit."
    $repaired = Get-JazzInstalledState -ProductCode $identity.productCode
    Require-Check 'repair-registration' $repaired.registered 'Candidate remains registered after repair.' 'Candidate registration is missing after repair.'
    Require-Check 'repair-resources' `
        ($repaired.executableExists -and $repaired.shortcutExists -and $repaired.runValue -eq ('"' + $repaired.executablePath + '"')) `
        'Repair retained the executable, shortcut and exact Run entry.' 'Repair did not retain all installed resources.'
    $postRepairInventory = Get-QualificationDirectoryInventory -Root $profile.Footprint.InstallRoot
    Require-Check 'repair-inventory' ($postRepairInventory.sha256 -eq $inventory.sha256) `
        'Installed inventory is byte-identical after repair.' 'Installed inventory changed during same-package repair.'
    foreach ($owned in $ownedFiles) {
        Require-Check ('repair-sentinel-' + [IO.Path]::GetFileName($owned.Path)) `
            (Test-QualificationFileHash -Path $owned.Path -ExpectedSha256 $owned.Sha256) `
            'Sentinel remains byte-identical after repair.' 'A sentinel changed or disappeared during repair.'
    }

    $phase = 'post-repair-launch'
    Start-And-Observe -ExecutablePath $repaired.executablePath -CheckSuffix 'after-repair'

    $phase = 'uninstall'
    $uninstallExit = Invoke-QualificationMsiExec -Operation Uninstall -ProductCode $identity.productCode -LogPath $rawLogs['msi-uninstall.sanitized.log']
    Require-Check 'uninstall-exit-code' ($uninstallExit -eq 0) "msiexec returned $uninstallExit." "msiexec returned $uninstallExit."
    $normalUninstallComplete = $true
    $removed = Get-JazzInstalledState -ProductCode $identity.productCode
    Require-Check 'uninstall-registration' (-not $removed.registered) 'Candidate ProductCode registration is gone.' 'Candidate ProductCode remains registered.'
    Require-Check 'uninstall-owned-resources' `
        (-not $removed.installRootExists -and -not $removed.executableExists -and -not $removed.shortcutExists -and $null -eq $removed.runValue) `
        'Executable, install root, shortcut and Run entry are gone.' 'One or more installer-owned resources remain.'
    foreach ($owned in $ownedFiles) {
        $safeName = [IO.Path]::GetFileName($owned.Path)
        $matches = Test-QualificationFileHash -Path $owned.Path -ExpectedSha256 $owned.Sha256
        $sentinelProof[$safeName] = [ordered]@{ before = $owned.Sha256; afterUninstall = if ($matches) { $owned.Sha256 } else { 'missing-or-changed' } }
        Require-Check ('uninstall-sentinel-' + $safeName) $matches `
            'Sentinel remains byte-identical after uninstall.' 'A sentinel changed or disappeared during uninstall.'
    }
    Require-Check 'package-hash-stable-after-uninstall' `
        ((Get-QualificationSha256 -Path $resolvedMsi) -eq $identity.sha256) `
        'The exact MSI bytes retain their original SHA-256.' 'The MSI bytes changed during qualification.'
} catch {
    $failed = $true
    $failurePhase = $phase
    Write-Error (Protect-QualificationText -Text $_.Exception.Message) -ErrorAction Continue
} finally {
    $phase = 'cleanup'
    foreach ($processIdentity in @($launchedProcesses)) {
        try {
            Stop-OwnedProcess -Id $processIdentity.Id -ExpectedPath $processIdentity.Path `
                -ExpectedStartTimeUtcTicks $processIdentity.StartTimeUtcTicks
        } catch {
            $failed = $true
            if ($null -eq $failurePhase) { $failurePhase = 'cleanup-process' }
            Add-Check 'cleanup-process' 'failed' 'A harness-launched process could not be safely stopped.'
        }
    }

    if ($mutationStarted -and -not $normalUninstallComplete -and
        (Test-JazzMsiProductRegistered -ProductCode $identity.productCode)) {
        try {
            if ($null -eq $tempLogRoot) {
                $tempLogRoot = Join-Path ([IO.Path]::GetTempPath()) ('jazz-msi-qualification-' + [Guid]::NewGuid().ToString('N'))
                [void][IO.Directory]::CreateDirectory($tempLogRoot)
            }
            $cleanupLog = Join-Path $tempLogRoot 'cleanup-uninstall.log'
            $rawLogs['msi-cleanup-uninstall.sanitized.log'] = $cleanupLog
            $cleanupExit = Invoke-QualificationMsiExec -Operation Uninstall -ProductCode $identity.productCode -LogPath $cleanupLog
            $cleanupState = Get-JazzInstalledState -ProductCode $identity.productCode
            $cleanupComplete = $cleanupExit -eq 0 -and -not $cleanupState.registered -and
                -not $cleanupState.installRootExists -and -not $cleanupState.shortcutExists -and
                $null -eq $cleanupState.runValue
            Add-Check 'cleanup-candidate-uninstall' $(if ($cleanupComplete) { 'passed' } else { 'failed' }) `
                "Candidate-only cleanup returned $cleanupExit and its owned-resource result was recorded."
            if (-not $cleanupComplete) { $failed = $true }
        } catch {
            $failed = $true
            Add-Check 'cleanup-candidate-uninstall' 'failed' 'Candidate-only cleanup could not complete.'
        }
    }

    if ($mutationStarted) {
        $sentinelCleanupSafe = $true
        foreach ($owned in $ownedFiles) {
            if (Test-Path -LiteralPath $owned.Path) {
                if (Test-QualificationFileHash -Path $owned.Path -ExpectedSha256 $owned.Sha256) {
                    Remove-Item -LiteralPath $owned.Path
                } else {
                    $sentinelCleanupSafe = $false
                }
            }
        }
        foreach ($directory in @($ownedDirectories | Sort-Object Length -Descending -Unique)) {
            if ((Test-Path -LiteralPath $directory) -and
                @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
                Remove-Item -LiteralPath $directory
            }
        }
        if ((Test-Path -LiteralPath $jazzRoot) -and @(Get-ChildItem -LiteralPath $jazzRoot -Force).Count -eq 0) {
            Remove-Item -LiteralPath $jazzRoot
        }
        Add-Check 'sentinel-cleanup' $(if ($sentinelCleanupSafe) { 'passed' } else { 'failed' }) `
            $(if ($sentinelCleanupSafe) { 'Only byte-identical harness sentinels were removed.' } else { 'A changed sentinel was retained for inspection.' })
        if (-not $sentinelCleanupSafe) { $failed = $true }
    }

    $report = [pscustomobject][ordered]@{
        '$schema' = '../../qualification/qualification-report.schema.json'
        schemaVersion = 1
        kind = 'automated-msi-lifecycle'
        status = if ($failed) { 'failed' } else { 'passed' }
        generatedAt = [DateTimeOffset]::UtcNow.ToString('O')
        durationMilliseconds = [int64]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        source = [ordered]@{
            commit = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { 'local' }
            runId = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { $null }
            runAttempt = if ($env:GITHUB_RUN_ATTEMPT) { $env:GITHUB_RUN_ATTEMPT } else { $null }
        }
        package = $identity
        environment = [ordered]@{
            osVersion = [Environment]::OSVersion.VersionString
            architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
            processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
            privilege = if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'administrator' } else { 'standard-user' }
            userInteractive = [Environment]::UserInteractive
            sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        }
        failurePhase = $failurePhase
        inventory = [ordered]@{ afterInstall = $inventory; afterRepair = $postRepairInventory }
        sentinels = $sentinelProof
        checks = @($checks)
        limitations = @(
            'Process creation, exact path and survival do not prove tray icon visibility or tray-menu behavior.',
            'No foreground UI, notification, microphone, scaling, secure-desktop or multi-display behavior is claimed.',
            'The MSI is unsigned; interactive SmartScreen and organizational policy behavior require manual evidence.',
            'Upgrade, downgrade, changed-same-version and deliberately failing rollback scenarios are owned by issue #40.',
            'First-run, single-instance, discoverability and update UX scenarios are owned by issue #42.'
        )
    }

    $replacements = @{
        '<PACKAGE-DIR>' = Split-Path -Parent $resolvedMsi
        '<EVIDENCE-DIR>' = $resolvedEvidence
        '<TEMP-LOG-DIR>' = if ($null -eq $tempLogRoot) { '' } else { $tempLogRoot }
    }
    try {
        Write-QualificationEvidence -Report $report -EvidenceDirectory $resolvedEvidence -RawLogs $rawLogs -AdditionalReplacements $replacements
        $reportText = Get-Content -LiteralPath (Join-Path $resolvedEvidence 'qualification.json') -Raw
        $schemaText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\qualification\qualification-report.schema.json') -Raw
        if (-not (Test-Json -Json $reportText -Schema $schemaText -ErrorAction Stop)) {
            throw 'The qualification report does not match its JSON schema.'
        }
    } finally {
        if ($null -ne $tempLogRoot -and (Test-Path -LiteralPath $tempLogRoot)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $tempLogRoot -File)) { Remove-Item -LiteralPath $file.FullName }
            if (@(Get-ChildItem -LiteralPath $tempLogRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $tempLogRoot }
        }
    }
}

if ($failed) { exit 1 }
Write-Host "Qualification passed for MSI SHA-256 $($identity.sha256)."
