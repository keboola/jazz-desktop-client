[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MsiQualification.psm1') -Force

$passed = 0
function Assert-Equal([string] $Name, $Actual, $Expected) {
    if ($Actual -ne $Expected) { throw "$Name failed: expected '$Expected', found '$Actual'." }
    $script:passed++
    Write-Host "PASS $Name"
}

function Assert-True([string] $Name, [bool] $Condition) {
    if (-not $Condition) { throw "$Name failed." }
    $script:passed++
    Write-Host "PASS $Name"
}

function Assert-Throws([string] $Name, [scriptblock] $Action) {
    try { & $Action } catch {
        $script:passed++
        Write-Host "PASS $Name"
        return
    }
    throw "$Name failed: the action did not throw."
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('jazz-qualification-helper-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $child = Join-Path $testRoot 'child\report.json'
    Assert-Equal 'strict child path accepted' `
        (Assert-QualificationChildPath -Root $testRoot -Path $child) `
        ([IO.Path]::GetFullPath($child))
    Assert-Throws 'root itself rejected as child' {
        Assert-QualificationChildPath -Root $testRoot -Path $testRoot
    }
    Assert-Throws 'sibling rejected as child' {
        Assert-QualificationChildPath -Root $testRoot -Path ($testRoot + '-sibling\file')
    }

    $msiPath = Join-Path $testRoot 'package with spaces\Jazz.msi'
    $logPath = Join-Path $testRoot 'logs with spaces\install.log'
    $arguments = @(Get-QualificationMsiExecArguments -Operation Install -MsiPath $msiPath -LogPath $logPath)
    Assert-Equal 'msiexec path remains one argument' $arguments[1] ([IO.Path]::GetFullPath($msiPath))
    Assert-True 'msiexec path is not shell-quoted' (-not $arguments[1].Contains('"'))
    Assert-Equal 'quiet install switch' $arguments[2] '/qn'
    Assert-Throws 'uninstall requires ProductCode' {
        Get-QualificationMsiExecArguments -Operation Uninstall -LogPath $logPath
    }

    $currentSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $expectedProcessPath = Join-Path $testRoot 'candidate\JazzCandidate.exe'
    Assert-True 'current-session exact candidate blocks uninstall' `
        (Test-JazzProcessBlocksCandidateUninstall -ProcessSessionId $currentSessionId `
            -CurrentSessionId $currentSessionId -ProcessPath $expectedProcessPath `
            -ExpectedExecutablePath $expectedProcessPath)
    Assert-True 'current-session blank process path fails closed' `
        (Test-JazzProcessBlocksCandidateUninstall -ProcessSessionId $currentSessionId `
            -CurrentSessionId $currentSessionId -ProcessPath '' `
            -ExpectedExecutablePath $expectedProcessPath)
    Assert-True 'current-session path inspection race fails closed' `
        (Test-JazzProcessBlocksCandidateUninstall -ProcessSessionId $currentSessionId `
            -CurrentSessionId $currentSessionId -ProcessPath $null `
            -ExpectedExecutablePath $expectedProcessPath -InspectionFailed)
    Assert-True 'unreadable process session fails closed' `
        (Test-JazzProcessBlocksCandidateUninstall -ProcessSessionId $null `
            -CurrentSessionId $currentSessionId -ProcessPath $null `
            -ExpectedExecutablePath $expectedProcessPath -InspectionFailed)
    Assert-True 'different-session process does not block this profile' `
        (-not (Test-JazzProcessBlocksCandidateUninstall -ProcessSessionId ($currentSessionId + 1) `
            -CurrentSessionId $currentSessionId -ProcessPath $null `
            -ExpectedExecutablePath $expectedProcessPath))
    Assert-True 'different current-session executable does not impersonate candidate' `
        (-not (Test-JazzProcessBlocksCandidateUninstall -ProcessSessionId $currentSessionId `
            -CurrentSessionId $currentSessionId -ProcessPath (Join-Path $testRoot 'other\JazzCandidate.exe') `
            -ExpectedExecutablePath $expectedProcessPath))

    # Prove that qualification derives every drift-prone installed identity from the same props
    # consumed by both MSI authorings and verifiers. This changes only a GUID-named temp copy.
    $sourcePropsPath = Join-Path $PSScriptRoot '..\Jazz.Version.props'
    [xml]$fakePropsDocument = Get-Content -LiteralPath $sourcePropsPath -Raw
    $fakePropertyGroup = $fakePropsDocument.Project.PropertyGroup
    $fakePropertyGroup.JazzProductName = 'Qualification Product'
    $fakePropertyGroup.JazzDataFolderName = 'QualificationData'
    $fakePropertyGroup.JazzInstallFolderName = 'Payload'
    $fakePropertyGroup.JazzRunValueName = 'QualificationRun'
    $fakePropertyGroup.JazzExecutableName = 'QualificationHost.exe'
    $fakePropertyGroup.JazzStartMenuFolderName = 'Qualification Menu'
    $fakePropertyGroup.JazzShortcutName = 'Qualification Shortcut'
    $fakePropsPath = Join-Path $testRoot 'Jazz.Test.Version.props'
    $fakePropsDocument.Save($fakePropsPath)
    $fakeConfiguration = Get-JazzInstallerConfiguration -VersionPropsPath $fakePropsPath
    Assert-Equal 'product display name follows props' $fakeConfiguration.ProductName 'Qualification Product'
    Assert-Equal 'data folder follows props' $fakeConfiguration.DataFolderName 'QualificationData'
    Assert-Equal 'install folder follows props' $fakeConfiguration.InstallFolderName 'Payload'
    Assert-Equal 'Run value name follows props' $fakeConfiguration.RunValueName 'QualificationRun'
    Assert-Equal 'executable name follows props' $fakeConfiguration.ExecutableName 'QualificationHost.exe'
    Assert-Equal 'process name derives from executable property' $fakeConfiguration.ProcessName 'QualificationHost'
    Assert-Equal 'Start Menu folder follows props' $fakeConfiguration.StartMenuFolderName 'Qualification Menu'
    Assert-Equal 'shortcut name follows props' $fakeConfiguration.ShortcutName 'Qualification Shortcut'
    $fakeFootprint = Get-JazzProfileFootprint -InstallerConfiguration $fakeConfiguration
    Assert-Equal 'profile data path follows configuration' $fakeFootprint.DataRoot `
        (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'QualificationData')
    Assert-Equal 'profile install path follows configuration' $fakeFootprint.InstallRoot `
        (Join-Path $fakeFootprint.DataRoot 'Payload')
    $expectedShortcut = Join-Path `
        (Join-Path (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::StartMenu)) 'Programs') 'Qualification Menu') `
        'Qualification Shortcut.lnk'
    Assert-Equal 'Start Menu shortcut path follows configuration' $fakeFootprint.ShortcutPath $expectedShortcut

    $fakeProfile = Join-Path $testRoot 'Person Name'
    $fakeWorkspace = Join-Path $testRoot 'Source Checkout'
    $unsafe = "$fakeProfile\Jazz; $fakeWorkspace\Jazz.msi; S-1-5-21-111-222-333-1001"
    $safe = Protect-QualificationText -Text $unsafe -AdditionalReplacements @{
        '<FAKE-PROFILE>' = $fakeProfile
        '<WORKSPACE>' = $fakeWorkspace
    }
    Assert-True 'profile path redacted' (-not $safe.Contains($fakeProfile))
    Assert-True 'workspace path redacted' (-not $safe.Contains($fakeWorkspace))
    Assert-True 'SID redacted' (-not $safe.Contains('S-1-5-21'))

    $rawLog = Join-Path $testRoot 'raw.log'
    [IO.File]::WriteAllText($rawLog, $unsafe, [Text.UTF8Encoding]::new($false))
    $evidence = Join-Path $testRoot 'evidence'
    $report = [pscustomobject][ordered]@{
        '$schema' = '../../qualification/qualification-report.schema.json'
        schemaVersion = 1
        kind = 'manual-real-windows'
        status = 'passed'
        generatedAt = [DateTimeOffset]::UtcNow.ToString('O')
        durationMilliseconds = 1
        source = [ordered]@{ commit = 'test'; runId = $null; runAttempt = $null }
        package = [ordered]@{
            productName = 'Jazz Capture'; productVersion = '0.0.0'; productCode = '{TEST}'
            packageCode = '{TEST}'; upgradeCode = '{TEST}'; byteLength = 1; sha256 = ('0' * 64)
            signerStatus = 'NotSigned'
        }
        environment = [ordered]@{
            osVersion = 'test'; architecture = 'x64'; processArchitecture = 'x64'
            privilege = 'standard-user'; userInteractive = $false; sessionId = 0
        }
        run = [ordered]@{
            runId = '11111111-2222-4333-8444-555555555555'
            profileRole = 'primary'
            relatedPrimaryRunId = $null
            phase = 'completed'
        }
        failurePhase = $null
        inventory = [ordered]@{ afterInstall = $null; afterRepair = $null }
        sentinels = @{}
        checks = @([ordered]@{ id = 'helper'; status = 'passed'; detail = "safe $fakeProfile" })
        limitations = @('Test report only.')
    }
    Write-QualificationEvidence -Report $report -EvidenceDirectory $evidence `
        -RawLogs @{ 'raw.sanitized.log' = $rawLog } `
        -AdditionalReplacements @{ '<FAKE-PROFILE>' = $fakeProfile; '<WORKSPACE>' = $fakeWorkspace }
    $writtenJson = Get-Content -LiteralPath (Join-Path $evidence 'qualification.json') -Raw | ConvertFrom-Json
    Assert-Equal 'report schema version' $writtenJson.schemaVersion 1
    Assert-Equal 'report status' $writtenJson.status 'passed'
    Assert-Equal 'manual report run role' $writtenJson.run.profileRole 'primary'
    $schemaText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\qualification\qualification-report.schema.json') -Raw
    $reportText = Get-Content -LiteralPath (Join-Path $evidence 'qualification.json') -Raw
    Assert-True 'report validates against JSON schema' (Test-Json -Json $reportText -Schema $schemaText -ErrorAction Stop)
    Assert-True 'JSON evidence excludes fake profile' (-not $reportText.Contains($fakeProfile))
    $markdownText = Get-Content -LiteralPath (Join-Path $evidence 'qualification.md') -Raw
    Assert-True 'Markdown evidence excludes fake profile' (-not $markdownText.Contains($fakeProfile))
    $writtenLog = Get-Content -LiteralPath (Join-Path $evidence 'raw.sanitized.log') -Raw
    Assert-True 'sanitized evidence excludes fake profile' (-not $writtenLog.Contains($fakeProfile))
    Assert-True 'sanitized evidence excludes SID' (-not $writtenLog.Contains('S-1-5-21'))

    $stateIdentity = [pscustomobject][ordered]@{
        sha256 = ('a' * 64)
        productCode = '{11111111-2222-3333-4444-555555555555}'
        productVersion = '1.2.3'
    }
    $statePath = Join-Path $testRoot 'state\qualification-state.json'
    $state = New-QualificationResumeState -MsiIdentity $stateIdentity -ProfileRole primary -StatePath $statePath
    $readState = Read-QualificationResumeState -StatePath $statePath -ExpectedMsiIdentity $stateIdentity
    Assert-Equal 'resume state binds run ID' $readState.binding.runId $state.binding.runId
    Assert-Equal 'resume state binds MSI digest' $readState.binding.packageSha256 $stateIdentity.sha256
    $state.checks = @([pscustomobject][ordered]@{
        id = 'persisted-check'; status = 'passed'; detail = 'privacy-safe test detail'
    })
    $state.updatedAt = [DateTimeOffset]::UtcNow.AddSeconds(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    Write-QualificationResumeState -State $state -StatePath $statePath
    $updatedState = Read-QualificationResumeState -StatePath $statePath -ExpectedMsiIdentity $stateIdentity
    Assert-Equal 'resume state check update persists' $updatedState.checks[0].id 'persisted-check'
    Assert-Equal 'resume state updatedAt persists' $updatedState.updatedAt $state.updatedAt

    $tampered = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $tampered.binding.productVersion = '9.9.9'
    $tampered | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding utf8
    Assert-Throws 'resume state visible tampering rejected' {
        Read-QualificationResumeState -StatePath $statePath -ExpectedMsiIdentity $stateIdentity
    }

    Write-QualificationResumeState -State $state -StatePath $statePath
    $tampered = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $tampered.protectedPayload = 'AAAA'
    $tampered | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding utf8
    Assert-Throws 'resume state seal tampering rejected' {
        Read-QualificationResumeState -StatePath $statePath -ExpectedMsiIdentity $stateIdentity
    }

    Write-QualificationResumeState -State $state -StatePath $statePath
    $wrongIdentity = [pscustomobject][ordered]@{
        sha256 = ('b' * 64)
        productCode = $stateIdentity.productCode
        productVersion = $stateIdentity.productVersion
    }
    Assert-Throws 'resume state wrong MSI rejected' {
        Read-QualificationResumeState -StatePath $statePath -ExpectedMsiIdentity $wrongIdentity
    }
    Assert-Throws 'secondary state requires primary run ID' {
        New-QualificationResumeState -MsiIdentity $stateIdentity -ProfileRole secondary -StatePath (Join-Path $testRoot 'bad-secondary.json')
    }

    $profileState = Test-JazzProfileClean -InstallerConfiguration (Get-JazzInstallerConfiguration)
    Assert-True 'profile preflight is read-only and shaped' `
        ($null -ne $profileState.PSObject.Properties['IsClean'] -and
         $null -ne $profileState.PSObject.Properties['Reasons'])

    $qualificationRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\qualification'))
    foreach ($jsonName in @('capability-matrix.json', 'qualification-report.schema.json')) {
        $document = Get-Content -LiteralPath (Join-Path $qualificationRoot $jsonName) -Raw | ConvertFrom-Json
        Assert-True "$jsonName parses" ($null -ne $document)
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        # The test owns this GUID-named directory. Validate its parent before recursive cleanup.
        [void](Assert-QualificationChildPath -Root ([IO.Path]::GetTempPath()) -Path $testRoot)
        [IO.Directory]::Delete($testRoot, $true)
    }
}

Write-Host "$passed helper assertions passed. No installer mutation was performed."
