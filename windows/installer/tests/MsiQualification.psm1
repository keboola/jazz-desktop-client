Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-QualificationSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-QualificationChildPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Path
    )

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $childPath = [IO.Path]::GetFullPath($Path)
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $childPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The path is not a strict descendant of the approved root.'
    }
    return $childPath
}

function Test-QualificationPathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Path
    )

    try {
        [void](Assert-QualificationChildPath -Root $Root -Path $Path)
        return $true
    } catch {
        return $false
    }
}

function Protect-QualificationText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string] $Text,
        [hashtable] $AdditionalReplacements = @{}
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $replacementValues = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $AdditionalReplacements.GetEnumerator()) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            $replacementValues.Add([pscustomobject]@{
                Value = [string]$entry.Value; Token = [string]$entry.Key; Boundary = $false
            })
        }
    }

    $builtIns = @(
        @{ Value = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData); Token = '<LOCALAPPDATA>'; Boundary = $false },
        @{ Value = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile); Token = '<PROFILE>'; Boundary = $false },
        @{ Value = [IO.Path]::GetTempPath().TrimEnd('\', '/'); Token = '<TEMP>'; Boundary = $false },
        @{ Value = [Environment]::UserName; Token = '<USER>'; Boundary = $true },
        @{ Value = [Environment]::MachineName; Token = '<MACHINE>'; Boundary = $true }
    )
    foreach ($entry in $builtIns) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            $replacementValues.Add([pscustomobject]@{
                Value = [string]$entry.Value; Token = [string]$entry.Token; Boundary = [bool]$entry.Boundary
            })
        }
    }

    $protected = $Text
    foreach ($entry in @($replacementValues | Sort-Object { $_.Value.Length } -Descending)) {
        $pattern = [regex]::Escape($entry.Value)
        if ($entry.Boundary) {
            $pattern = '(?<![\p{L}\p{N}_])' + $pattern + '(?![\p{L}\p{N}_])'
        }
        $protected = [regex]::Replace(
            $protected,
            $pattern,
            [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $entry.Token },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    # Defense in depth for log formats that print a SID without a profile path nearby.
    $protected = [regex]::Replace($protected, 'S-1-5-(?:\d+-){1,14}\d+', '<SID>', 'IgnoreCase')
    return $protected
}

function Get-JazzMsiIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $MsiPath)

    $resolved = (Resolve-Path -LiteralPath $MsiPath).Path
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.GetType().InvokeMember(
        'OpenDatabase', 'InvokeMethod', $null, $installer, @($resolved, 0))

    function Read-Property([string] $Name) {
        $sql = "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$($Name.Replace("'", "''"))'"
        $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($sql))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        $value = if ($null -eq $record) { '' } else {
            [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
        }
        $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
        return $value
    }

    $summary = $installer.GetType().InvokeMember(
        'SummaryInformation', 'GetProperty', $null, $installer, @($resolved, 0))
    $packageCode = [string]$summary.GetType().InvokeMember(
        'Property', 'GetProperty', $null, $summary, @(9))
    $signature = Get-AuthenticodeSignature -LiteralPath $resolved

    return [pscustomobject][ordered]@{
        productName = Read-Property 'ProductName'
        productVersion = Read-Property 'ProductVersion'
        productCode = (Read-Property 'ProductCode').ToUpperInvariant()
        packageCode = $packageCode.ToUpperInvariant()
        upgradeCode = (Read-Property 'UpgradeCode').ToUpperInvariant()
        byteLength = (Get-Item -LiteralPath $resolved).Length
        sha256 = Get-QualificationSha256 -Path $resolved
        signerStatus = [string]$signature.Status
    }
}

function Test-JazzMsiProductRegistered {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProductCode)

    $normalized = $ProductCode.ToUpperInvariant()
    $uninstallRoots = @(
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (Test-Path -LiteralPath (Join-Path $root $normalized)) { return $true }
    }

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $state = [int]$installer.GetType().InvokeMember(
            'ProductState', 'GetProperty', $null, $installer, @($normalized))
        return $state -eq 5
    } catch {
        return $false
    }
}

