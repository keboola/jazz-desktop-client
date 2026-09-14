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
$registrySentinels = [System.Collections.Generic.List[object]]::new()
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

# An administrator-deployed preference the baseline package knows nothing about (the baseline has
# no policy component at all). The candidate's AppSearch must find it and its component must
# rewrite it, not overwrite it with the default (#60 slice 2, issue #60 section 0).
function Add-RegistrySentinel([string] $Kind, [string] $KeyPath, [string] $Name, [string] $Value, [string] $Type = 'String') {
    $registryPath = 'Registry::HKEY_CURRENT_USER\' + $KeyPath
    # Fail closed rather than silently overwrite a value already at this exact, harness-owned name
    # -- it can only be a previous interrupted run's own sentinel, and the profile is supposed to
    # be clean before mutation starts (a Copilot review finding, this PR).
    if (Test-Path -LiteralPath $registryPath) {
        $existing = Get-ItemProperty -LiteralPath $registryPath -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            throw "Registry sentinel '$Name' already exists under $registryPath; refusing to overwrite it. A previous run may not have cleaned up."
        }
    }
    Initialize-JazzRegistryKey -KeyPath $registryPath
    Set-ItemProperty -LiteralPath $registryPath -Name $Name -Value $Value -Type $Type
    $created = [pscustomobject] @{ Kind = $Kind; KeyPath = $registryPath; Name = $Name; Value = $Value; Type = $Type }
    $registrySentinels.Add($created)
    return $created
}

function Get-RegistrySentinelValue($Sentinel) {
    if (-not (Test-Path -LiteralPath $Sentinel.KeyPath)) { return 'missing' }
    $property = Get-ItemProperty -LiteralPath $Sentinel.KeyPath -Name $Sentinel.Name -ErrorAction SilentlyContinue
    if ($null -eq $property) { return 'missing' }
    return [string] $property.PSObject.Properties[$Sentinel.Name].Value
}

# Value alone is not enough: a REG_SZ "1" and a REG_DWORD 1 stringify identically, so the seeded
# release policy sentinel (REG_DWORD) needs its registry kind checked too, or a kind change would
# be silently accepted as "unchanged" and the sentinel cleanup path could delete a value that only
# looks the same (a Copilot review finding).
function Test-RegistrySentinelUnchanged($Sentinel) {
    if (-not (Test-Path -LiteralPath $Sentinel.KeyPath)) { return $false }
    $actualKind = Get-JazzRegistryValueKind -KeyPath $Sentinel.KeyPath -Name $Sentinel.Name
    $expectedKind = [Microsoft.Win32.RegistryValueKind] $Sentinel.Type
    if ($actualKind -ne $expectedKind) { return $false }
    return (Get-RegistrySentinelValue $Sentinel) -ceq $Sentinel.Value
}

