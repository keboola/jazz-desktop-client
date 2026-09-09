<#
.SYNOPSIS
    Runs one resumable stage of interactive Windows MSI qualification.

.DESCRIPTION
    Prepare installs into a clean standard-user profile and writes a DPAPI-authenticated state file.
    End that invocation before logging out. Resume validates that state against the exact MSI and
    records observations after the next logon; it can be rerun after interruption. Complete accepts
    the installed candidate only through the same state binding and uninstalls only its ProductCode
    after the operator repeats the run ID.

    A secondary profile starts its own Prepare run with the primary run ID as a privacy-safe link.
    Its isolation result remains explicit operator attestation, not automatic cross-profile proof.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Resume', 'Complete')][string] $Phase,
    [Parameter(Mandatory)][string] $MsiPath,
    [Parameter(Mandatory)][string] $ExpectedVersion,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedSha256,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [ValidateSet('primary', 'secondary')][string] $ProfileRole = 'primary',
    [string] $RelatedPrimaryRunId,
    [string] $ConfirmUninstallRunId,
    [switch] $AllowInstalledProductMutation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$startedAt = [DateTimeOffset]::UtcNow
$module = Join-Path $PSScriptRoot '..\installer\tests\MsiQualification.psm1'
Import-Module $module -Force

$resolvedMsi = (Resolve-Path -LiteralPath $MsiPath).Path
$resolvedEvidence = [IO.Path]::GetFullPath($EvidenceDirectory)
$installerConfiguration = Get-JazzInstallerConfiguration
$identity = Get-JazzMsiIdentity -MsiPath $resolvedMsi
$jazzRoot = (Get-JazzProfileFootprint -CandidateProductCode $identity.productCode `
    -InstallerConfiguration $installerConfiguration).DataRoot
if ($resolvedEvidence -eq [IO.Path]::GetFullPath($jazzRoot) -or
    (Test-QualificationPathWithin -Root $jazzRoot -Path $resolvedEvidence)) {
    throw 'EvidenceDirectory must be outside the Jazz application-data root. No mutation was attempted.'
}
$statePath = Join-Path $resolvedEvidence 'qualification-state.json'
$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$checks = [System.Collections.Generic.List[object]]::new()
$state = $null
$failed = $false
$failurePhase = $null
$tempRoot = $null
$rawLogs = @{}
$installedDuringPrepare = $false

function Set-StateCheck([string] $Id, [string] $Status, [string] $Detail) {
    $existing = @($checks | Where-Object { $_.id -eq $Id })
    foreach ($item in $existing) { [void]$checks.Remove($item) }
    $checks.Add([pscustomobject][ordered]@{ id = $Id; status = $Status; detail = $Detail })
    if ($null -ne $state) {
        $state.checks = @($checks)
        $state.updatedAt = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        Write-QualificationResumeState -State $state -StatePath $statePath
    }
}

function Read-ManualStatus([string] $Id, [string] $Instruction, [string] $EvidenceKind = 'operator-observed') {
    Write-Host "`n[$Id] $Instruction" -ForegroundColor Cyan
    while ($true) {
        $answer = (Read-Host 'Enter passed, failed, blocked, or not-run').Trim().ToLowerInvariant()
        if ($answer -in @('passed', 'failed', 'blocked', 'not-run')) {
            Set-StateCheck $Id $answer "$EvidenceKind; no capture content or free-form operator text is retained."
            return
        }
        Write-Host 'Use exactly: passed, failed, blocked, or not-run.' -ForegroundColor Yellow
    }
}

function Assert-ExactInstalledCandidate {
    $installed = Get-JazzInstalledState -ProductCode $identity.productCode `
        -InstallerConfiguration $installerConfiguration
    $footprint = Get-JazzProfileFootprint -CandidateProductCode $identity.productCode `
        -InstallerConfiguration $installerConfiguration
    if (-not $installed.registered -or -not $installed.executableExists -or
        -not $installed.shortcutExists -or $footprint.ProductCount -ne 1) {
        throw 'The current profile does not contain exactly the state-bound installed candidate.'
    }
    $expectedRun = '"' + $installed.executablePath + '"'
    if ($installed.runValue -ne $expectedRun -or $installed.shortcutTarget -ne $installed.executablePath) {
        throw 'The state-bound candidate footprint does not match its expected Run entry and shortcut.'
    }
    return $installed
}