function Get-JazzProfileFootprint {
    [CmdletBinding()]
    param([string] $CandidateProductCode = '')

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $dataRoot = Join-Path $localAppData 'Jazz'
    $installRoot = Join-Path $dataRoot 'App'
    $runKey = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run'
    $runValuePresent = $false
    if (Test-Path -LiteralPath $runKey) {
        $property = Get-ItemProperty -LiteralPath $runKey -Name JazzCapture -ErrorAction SilentlyContinue
        $runValuePresent = $null -ne $property
    }

    $shortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::StartMenu)) 'Programs\Jazz\Jazz Capture.lnk'
    $productCount = 0
    foreach ($root in @(
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $productCount += @(
            Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
                Get-ItemProperty -ErrorAction SilentlyContinue |
                Where-Object {
                    $null -ne $_.PSObject.Properties['DisplayName'] -and
                    $_.PSObject.Properties['DisplayName'].Value -eq 'Jazz Capture'
                }
        ).Count
    }

    $candidateRegistered = $false
    if (-not [string]::IsNullOrWhiteSpace($CandidateProductCode)) {
        $candidateRegistered = Test-JazzMsiProductRegistered -ProductCode $CandidateProductCode
    }

    # Another fast-switched Windows user may legitimately have its own per-user Jazz process.
    # Only this interactive session can belong to the HKCU/profile being inspected here.
    $currentSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $currentSessionProcessCount = @(
        Get-Process -Name JazzCapture -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $currentSessionId }
    ).Count

    return [pscustomobject][ordered]@{
        DataRoot = $dataRoot
        InstallRoot = $installRoot
        DataRootExists = Test-Path -LiteralPath $dataRoot
        InstallRootExists = Test-Path -LiteralPath $installRoot
        RunValuePresent = $runValuePresent
        ShortcutPresent = Test-Path -LiteralPath $shortcut
        ProcessCount = $currentSessionProcessCount
        ProductCount = $productCount
        CandidateRegistered = $candidateRegistered
        ShortcutPath = $shortcut
    }
}

function Test-JazzProfileClean {
    [CmdletBinding()]
    param([string] $CandidateProductCode = '')

    $footprint = Get-JazzProfileFootprint -CandidateProductCode $CandidateProductCode
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($footprint.DataRootExists) { $reasons.Add('data-root-present') }
    if ($footprint.InstallRootExists) { $reasons.Add('install-root-present') }
    if ($footprint.RunValuePresent) { $reasons.Add('run-entry-present') }
    if ($footprint.ShortcutPresent) { $reasons.Add('shortcut-present') }
    if ($footprint.ProcessCount -gt 0) { $reasons.Add('process-present') }
    if ($footprint.ProductCount -gt 0 -or $footprint.CandidateRegistered) { $reasons.Add('product-present') }

    return [pscustomobject][ordered]@{
        IsClean = $reasons.Count -eq 0
        Reasons = @($reasons)
        Footprint = $footprint
    }
}

function Get-QualificationMsiExecArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Install', 'Repair', 'Uninstall')][string] $Operation,
        [string] $MsiPath,
        [string] $ProductCode,
        [Parameter(Mandatory)][string] $LogPath,
        [switch] $Interactive
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    switch ($Operation) {
        'Install' {
            if ([string]::IsNullOrWhiteSpace($MsiPath)) { throw 'Install requires an MSI path.' }
            $arguments.Add('/i'); $arguments.Add([IO.Path]::GetFullPath($MsiPath))
        }
        'Repair' {
            if ([string]::IsNullOrWhiteSpace($MsiPath)) { throw 'Repair requires an MSI path.' }
            $arguments.Add('/i'); $arguments.Add([IO.Path]::GetFullPath($MsiPath))
            $arguments.Add('REINSTALL=ALL'); $arguments.Add('REINSTALLMODE=vomus')
        }
        'Uninstall' {
            if ([string]::IsNullOrWhiteSpace($ProductCode)) { throw 'Uninstall requires a ProductCode.' }
            $arguments.Add('/x'); $arguments.Add($ProductCode)
        }
    }
    if (-not $Interactive) { $arguments.Add('/qn') }
    $arguments.Add('/norestart')
    $arguments.Add('/L*V'); $arguments.Add([IO.Path]::GetFullPath($LogPath))
    return @($arguments)
}

function Invoke-QualificationMsiExec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Install', 'Repair', 'Uninstall')][string] $Operation,
        [string] $MsiPath,
        [string] $ProductCode,
        [Parameter(Mandatory)][string] $LogPath,
        [switch] $Interactive
    )

    $arguments = Get-QualificationMsiExecArguments @PSBoundParameters
    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    $processInfo.UseShellExecute = $false
    foreach ($argument in $arguments) { [void]$processInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($processInfo)
    $process.WaitForExit()
    return $process.ExitCode
}