# A parallel proof object to Assert-Data, kept separate rather than folded into its loop: unlike
# every file sentinel, which proves data safety by staying put for the harness's entire run, the
# registry sentinel is *expected* to disappear at uninstall, along with the component that owns
# it -- the opposite assertion, at one specific point.
function Assert-RegistrySentinels([string] $At) {
    # Merged into the SAME $proof[$At] entry Assert-Data just wrote (always called first at every
    # call site below) rather than replacing it outright -- $proof[$At] = $row here would silently
    # discard that call's file-sentinel proof, since both functions key on the same phase name.
    if (-not $proof.Contains($At)) { $proof[$At] = [ordered] @{} }
    foreach ($sentinel in $registrySentinels) {
        $actual = Get-RegistrySentinelValue $sentinel
        $proof[$At][$sentinel.Kind] = @{ before = $sentinel.Value; after = $actual }
        # Value and kind both: a REG_SZ "1" and a REG_DWORD 1 stringify identically, so checking
        # only the text would accept a kind change as "unchanged" (a Copilot review finding).
        Require "data-$At-$($sentinel.Kind)" (Test-RegistrySentinelUnchanged $sentinel) `
            "$($sentinel.Kind) registry value and kind remain unchanged."
    }
}

function Assert-RegistrySentinelsRemoved([string] $At) {
    if (-not $proof.Contains($At)) { $proof[$At] = [ordered] @{} }
    foreach ($sentinel in $registrySentinels) {
        $actual = Get-RegistrySentinelValue $sentinel
        $proof[$At][$sentinel.Kind] = @{ before = $sentinel.Value; after = $actual }
        Require "data-$At-$($sentinel.Kind)-removed" ($actual -ceq 'missing') `
            "$($sentinel.Kind) registry value is removed with its component."
    }
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

    # A fully valid, explicitly *paused* settings document -- not the minimal {"schemaVersion":1}
    # a bare data-safety sentinel would need, because this harness seeds a policy value of "1"
    # below and later launches the real installed executable to test Restart Manager behavior
    # across the running-host upgrade. An explicit pause suppresses automatic capture regardless
    # of which layer would otherwise turn it on -- including an enforced managed policy
    # (windows/README.md's cross-cutting precedence rule) -- so the launched host cannot begin a
    # real, untracked capture on the CI desktop (a Copilot review finding).
    $pausedSettingsJson = '{"captureAtLaunchEnabled":false,"captureAtLaunchPaused":true,' +
        '"excludedApplications":["1password","bitwarden","consent.exe","credentialuibroker",' +
        '"dashlane","keepass","lastpass","logonui.exe"],"highlightClicks":false,' +
        '"narrationEnabled":false,"schemaVersion":1,"screenshotsEnabled":false}'
    Add-Sentinel settings (Join-Path $root 'settings.json') $pausedSettingsJson
    Add-Sentinel capture (Join-Path $root 'captures\.release-upgrade-capture') 'capture'
    Add-Sentinel journal (Join-Path $root 'captures\.capture-journal\fixture\checkpoint.json') `
        '{"lifecycle":"committed"}'
    Add-Sentinel queue (Join-Path $root 'queue\.release-upgrade.jazz-archive') 'queue'
    # An administrator-deployed preference the baseline package knows nothing about. The candidate's
    # AppSearch must find it and its component must rewrite it, not overwrite it with the default.
    # Seeded as REG_DWORD, not REG_SZ: this is exactly the Intune settings-catalog/ADMX deployment
    # shape (windows/README.md's "Both keys accept a REG_DWORD or a REG_SZ value"), and it directly
    # exercises the round-trip Package.wxs's own comments describe -- RememberCaptureAtLaunch's raw
    # RegistrySearch reconstructing the '#' marker from an existing DWORD so the write below
    # reconstructs REG_DWORD, unchanged, rather than silently flipping it to REG_SZ (a Copilot
    # review finding: no automated scenario exercised this before).
    $policySentinel = Add-RegistrySentinel policy $config.PolicyKey $config.PolicyValueName '1' -Type DWord
    $proof.before = [ordered] @{}
    foreach ($sentinel in $sentinels) { $proof.before[$sentinel.Kind] = $sentinel.Hash }
    foreach ($sentinel in $registrySentinels) { $proof.before[$sentinel.Kind] = $sentinel.Value }

    $phase = 'baseline-install'
    Require 'baseline-install' `
        ((Invoke-MatrixMsi '01-baseline-install' Install $baselinePath) -eq 0) `
        'Exact baseline bytes install.'
    $snapshots.baseline = Get-Snapshot $baseline.productCode
    Require 'baseline-registration' ($snapshots.baseline.registrationCount -eq 1) `
        'Exactly baseline is registered.'
    Assert-Data baselineInstall
    # The baseline predates #60 slice 2 entirely -- it has no policy component, so of course it
    # must not touch the administrator-deployed value seeded above.
    Assert-RegistrySentinels baselineInstall

    $phase = 'baseline-repair'
    Require 'baseline-repair' `
        ((Invoke-MatrixMsi '02-baseline-repair' Repair $baselinePath) -eq 0) `
        'Exact baseline repair succeeds.'
    Assert-SnapshotEqual baselineRepair $snapshots.baseline (Get-Snapshot $baseline.productCode)
    Assert-Data baselineRepair
    Assert-RegistrySentinels baselineRepair

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
    # #60 slice 2: the candidate is the first package in this chain with a policy component. Its
    # AppSearch must find the administrator-deployed value the baseline never wrote and its
    # component must rewrite it unchanged -- never overwrite it with the "0" default.
    $candidatePolicyValue = Get-RegistrySentinelValue $policySentinel
    Require 'candidate-policy-preserved' `
        ($candidatePolicyValue -eq '1' -and
            (Get-JazzRegistryValueKind -KeyPath $policySentinel.KeyPath -Name $policySentinel.Name) -eq
                [Microsoft.Win32.RegistryValueKind]::DWord) `
        "Candidate upgrade preserves the administrator-deployed installer preference as REG_DWORD, found '$candidatePolicyValue'."
    Assert-RegistrySentinels candidateUpgrade

    $beforeDowngrade = Get-Snapshot $candidate.productCode
    $phase = 'downgrade'
    $downgradeExit = Invoke-MatrixMsi '04-downgrade' Install $baselinePath
    Require 'downgrade-rejected' ($downgradeExit -ne 0) `
        "Downgrade returns $downgradeExit."
    Assert-SnapshotEqual downgrade $beforeDowngrade (Get-Snapshot $candidate.productCode)
    Require 'no-baseline-residue' (-not (Get-State $baseline.productCode).registered) `
        'Rejected downgrade leaves no baseline registration.'
    Assert-Data downgrade
    Assert-RegistrySentinels downgrade

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
    $repairedPolicyValue = Get-RegistrySentinelValue $policySentinel
    Require 'candidate-repair-policy-preserved' `
        ($repairedPolicyValue -eq '1' -and
            (Get-JazzRegistryValueKind -KeyPath $policySentinel.KeyPath -Name $policySentinel.Name) -eq
                [Microsoft.Win32.RegistryValueKind]::DWord) `
        "Candidate repair preserves the administrator-deployed installer preference as REG_DWORD, found '$repairedPolicyValue'."
    Assert-RegistrySentinels candidateRepair

    $phase = 'uninstall'
    Require 'candidate-uninstall' `
        ((Invoke-MatrixMsi '06-candidate-uninstall' Uninstall '' $candidate.productCode) -eq 0) `
        'Candidate uninstall succeeds.'
    $removed = Get-State $candidate.productCode
    Require 'owned-resources-removed' `
        (-not $removed.registered -and -not $removed.installRootExists -and
            $null -eq $removed.runValue -and -not $removed.shortcutExists) `
        'Only installer-owned resources are removed.'
    Require 'candidate-policy-removed' ($null -eq $removed.policyValue) `
        'Installer preference is removed with the component.'
    Assert-Data uninstall
    Assert-RegistrySentinelsRemoved uninstall
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

    # File and registry sentinel cleanup runs before the report below is built, not after (a
    # Copilot review finding): doing it afterward let a failed cleanup set $failed while
    # qualification.json had already been serialized as "passed", so the recorded status and the
    # process's own exit code could disagree.
    foreach ($sentinel in $sentinels) {
        if (Test-QualificationFileHash $sentinel.Path $sentinel.Hash) {
            Remove-Item -LiteralPath $sentinel.Path
        }
    }
    # Expected gone already, by the candidate uninstall step above; this only cleans up a sentinel
    # a failed run left behind, and only if it is still exactly what was seeded -- value and kind
    # both, since a REG_SZ "1" and a REG_DWORD 1 stringify identically (a Copilot review finding).
    foreach ($sentinel in $registrySentinels) {
        if (Test-RegistrySentinelUnchanged $sentinel) {
            Remove-ItemProperty -LiteralPath $sentinel.KeyPath -Name $sentinel.Name -ErrorAction SilentlyContinue
            if ((Get-RegistrySentinelValue $sentinel) -ceq $sentinel.Value) {
                # Still there after the removal attempt: fail closed.
                $failed = $true
            }
        }
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
}

if ($failed) { exit 1 }
Write-Host 'Exact baseline-to-candidate release upgrade qualification passed.'