function Write-StageReport {
    $failedCount = @($checks | Where-Object { $_.status -eq 'failed' }).Count
    $incompleteCount = @($checks | Where-Object { $_.status -in @('blocked', 'not-run') }).Count
    $complete = $null -ne $state -and $state.phase -eq 'completed'
    $requiredChecks = if ($null -eq $state) {
        @()
    } elseif ($state.binding.profileRole -eq 'primary') {
        @(
            'interactive-install', 'resume-state', 'login-startup', 'unsigned-policy',
            'tray-start-menu', 'capture-review-relaunch', 'microphone-allow-deny-revoke',
            'elevated-target', 'secure-desktop', 'display-scaling', 'mixed-displays',
            'interactive-uninstall'
        )
    } else {
        @(
            'interactive-install', 'resume-state', 'secondary-login-startup',
            'second-profile-isolation-attestation', 'secondary-tray-start-menu',
            'interactive-uninstall'
        )
    }
    $recordedIds = @($checks | ForEach-Object { $_.id })
    $missingRequired = @($requiredChecks | Where-Object { $_ -notin $recordedIds }).Count
    $status = if ($failed -or $failedCount -gt 0) {
        'failed'
    } elseif (-not $complete -or $incompleteCount -gt 0 -or $missingRequired -gt 0) {
        'incomplete'
    } else {
        'passed'
    }
    $run = if ($null -eq $state) { $null } else {
        [ordered]@{
            runId = $state.binding.runId
            profileRole = $state.binding.profileRole
            relatedPrimaryRunId = $state.binding.relatedPrimaryRunId
            phase = $state.phase
        }
    }
    $report = [pscustomobject][ordered]@{
        '$schema' = 'qualification-report.schema.json'
        schemaVersion = 1
        kind = 'manual-real-windows'
        status = $status
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
            privilege = if ($isAdministrator) { 'administrator' } else { 'standard-user' }
            userInteractive = [Environment]::UserInteractive
            sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        }
        run = $run
        failurePhase = $failurePhase
        inventory = $null
        sentinels = $null
        checks = @($checks)
        limitations = @(
            'Statuses are explicit operator observations; reports contain no screenshots, recordings, usernames, machine names, SIDs, profile paths or free-form notes.',
            'A secondary-profile isolation result is operator attestation linked by run ID, not automatic cross-profile inspection.',
            'ARM64 is unqualified; the current package is win-x64.',
            'Issue #40 owns changed-same-version, upgrade, downgrade and deliberately failing rollback evidence.',
            'Issue #42 owns first-run, single-instance, discoverability and update UX.'
        )
    }
    Write-QualificationEvidence -Report $report -EvidenceDirectory $resolvedEvidence -RawLogs $rawLogs -AdditionalReplacements @{
        '<PACKAGE-DIR>' = Split-Path -Parent $resolvedMsi
        '<EVIDENCE-DIR>' = $resolvedEvidence
        '<TEMP-LOG-DIR>' = if ($null -eq $tempRoot) { '' } else { $tempRoot }
    }
    $reportText = Get-Content -LiteralPath (Join-Path $resolvedEvidence 'qualification.json') -Raw
    $schemaText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'qualification-report.schema.json') -Raw
    if (-not (Test-Json -Json $reportText -Schema $schemaText -ErrorAction Stop)) {
        throw 'The manual qualification report does not match its JSON schema.'
    }
    return $status
}

