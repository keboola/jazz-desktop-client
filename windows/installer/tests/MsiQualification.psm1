Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Release-QualificationComObject {
    param([AllowNull()] $Value)

    if ($null -eq $Value -or -not [Runtime.InteropServices.Marshal]::IsComObject($Value)) { return }
    try {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Value)
    } catch {
        # Cleanup must not hide the original MSI/shortcut inspection failure. A later repeat-read
        # and exclusive-open helper test detects handles that were not actually released.
    }
}

function Get-QualificationSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-JazzInstallerConfiguration {
    [CmdletBinding()]
    param(
        [string] $VersionPropsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Jazz.Version.props')
    )

    $resolved = (Resolve-Path -LiteralPath $VersionPropsPath).Path
    $propertyNames = @(
        'JazzProductName',
        'JazzDataFolderName',
        'JazzInstallFolderName',
        'JazzRunKey',
        'JazzRunValueName',
        'JazzExecutableName',
        'JazzStartMenuFolderName',
        'JazzShortcutName'
    )

    # Qualification must remain usable on a clean machine with only the self-contained MSI and
    # PowerShell. Read the repository-owned flat props file directly; build-time scripts may use
    # MSBuild, but this runtime safety check deliberately invokes no external process.
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($resolved, $settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
    } finally {
        $reader.Dispose()
    }
    if ($document.DocumentElement.Name -cne 'Project') {
        throw 'Jazz.Version.props must have a Project root.'
    }

    $rawProperties = @{}
    foreach ($node in @($document.SelectNodes('/Project/PropertyGroup/*'))) {
        if ($node.NodeType -ne [Xml.XmlNodeType]::Element) { continue }
        if ($rawProperties.ContainsKey($node.Name)) {
            throw "Jazz.Version.props property $($node.Name) must be defined exactly once."
        }
        $rawProperties[$node.Name] = [string]$node.InnerText
    }
    $resolvedProperties = @{}
    function Resolve-FlatProperty([string] $Name, [string[]] $Stack = @()) {
        if ($resolvedProperties.ContainsKey($Name)) { return [string]$resolvedProperties[$Name] }
        if ($Name -in $Stack) { throw "Jazz.Version.props has a cyclic reference involving $Name." }
        if (-not $rawProperties.ContainsKey($Name)) { throw "Jazz.Version.props property $Name is missing." }

        $value = [string]$rawProperties[$Name]
        $references = @([regex]::Matches($value, '\$\(([A-Za-z_][A-Za-z0-9_.-]*)\)'))
        foreach ($reference in $references) {
            $referencedName = $reference.Groups[1].Value
            $replacement = Resolve-FlatProperty -Name $referencedName -Stack ($Stack + $Name)
            $value = $value.Replace($reference.Value, $replacement)
        }
        if ($value.Contains('$(')) {
            throw "Jazz.Version.props property $Name contains an unsupported MSBuild expression."
        }
        $resolvedProperties[$Name] = $value
        return $value
    }

    $properties = @{}
    foreach ($name in $propertyNames) { $properties[$name] = Resolve-FlatProperty -Name $name }

    foreach ($name in $propertyNames) {
        if ([string]::IsNullOrWhiteSpace([string]$properties[$name])) {
            throw "Jazz.Version.props property $name must not be blank."
        }
    }
    foreach ($name in @('JazzDataFolderName', 'JazzInstallFolderName', 'JazzExecutableName',
            'JazzStartMenuFolderName', 'JazzShortcutName')) {
        $value = [string]$properties[$name]
        if ($value.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $value.Contains([IO.Path]::DirectorySeparatorChar) -or
            $value.Contains([IO.Path]::AltDirectorySeparatorChar)) {
            throw "Jazz.Version.props property $name must be one safe path segment."
        }
    }

    return [pscustomobject][ordered]@{
        ProductName = [string]$properties.JazzProductName
        DataFolderName = [string]$properties.JazzDataFolderName
        InstallFolderName = [string]$properties.JazzInstallFolderName
        RunKey = [string]$properties.JazzRunKey
        RunValueName = [string]$properties.JazzRunValueName
        ExecutableName = [string]$properties.JazzExecutableName
        ProcessName = [IO.Path]::GetFileNameWithoutExtension([string]$properties.JazzExecutableName)
        StartMenuFolderName = [string]$properties.JazzStartMenuFolderName
        ShortcutName = [string]$properties.JazzShortcutName
    }
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
    $installer = $null
    $database = $null
    $summary = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.GetType().InvokeMember(
            'OpenDatabase', 'InvokeMethod', $null, $installer, @($resolved, 0))

        function Read-Property([string] $Name) {
            $view = $null
            $record = $null
            try {
                $sql = "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$($Name.Replace("'", "''"))'"
                $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($sql))
                $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
                $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                if ($null -eq $record) { return '' }
                return [string]$record.GetType().InvokeMember(
                    'StringData', 'GetProperty', $null, $record, @(1))
            } finally {
                if ($null -ne $view) {
                    try { $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null } catch {}
                }
                Release-QualificationComObject $record
                Release-QualificationComObject $view
            }
        }

        # Copy every COM-backed value into managed strings before releasing the COM graph.
        $productName = [string](Read-Property 'ProductName')
        $productVersion = [string](Read-Property 'ProductVersion')
        $productCode = ([string](Read-Property 'ProductCode')).ToUpperInvariant()
        $upgradeCode = ([string](Read-Property 'UpgradeCode')).ToUpperInvariant()
        $summary = $installer.GetType().InvokeMember(
            'SummaryInformation', 'GetProperty', $null, $installer, @($resolved, 0))
        $packageCode = ([string]$summary.GetType().InvokeMember(
            'Property', 'GetProperty', $null, $summary, @(9))).ToUpperInvariant()
        $signatureStatus = [string](Get-AuthenticodeSignature -LiteralPath $resolved).Status
        $byteLength = [int64](Get-Item -LiteralPath $resolved).Length
        $sha256 = [string](Get-QualificationSha256 -Path $resolved)

        return [pscustomobject][ordered]@{
            productName = $productName
            productVersion = $productVersion
            productCode = $productCode
            packageCode = $packageCode
            upgradeCode = $upgradeCode
            byteLength = $byteLength
            sha256 = $sha256
            signerStatus = $signatureStatus
        }
    } finally {
        Release-QualificationComObject $summary
        Release-QualificationComObject $database
        Release-QualificationComObject $installer
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

    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $state = [int]$installer.GetType().InvokeMember(
            'ProductState', 'GetProperty', $null, $installer, @($normalized))
        return $state -eq 5
    } catch {
        return $false
    } finally {
        Release-QualificationComObject $installer
    }
}