function Get-QualificationDirectoryInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Root)

    $rootPath = [IO.Path]::GetFullPath($Root)
    $lines = [System.Collections.Generic.List[string]]::new()
    $totalBytes = [int64]0
    $files = @(Get-ChildItem -LiteralPath $rootPath -File -Recurse | Sort-Object FullName)
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($rootPath, $file.FullName).Replace('\', '/')
        $digest = Get-QualificationSha256 -Path $file.FullName
        $totalBytes += $file.Length
        $lines.Add("$relative`t$($file.Length)`t$digest")
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $aggregate = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return [pscustomobject][ordered]@{ fileCount = $files.Count; byteLength = $totalBytes; sha256 = $aggregate }
}

function Get-JazzInstalledState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProductCode)

    $footprint = Get-JazzProfileFootprint -CandidateProductCode $ProductCode
    $exePath = Join-Path $footprint.InstallRoot 'JazzCapture.exe'
    $runKey = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run'
    $runValue = $null
    if (Test-Path -LiteralPath $runKey) {
        $runProperty = Get-ItemProperty -LiteralPath $runKey -Name JazzCapture -ErrorAction SilentlyContinue
        if ($null -ne $runProperty) { $runValue = $runProperty.JazzCapture }
    }

    $shortcutTarget = $null
    if ($footprint.ShortcutPresent) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcutTarget = $shell.CreateShortcut($footprint.ShortcutPath).TargetPath
    }

    return [pscustomobject][ordered]@{
        registered = Test-JazzMsiProductRegistered -ProductCode $ProductCode
        installRootExists = Test-Path -LiteralPath $footprint.InstallRoot
        executableExists = Test-Path -LiteralPath $exePath
        executablePath = $exePath
        runValue = $runValue
        shortcutExists = $footprint.ShortcutPresent
        shortcutTarget = $shortcutTarget
    }
}

function Test-QualificationFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedSha256
    )

    return (Test-Path -LiteralPath $Path -PathType Leaf) -and
        ((Get-QualificationSha256 -Path $Path) -eq $ExpectedSha256.ToLowerInvariant())
}

function ConvertTo-QualificationResumePayload {
    param([Parameter(Mandatory)] $State)

    function ConvertTo-StateTimestamp($Value) {
        return ([DateTimeOffset]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    }

    $checks = @($State.checks | ForEach-Object {
        [ordered]@{ id = [string]$_.id; status = [string]$_.status; detail = [string]$_.detail }
    })
    $payload = [ordered]@{
        schemaVersion = [int]$State.schemaVersion
        kind = [string]$State.kind
        binding = [ordered]@{
            runId = [string]$State.binding.runId
            packageSha256 = [string]$State.binding.packageSha256
            productCode = [string]$State.binding.productCode
            productVersion = [string]$State.binding.productVersion
            profileRole = [string]$State.binding.profileRole
            relatedPrimaryRunId = if ($null -eq $State.binding.relatedPrimaryRunId) { $null } else { [string]$State.binding.relatedPrimaryRunId }
        }
        phase = [string]$State.phase
        createdAt = ConvertTo-StateTimestamp $State.createdAt
        updatedAt = ConvertTo-StateTimestamp $State.updatedAt
        checks = $checks
    }
    return ($payload | ConvertTo-Json -Depth 12 -Compress)
}

function New-QualificationResumeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $MsiIdentity,
        [Parameter(Mandatory)][ValidateSet('primary', 'secondary')][string] $ProfileRole,
        [AllowNull()][string] $RelatedPrimaryRunId,
        [Parameter(Mandatory)][string] $StatePath
    )

    if ($ProfileRole -eq 'secondary') {
        $parsedRelated = [Guid]::Empty
        if (-not [Guid]::TryParse($RelatedPrimaryRunId, [ref]$parsedRelated) -or $parsedRelated -eq [Guid]::Empty) {
            throw 'A secondary profile requires a valid, non-empty primary run ID.'
        }
        $relatedBinding = $parsedRelated.ToString('D')
    } elseif (-not [string]::IsNullOrWhiteSpace($RelatedPrimaryRunId)) {
        throw 'A primary profile cannot declare a related primary run ID.'
    } else {
        $relatedBinding = $null
    }

    $now = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    $state = [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'windows-manual-qualification-state'
        binding = [pscustomobject][ordered]@{
            runId = [Guid]::NewGuid().ToString('D')
            packageSha256 = ([string]$MsiIdentity.sha256).ToLowerInvariant()
            productCode = ([string]$MsiIdentity.productCode).ToUpperInvariant()
            productVersion = [string]$MsiIdentity.productVersion
            profileRole = $ProfileRole
            relatedPrimaryRunId = $relatedBinding
        }
        phase = 'installed'
        createdAt = $now
        updatedAt = $now
        checks = @()
    }
    Write-QualificationResumeState -State $state -StatePath $StatePath
    return $state
}

