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
$production = Get-JazzInstallerConfiguration
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
    # #60 slice 2. Composed from the shared installer configuration's Manufacturer and
    # PolicyValueName -- only the fixture-specific data-folder segment is a literal here, so a
    # future rename of either source property still lines up with what the same Package.wxs the
    # production build compiles actually writes (windows/README.md's "consume Jazz.Version.props,
    # do not repeat literals" rule, a Copilot review finding). Set-StrictMode -Version Latest makes
    # a missing member here a hard throw at the first Get-State call, so both members must be
    # present.
    PolicyKey = 'Software\' + $production.PolicyKey.Split('\')[1] + '\JazzUpgradeFixture\Policy'
    PolicyValueName = $production.PolicyValueName
    # The public MSI property name itself, not a repeated literal (a Copilot review finding): the
    # fixture's Package.wxs compile shares the exact same JazzPolicyPropertyName source as
    # production, so the -Properties arguments this script builds below track a rename instead of
    # silently exercising a property name the built MSI no longer defines.
    PolicyPropertyName = $production.PolicyPropertyName
}
$runtimeRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Jazz'
$fixtureRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'JazzUpgradeFixture'
$fixtureInstallRoot = Join-Path $fixtureRoot 'App'
$checks = [System.Collections.Generic.List[object]]::new()
$logs = @{}
$sentinels = [System.Collections.Generic.List[object]]::new()
$registrySentinels = [System.Collections.Generic.List[object]]::new()
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