function Get-JazzProfileFootprint {
    [CmdletBinding()]
    param(
        [string] $CandidateProductCode = '',
        $InstallerConfiguration = (Get-JazzInstallerConfiguration)
    )

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $dataRoot = Join-Path $localAppData $InstallerConfiguration.DataFolderName
    $installRoot = Join-Path $dataRoot $InstallerConfiguration.InstallFolderName
    $runKey = 'Registry::HKEY_CURRENT_USER\' + $InstallerConfiguration.RunKey
    $runValuePresent = $false
    if (Test-Path -LiteralPath $runKey) {
        $property = Get-ItemProperty -LiteralPath $runKey -Name $InstallerConfiguration.RunValueName -ErrorAction SilentlyContinue
        $runValuePresent = $null -ne $property
    }

    $programs = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::StartMenu)) 'Programs'
    $shortcutFolder = Join-Path $programs $InstallerConfiguration.StartMenuFolderName
    $shortcut = Join-Path $shortcutFolder ($InstallerConfiguration.ShortcutName + '.lnk')
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
                    $_.PSObject.Properties['DisplayName'].Value -eq $InstallerConfiguration.ProductName
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
        Get-Process -Name $InstallerConfiguration.ProcessName -ErrorAction SilentlyContinue |
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
    param(
        [string] $CandidateProductCode = '',
        $InstallerConfiguration = (Get-JazzInstallerConfiguration)
    )

    $footprint = Get-JazzProfileFootprint -CandidateProductCode $CandidateProductCode `
        -InstallerConfiguration $InstallerConfiguration
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

function Test-JazzProcessBlocksCandidateUninstall {
    [CmdletBinding()]
    param(
        [AllowNull()] $ProcessSessionId,
        [Parameter(Mandatory)][int] $CurrentSessionId,
        [AllowNull()][AllowEmptyString()][string] $ProcessPath,
        [Parameter(Mandatory)][string] $ExpectedExecutablePath,
        [switch] $InspectionFailed
    )

    # An inspection failure may be a process-exit race, an access restriction, or an unreadable
    # path. Completion is intentionally retryable, so uncertainty blocks this attempt rather than
    # allowing Windows Installer to mutate a potentially running candidate.
    if ($InspectionFailed -or $null -eq $ProcessSessionId) { return $true }
    try { $sessionId = [int]$ProcessSessionId } catch { return $true }
    if ($sessionId -ne $CurrentSessionId) { return $false }
    if ([string]::IsNullOrWhiteSpace($ProcessPath)) { return $true }
    try {
        return [IO.Path]::GetFullPath($ProcessPath).Equals(
            [IO.Path]::GetFullPath($ExpectedExecutablePath),
            [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $true
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
    param(
        [Parameter(Mandatory)][string] $ProductCode,
        $InstallerConfiguration = (Get-JazzInstallerConfiguration)
    )

    $footprint = Get-JazzProfileFootprint -CandidateProductCode $ProductCode `
        -InstallerConfiguration $InstallerConfiguration
    $exePath = Join-Path $footprint.InstallRoot $InstallerConfiguration.ExecutableName
    $runKey = 'Registry::HKEY_CURRENT_USER\' + $InstallerConfiguration.RunKey
    $runValue = $null
    if (Test-Path -LiteralPath $runKey) {
        $runProperty = Get-ItemProperty -LiteralPath $runKey -Name $InstallerConfiguration.RunValueName -ErrorAction SilentlyContinue
        if ($null -ne $runProperty) {
            $runValue = $runProperty.PSObject.Properties[$InstallerConfiguration.RunValueName].Value
        }
    }

    $shortcutTarget = $null
    if ($footprint.ShortcutPresent) {
        $shortcutTarget = Get-QualificationShortcutTarget -ShortcutPath $footprint.ShortcutPath
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

function Get-QualificationShortcutTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ShortcutPath)

    $resolved = (Resolve-Path -LiteralPath $ShortcutPath).Path
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($resolved)
        return [string]$shortcut.TargetPath
    } finally {
        Release-QualificationComObject $shortcut
        Release-QualificationComObject $shell
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
    'Get-JazzInstallerConfiguration',
    'Get-JazzInstalledState',
    'Get-JazzMsiIdentity',
    'Get-JazzProfileFootprint',
    'Get-QualificationDirectoryInventory',
    'Get-QualificationMsiExecArguments',
    'Get-QualificationShortcutTarget',
    'Get-QualificationSha256',
    'Invoke-QualificationMsiExec',
    'Protect-QualificationText',
    'New-QualificationResumeState',
    'Read-QualificationResumeState',
    'Test-JazzMsiProductRegistered',
    'Test-JazzProcessBlocksCandidateUninstall',
    'Test-JazzProfileClean',
    'Test-QualificationFileHash',
    'Test-QualificationPathWithin',
    'Write-QualificationResumeState',
    'Write-QualificationEvidence'
)