function Write-QualificationResumeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $StatePath
    )

    $payloadText = ConvertTo-QualificationResumePayload -State $State
    $entropy = [Text.Encoding]::UTF8.GetBytes('Jazz Windows manual qualification state v1')
    $sealed = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($payloadText),
        $entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $output = [ordered]@{
        schemaVersion = [int]$State.schemaVersion
        kind = [string]$State.kind
        binding = [ordered]@{
            runId = [string]$State.binding.runId
            packageSha256 = [string]$State.binding.packageSha256
            productCode = [string]$State.binding.productCode
            productVersion = [string]$State.binding.productVersion
            profileRole = [string]$State.binding.profileRole
            relatedPrimaryRunId = if ($null -eq $State.binding.relatedPrimaryRunId) { $null } else { [string]$State.binding.relatedPrimaryRunId }
        }
        phase = [string]$State.phase
        createdAt = ([DateTimeOffset]$State.createdAt).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        updatedAt = ([DateTimeOffset]$State.updatedAt).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        checks = @($State.checks | ForEach-Object {
            [ordered]@{ id = [string]$_.id; status = [string]$_.status; detail = [string]$_.detail }
        })
        protectedPayload = [Convert]::ToBase64String($sealed)
    } | ConvertTo-Json -Depth 12

    $fullPath = [IO.Path]::GetFullPath($StatePath)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $fullPath))
    $temporary = $fullPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $output + "`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $fullPath, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Read-QualificationResumeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $StatePath,
        [Parameter(Mandatory)] $ExpectedMsiIdentity
    )

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw 'The qualification state file does not exist.'
    }
    try {
        $document = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'The qualification state file is not valid JSON.'
    }

    $expectedProperties = @('schemaVersion', 'kind', 'binding', 'phase', 'createdAt', 'updatedAt', 'checks', 'protectedPayload')
    $actualProperties = @($document.PSObject.Properties.Name | Sort-Object)
    if (($actualProperties -join "`n") -ne (($expectedProperties | Sort-Object) -join "`n")) {
        throw 'The qualification state file has missing or unexpected fields.'
    }
    if ($document.schemaVersion -ne 1 -or $document.kind -ne 'windows-manual-qualification-state') {
        throw 'The qualification state version or kind is unsupported.'
    }
    if ($document.phase -notin @('installed', 'observed', 'completed')) {
        throw 'The qualification state phase is invalid.'
    }
    $expectedBindingProperties = @(
        'runId', 'packageSha256', 'productCode', 'productVersion',
        'profileRole', 'relatedPrimaryRunId'
    )
    $actualBindingProperties = @($document.binding.PSObject.Properties.Name | Sort-Object)
    if (($actualBindingProperties -join "`n") -ne (($expectedBindingProperties | Sort-Object) -join "`n")) {
        throw 'The qualification state binding has missing or unexpected fields.'
    }

    $runId = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$document.binding.runId, [ref]$runId) -or $runId -eq [Guid]::Empty) {
        throw 'The qualification state run ID is invalid.'
    }
    if ($document.binding.profileRole -notin @('primary', 'secondary')) {
        throw 'The qualification state profile role is invalid.'
    }
    $relatedRunId = [Guid]::Empty
    if ($document.binding.profileRole -eq 'secondary') {
        if (-not [Guid]::TryParse([string]$document.binding.relatedPrimaryRunId, [ref]$relatedRunId) -or
            $relatedRunId -eq [Guid]::Empty) {
            throw 'A secondary qualification state must bind a valid primary run ID.'
        }
    } elseif ($null -ne $document.binding.relatedPrimaryRunId) {
        throw 'A primary qualification state cannot bind another primary run ID.'
    }

    $state = [pscustomobject][ordered]@{
        schemaVersion = [int]$document.schemaVersion
        kind = [string]$document.kind
        binding = [pscustomobject][ordered]@{
            runId = $runId.ToString('D')
            packageSha256 = ([string]$document.binding.packageSha256).ToLowerInvariant()
            productCode = ([string]$document.binding.productCode).ToUpperInvariant()
            productVersion = [string]$document.binding.productVersion
            profileRole = [string]$document.binding.profileRole
            relatedPrimaryRunId = if ($null -eq $document.binding.relatedPrimaryRunId) { $null } else { [string]$document.binding.relatedPrimaryRunId }
        }
        phase = [string]$document.phase
        createdAt = ([DateTimeOffset]$document.createdAt).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        updatedAt = ([DateTimeOffset]$document.updatedAt).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        checks = @($document.checks)
    }

    try {
        $sealed = [Convert]::FromBase64String([string]$document.protectedPayload)
        $entropy = [Text.Encoding]::UTF8.GetBytes('Jazz Windows manual qualification state v1')
        $unsealed = [Security.Cryptography.ProtectedData]::Unprotect(
            $sealed,
            $entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $unsealedText = [Text.Encoding]::UTF8.GetString($unsealed)
    } catch {
        throw 'The qualification state cannot be authenticated for this Windows profile.'
    }
    if ($unsealedText -cne (ConvertTo-QualificationResumePayload -State $state)) {
        throw 'The qualification state contents were changed after sealing.'
    }

    if ($state.binding.packageSha256 -ne ([string]$ExpectedMsiIdentity.sha256).ToLowerInvariant() -or
        $state.binding.productCode -ne ([string]$ExpectedMsiIdentity.productCode).ToUpperInvariant() -or
        $state.binding.productVersion -ne [string]$ExpectedMsiIdentity.productVersion) {
        throw 'The qualification state is bound to a different MSI.'
    }
    return $state
}