function Invoke-MatrixMsi([string] $Name, [string] $Operation, [string] $Package = '', [string] $ProductCode = '', [string[]] $Properties = @()) {
    return Invoke-QualificationMsiExec -Operation $Operation -MsiPath $Package `
        -ProductCode $ProductCode -LogPath (New-Log $Name) -Properties $Properties
}

function Get-State([string] $ProductCode) {
    return Get-JazzInstalledState -ProductCode $ProductCode -InstallerConfiguration $fixture
}

function Get-PolicyValue([string] $ProductCode) {
    return (Get-State $ProductCode).policyValue
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

# A harness-owned, inert value under the fixture's own key, one level above its own
# ...\JazzUpgradeFixture\Policy value -- the same "uninstall removes the value, not the key" proof
# Invoke-MsiLifecycleQualification.ps1 makes for production, in the isolated fixture family (#60
# slice 2).
function Add-RegistrySentinel([string] $Kind, [string] $KeyPath, [string] $Name, [string] $Value) {
    # Fail closed rather than silently overwrite a value already at this exact, harness-owned name
    # -- it can only be a previous interrupted run's own sentinel, and the profile is supposed to
    # be clean before mutation starts (a Copilot review finding, this PR).
    if (Test-Path -LiteralPath $KeyPath) {
        $existing = Get-ItemProperty -LiteralPath $KeyPath -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            throw "Registry sentinel '$Name' already exists under $KeyPath; refusing to overwrite it. A previous run may not have cleaned up."
        }
    }
    Initialize-JazzRegistryKey -KeyPath $KeyPath
    Set-ItemProperty -LiteralPath $KeyPath -Name $Name -Value $Value -Type String
    $registrySentinels.Add([pscustomobject] @{
            Kind = $Kind
            KeyPath = $KeyPath
            Name = $Name
            Value = $Value
        })
}

function Get-RegistrySentinelValue($Sentinel) {
    if (-not (Test-Path -LiteralPath $Sentinel.KeyPath)) { return 'missing' }
    $property = Get-ItemProperty -LiteralPath $Sentinel.KeyPath -Name $Sentinel.Name -ErrorAction SilentlyContinue
    if ($null -eq $property) { return 'missing' }
    return [string] $property.PSObject.Properties[$Sentinel.Name].Value
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
    foreach ($sentinel in $registrySentinels) {
        $actual = Get-RegistrySentinelValue $sentinel
        $proof[$sentinel.Kind] = @{ before = $sentinel.Value; after = $actual }
        # -ceq, not -eq: PowerShell's comparison operators are case-insensitive by default, which
        # would treat a case-only mutation as still byte-identical (a Copilot review finding).
        Require "data-$At-$($sentinel.Kind)" ($actual -ceq $sentinel.Value) `
            "$($sentinel.Kind) registry value remains unchanged."
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
        policyValue = $state.policyValue
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
    Require "$Id-policy" ($Actual.policyValue -eq $Expected.policyValue) `
        'Installer preference value is exact and unchanged.'
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
    # Composed from the fixture's own PolicyKey, one level above ...\JazzUpgradeFixture\Policy, so
    # this sentinel itself sits outside the ...\Policy subtree and would not trip
    # Test-JazzProfileClean's policy-value-present reason. Still created after the clean-profile
    # gate above, as a matter of hygiene consistent with every other sentinel in this harness and
    # with the release-upgrade harness's own ordering (#60 slice 2).
    $fixturePolicyKeySegments = $fixture.PolicyKey.Split('\')
    $fixtureRegistrySentinelKey = 'Registry::HKEY_CURRENT_USER\' + $fixturePolicyKeySegments[0] + '\' +
        $fixturePolicyKeySegments[1] + '\' + $fixturePolicyKeySegments[2]
    Add-RegistrySentinel registryFixture $fixtureRegistrySentinelKey `
        '.jazz-msi-qualification.registry-sentinel' 'Jazz upgrade matrix registry sentinel v1'
    $sentinelProof.before = [ordered] @{}
    foreach ($sentinel in $sentinels) {
        $sentinelProof.before[$sentinel.Kind] = $sentinel.Sha256
    }
    foreach ($sentinel in $registrySentinels) {
        $sentinelProof.before[$sentinel.Kind] = $sentinel.Value
    }

    $phase = 'install-n'
    # #60 slice 2: this proves the installer half of acceptance box 1 -- that a clean-profile
    # install with the property set writes the enforced value into the registry. This is an
    # isolated fixture install: the MSI writes HKCU\Software\Keboola\JazzUpgradeFixture\Policy,
    # while the client this fixture's own binary belongs to would still read the fixed production
    # HKCU\Software\Keboola\Jazz\Policy. So this proves registry persistence only, not that capture
    # actually starts -- that end-to-end claim needs a real client reading the production key,
    # which is a real-machine row (docs/REAL_WINDOWS_QUALIFICATION.md), not this isolated fixture.
    Require 'install-n' `
        ((Invoke-MatrixMsi '01-install-n' Install $paths[$names[0]] '' @("$($fixture.PolicyPropertyName)=1")) -eq 0) `
        'Baseline N installs with the capture-at-launch property set.'
    $snapshots.afterInstallN = Get-ResourceSnapshot $baseline.productCode
    Require 'n-single-registration' ($snapshots.afterInstallN.registrationCount -eq 1) `
        'Exactly N is registered.'
    Require 'install-n-policy-enforced' ($snapshots.afterInstallN.policyValue -eq '1') `
        "A clean-profile install with $($fixture.PolicyPropertyName)=1 writes the enforced value to the registry."
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
    Add-Check changed-same-version-policy observed `
        "policyValue=$($snapshots.afterChangedSameVersion.policyValue)."
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
    # #60 slice 2, acceptance box 5's preservation half: a major upgrade with no property passed
    # must preserve whatever was already deployed.
    Require 'upgrade-policy-preserved' ($snapshots.afterUpgrade.policyValue -eq '1') `
        'A major upgrade with no property preserves the previously deployed installer preference.'
    $recoveryProcesses = @(Start-Or-AdoptRecoveryHost)
    foreach ($identity in $recoveryProcesses) { Stop-OwnedProcess $identity }
    Require 'no-recovery-orphan' (@(Get-OwnedProcesses).Count -eq 0) `
        'No candidate recovery process remains.'
    Assert-Sentinels upgrade

    $phase = 'repair-with-policy-update'
    # Open question 1 (#60 slice 2 plan, section 0): AppSearch remembers whatever is already
    # deployed and overwrites the property with it, including a value supplied on the command
    # line, once a value exists in the profile -- which it always does after the first install.
    # The plan's prediction is that this pass, a same-package REINSTALLMODE=vomus repair run with
    # =0 against a profile that already has 1, reads back 1 -- a repair rather than a version
    # upgrade specifically because it forces AppSearch and the registry-writing component to run
    # again on the identical, already-installed N+1 bytes, which a plain `/i` of the same
    # ProductCode+version might otherwise treat as a no-op. This is deliberately `observed`, not
    # `Require`d: the evidence here is what tells the PR author which sentence to write in
    # docs/INTUNE_DEPLOYMENT.md, rather than the plan's inference doing it.
    Require 'upgrade-policy-update-n-plus-1' `
        ((Invoke-MatrixMsi '04b-running-upgrade-policy-update' Repair $paths[$names[2]] '' @("$($fixture.PolicyPropertyName)=0")) -eq 0) `
        "Same-package repair with $($fixture.PolicyPropertyName)=0 succeeds."
    $observedPolicyAfterUpdate = Get-PolicyValue $candidate.productCode
    Add-Check 'upgrade-policy-update-observed' observed `
        "Reinstalling N+1 with $($fixture.PolicyPropertyName)=0 against a profile already at 1 leaves policyValue=$observedPolicyAfterUpdate."

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
    Require 'final-policy-removed' ($null -eq $removed.policyValue) `
        'Installer preference is removed with the component.'
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
        # Defensive, not a substitute for final-policy-removed above: uninstall is expected to
        # remove the fixture's own policy value entirely, and by the time both ProductCodes are
        # unregistered a re-run of msiexec /x has nothing left to act on. If the value is still
        # here regardless, remove it directly so it cannot poison the next run's fixture-profile-
        # clean gate rather than being left to fail confusingly two runs later -- but only when it
        # is exactly "0" or "1" as REG_SZ, the only values this harness's own scenarios ever write;
        # anything else might belong to a concurrent process, and is retained instead (a Copilot
        # review finding).
        $residualPolicyValue = Get-PolicyValue $candidate.productCode
        if ($null -ne $residualPolicyValue) {
            $fixturePolicyRegistryPath = 'Registry::HKEY_CURRENT_USER\' + $fixture.PolicyKey
            $residualPolicyKind = Get-JazzRegistryValueKind -KeyPath $fixturePolicyRegistryPath -Name $fixture.PolicyValueName
            if (($residualPolicyValue -ceq '0' -or $residualPolicyValue -ceq '1') -and
                $residualPolicyKind -eq [Microsoft.Win32.RegistryValueKind]::String) {
                Remove-ItemProperty -LiteralPath $fixturePolicyRegistryPath -Name $fixture.PolicyValueName -ErrorAction SilentlyContinue
            }
        }
        $cleaned = @(Get-OwnedProcesses).Count -eq 0 -and
            -not (Get-State $baseline.productCode).registered -and
            -not (Get-State $candidate.productCode).registered -and
            $null -eq (Get-PolicyValue $candidate.productCode)
        Require 'candidate-cleanup' $cleaned `
            'Bounded cleanup removed only exact test candidate processes, ProductCodes and the fixture policy value.'
    } catch {
        $failed = $true
        Add-Check candidate-cleanup failed (Protect-QualificationText $_.Exception.Message)
    }

    # File and registry sentinel cleanup runs before the report below is built, not after (a
    # Copilot review finding): doing it afterward let a failed cleanup set $failed while
    # qualification.json had already been serialized as "passed", so the recorded status and the
    # process's own exit code could disagree.
    foreach ($sentinel in $sentinels) {
        if (Test-QualificationFileHash $sentinel.Path $sentinel.Sha256) {
            Remove-Item -LiteralPath $sentinel.Path
        }
    }
    # -ceq, not -eq: PowerShell's comparison operators are case-insensitive by default, which would
    # treat a case-only mutation as still byte-identical (a Copilot review finding).
    foreach ($sentinel in $registrySentinels) {
        if ((Get-RegistrySentinelValue $sentinel) -ceq $sentinel.Value) {
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
}

if ($failed) { exit 1 }
Write-Host 'Upgrade lifecycle matrix passed on a disposable runner.'