try {
    if ($identity.productVersion -ne $ExpectedVersion) { throw 'MSI ProductVersion does not match ExpectedVersion.' }
    if ($identity.sha256 -ne $ExpectedSha256.ToLowerInvariant()) { throw 'MSI SHA-256 does not match ExpectedSha256.' }
    if ($isAdministrator) { throw 'Interactive qualification must run in a non-elevated standard-user session.' }

    switch ($Phase) {
        'Prepare' {
            $failurePhase = 'prepare-preflight'
            $profile = Test-JazzProfileClean -CandidateProductCode $identity.productCode `
                -InstallerConfiguration $installerConfiguration
            if (-not $profile.IsClean) {
                Set-StateCheck 'clean-profile' 'failed' ('Dirty profile: ' + ($profile.Reasons -join ', ') + '. No mutation was attempted.')
                throw 'Prepare requires a dedicated clean profile.'
            }
            if (-not $AllowInstalledProductMutation) { throw 'Prepare requires -AllowInstalledProductMutation. No mutation was attempted.' }
            if (Test-Path -LiteralPath $statePath) { throw 'Prepare refuses to replace an existing qualification state file.' }
            if ($ProfileRole -eq 'secondary' -and [string]::IsNullOrWhiteSpace($RelatedPrimaryRunId)) {
                throw 'Secondary Prepare requires -RelatedPrimaryRunId from the primary Prepare stage.'
            }

            [void][IO.Directory]::CreateDirectory($resolvedEvidence)
            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('jazz-real-windows-prepare-' + [Guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($tempRoot)
            $installLog = Join-Path $tempRoot 'interactive-install.log'
            $cleanupLog = Join-Path $tempRoot 'prepare-cleanup-uninstall.log'
            $rawLogs['msi-interactive-install.sanitized.log'] = $installLog
            $rawLogs['msi-prepare-cleanup.sanitized.log'] = $cleanupLog

            Write-Host 'The exact package and clean profile are verified. The installer UI will open.' -ForegroundColor Green
            $failurePhase = 'prepare-install'
            $installExit = Invoke-QualificationMsiExec -Operation Install -MsiPath $resolvedMsi -LogPath $installLog -Interactive
            if ($installExit -ne 0) { throw "Interactive install returned $installExit." }
            $installedDuringPrepare = $true
            [void](Assert-ExactInstalledCandidate)

            $state = New-QualificationResumeState -MsiIdentity $identity -ProfileRole $ProfileRole `
                -RelatedPrimaryRunId $RelatedPrimaryRunId -StatePath $statePath
            $checks.Clear()
            Set-StateCheck 'interactive-install' 'passed' 'Exact MSI installed and candidate footprint verified in a clean standard-user profile.'
            $state.phase = 'installed'
            $state.updatedAt = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            Write-QualificationResumeState -State $state -StatePath $statePath
            $failurePhase = $null

            Write-Host "`nPrepare complete. Run ID: $($state.binding.runId)" -ForegroundColor Green
            Write-Host 'End this shell, log out and back into this same profile, then run -Phase Resume with the same MSI, digest and evidence directory.'
            if ($ProfileRole -eq 'primary') {
                Write-Host 'Keep this run ID: a secondary profile must bind it with -RelatedPrimaryRunId.'
            }
        }
        'Resume' {
            $failurePhase = 'resume-state'
            $state = Read-QualificationResumeState -StatePath $statePath -ExpectedMsiIdentity $identity
            if ($state.phase -eq 'completed') { throw 'This qualification run is already completed and cannot be resumed.' }
            foreach ($check in @($state.checks)) { $checks.Add($check) }
            [void](Assert-ExactInstalledCandidate)
            Set-StateCheck 'resume-state' 'passed' 'DPAPI-authenticated state and exact installed candidate were verified for this profile.'
            $state.phase = 'observed'
            $state.updatedAt = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            Write-QualificationResumeState -State $state -StatePath $statePath
            $failurePhase = 'resume-observations'

            if ($state.binding.profileRole -eq 'primary') {
                Read-ManualStatus 'login-startup' 'After the completed logon, confirm the state-bound candidate started from the HKCU Run entry.'
                Read-ManualStatus 'unsigned-policy' 'Record the actual SmartScreen or organizational-policy result shown for this unsigned package.'
                Read-ManualStatus 'tray-start-menu' 'Confirm a visible tray icon/menu, quit, and Start Menu relaunch of the installed executable.'
                Read-ManualStatus 'capture-review-relaunch' 'Using non-sensitive test content, capture, label, review, quit and relaunch; confirm evidence remains local.'
                Read-ManualStatus 'microphone-allow-deny-revoke' 'Exercise microphone allow, deny and revoke with synthetic narration; confirm each state is reported honestly.'
                Read-ManualStatus 'elevated-target' 'Exercise normal and elevated UI Automation targets with test content; record explicit degradation across the integrity boundary.'
                Read-ManualStatus 'secure-desktop' 'Trigger a test secure-desktop boundary and confirm Jazz does not claim evidence it could not observe.'
                Read-ManualStatus 'display-scaling' 'Exercise 100%, 150%, and 200% scaling and verify target/screenshot alignment.'
                Read-ManualStatus 'mixed-displays' 'Exercise multiple displays, preferably mixed scaling, and verify capture boundaries and target alignment.'
            } else {
                Read-ManualStatus 'secondary-login-startup' 'After logon to this secondary profile, confirm its own state-bound candidate started from its own HKCU Run entry.'
                Read-ManualStatus 'second-profile-isolation-attestation' `
                    'While the linked primary run remains intact, attest that this profile has independent HKCU/Jazz state and cannot see the primary test capture.' `
                    'operator-attested cross-profile result linked only by primary run ID'
                Read-ManualStatus 'secondary-tray-start-menu' 'Confirm the secondary profile has its own usable tray and Start Menu launch.'
            }
            $failurePhase = $null
            Write-Host "`nResume observations saved. Re-run Resume to replace any status, or quit Jazz and run Complete." -ForegroundColor Green
        }
        'Complete' {
            $failurePhase = 'complete-state'
            $state = Read-QualificationResumeState -StatePath $statePath -ExpectedMsiIdentity $identity
            foreach ($check in @($state.checks)) { $checks.Add($check) }
            if ($state.phase -eq 'completed') { throw 'This qualification run is already completed.' }
            $installed = Assert-ExactInstalledCandidate
            if (-not $AllowInstalledProductMutation) { throw 'Complete requires -AllowInstalledProductMutation.' }
            if ($ConfirmUninstallRunId -cne $state.binding.runId) {
                throw 'Complete requires -ConfirmUninstallRunId equal to the authenticated state run ID.'
            }

            $currentSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
            $processBlocksUninstall = $false
            foreach ($process in @(Get-Process -Name $installerConfiguration.ProcessName -ErrorAction SilentlyContinue)) {
                $processSessionId = $null
                $processPath = $null
                $inspectionFailed = $false
                try {
                    $processSessionId = $process.SessionId
                    if ($processSessionId -eq $currentSessionId) { $processPath = $process.Path }
                } catch {
                    $inspectionFailed = $true
                }
                if (Test-JazzProcessBlocksCandidateUninstall `
                        -ProcessSessionId $processSessionId `
                        -CurrentSessionId $currentSessionId `
                        -ProcessPath $processPath `
                        -ExpectedExecutablePath $installed.executablePath `
                        -InspectionFailed:$inspectionFailed) {
                    $processBlocksUninstall = $true
                    break
                }
            }
            if ($processBlocksUninstall) {
                throw "Quit this profile's Jazz from the tray before Complete; the runner will not terminate it."
            }

            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('jazz-real-windows-complete-' + [Guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($tempRoot)
            $uninstallLog = Join-Path $tempRoot 'interactive-uninstall.log'
            $rawLogs['msi-interactive-uninstall.sanitized.log'] = $uninstallLog
            $failurePhase = 'complete-uninstall'
            $uninstallExit = Invoke-QualificationMsiExec -Operation Uninstall -ProductCode $identity.productCode -LogPath $uninstallLog -Interactive
            if ($uninstallExit -ne 0) {
                Set-StateCheck 'interactive-uninstall' 'failed' "Candidate-specific msiexec returned $uninstallExit."
                throw "Interactive uninstall returned $uninstallExit."
            }
            $removed = Get-JazzInstalledState -ProductCode $identity.productCode `
                -InstallerConfiguration $installerConfiguration
            $ownedResourcesGone = -not $removed.registered -and -not $removed.installRootExists -and
                -not $removed.shortcutExists -and $null -eq $removed.runValue
            if (-not $ownedResourcesGone) {
                Set-StateCheck 'interactive-uninstall' 'failed' 'Candidate uninstall left an installer-owned resource.'
                throw 'Interactive uninstall footprint verification failed.'
            }
            Set-StateCheck 'interactive-uninstall' 'passed' 'Candidate ProductCode and installer-owned resources are gone; user data was not removed.'
            $state.phase = 'completed'
            $state.updatedAt = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            Write-QualificationResumeState -State $state -StatePath $statePath
            $failurePhase = $null
            Write-Host 'Complete stage finished. The authenticated state file remains with the evidence.' -ForegroundColor Green
        }
    }
} catch {
    $failed = $true
    if ($null -eq $failurePhase) { $failurePhase = $Phase.ToLowerInvariant() }
    if ($Phase -eq 'Prepare' -and $installedDuringPrepare -and
        (Test-JazzMsiProductRegistered -ProductCode $identity.productCode) -and $null -eq $state) {
        try {
            $cleanupLog = if ($null -ne $tempRoot) { Join-Path $tempRoot 'prepare-cleanup-uninstall.log' } else {
                $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('jazz-real-windows-cleanup-' + [Guid]::NewGuid().ToString('N'))
                [void][IO.Directory]::CreateDirectory($tempRoot)
                Join-Path $tempRoot 'prepare-cleanup-uninstall.log'
            }
            $rawLogs['msi-prepare-cleanup.sanitized.log'] = $cleanupLog
            $cleanupExit = Invoke-QualificationMsiExec -Operation Uninstall -ProductCode $identity.productCode -LogPath $cleanupLog
            Set-StateCheck 'prepare-failure-cleanup' $(if ($cleanupExit -eq 0) { 'passed' } else { 'failed' }) `
                "Candidate-specific cleanup returned $cleanupExit."
        } catch {
            Set-StateCheck 'prepare-failure-cleanup' 'failed' 'Candidate-specific cleanup could not complete.'
        }
    }
    Write-Error (Protect-QualificationText -Text $_.Exception.Message) -ErrorAction Continue
} finally {
    try {
        $resultStatus = Write-StageReport
    } finally {
        if ($null -ne $tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $tempRoot -File)) { Remove-Item -LiteralPath $file.FullName }
            if (@(Get-ChildItem -LiteralPath $tempRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $tempRoot }
        }
    }
}

if ($failed) { exit 1 }
Write-Host "Stage $Phase finished with report status $resultStatus."