function Write-QualificationEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)][string] $EvidenceDirectory,
        [hashtable] $RawLogs = @{},
        [hashtable] $AdditionalReplacements = @{}
    )

    [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($EvidenceDirectory))
    $jsonPath = Join-Path $EvidenceDirectory 'qualification.json'
    $markdownPath = Join-Path $EvidenceDirectory 'qualification.md'
    $json = $Report | ConvertTo-Json -Depth 32
    $safeJson = Protect-QualificationText -Text $json -AdditionalReplacements $AdditionalReplacements
    [IO.File]::WriteAllText($jsonPath, $safeJson + "`n", [Text.UTF8Encoding]::new($false))

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Windows MSI qualification')
    $lines.Add('')
    $lines.Add("- Status: **$($Report.status)**")
    $lines.Add(('- Kind: `{0}`' -f $Report.kind))
    $lines.Add(('- Version: `{0}`' -f $Report.package.productVersion))
    $lines.Add(('- MSI SHA-256: `{0}`' -f $Report.package.sha256))
    $lines.Add(('- ProductCode: `{0}`' -f $Report.package.productCode))
    $lines.Add(('- PackageCode: `{0}`' -f $Report.package.packageCode))
    $lines.Add(('- Signer status: `{0}`' -f $Report.package.signerStatus))
    $lines.Add('')
    $lines.Add('## Checks')
    $lines.Add('')
    $lines.Add('| Check | Status | Detail |')
    $lines.Add('| --- | --- | --- |')
    foreach ($check in $Report.checks) {
        $detail = ([string]$check.detail).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
        $lines.Add(('| `{0}` | {1} | {2} |' -f $check.id, $check.status, $detail))
    }
    $lines.Add('')
    $lines.Add('## Limitations')
    $lines.Add('')
    foreach ($limitation in $Report.limitations) { $lines.Add("- $limitation") }
    $markdown = ($lines -join "`n") + "`n"
    $safeMarkdown = Protect-QualificationText -Text $markdown -AdditionalReplacements $AdditionalReplacements
    [IO.File]::WriteAllText($markdownPath, $safeMarkdown, [Text.UTF8Encoding]::new($false))

    foreach ($entry in $RawLogs.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) { continue }
        $raw = [IO.File]::ReadAllText([string]$entry.Value)
        $safe = Protect-QualificationText -Text $raw -AdditionalReplacements $AdditionalReplacements
        $destination = Join-Path $EvidenceDirectory ([string]$entry.Key)
        [IO.File]::WriteAllText($destination, $safe, [Text.UTF8Encoding]::new($false))
    }
}

Export-ModuleMember -Function @(
    'Assert-QualificationChildPath',
    'Get-JazzInstalledState',
    'Get-JazzMsiIdentity',
    'Get-JazzProfileFootprint',
    'Get-QualificationDirectoryInventory',
    'Get-QualificationMsiExecArguments',
    'Get-QualificationSha256',
    'Invoke-QualificationMsiExec',
    'Protect-QualificationText',
    'New-QualificationResumeState',
    'Read-QualificationResumeState',
    'Test-JazzMsiProductRegistered',
    'Test-JazzProfileClean',
    'Test-QualificationFileHash',
    'Test-QualificationPathWithin',
    'Write-QualificationResumeState',
    'Write-QualificationEvidence'
)
