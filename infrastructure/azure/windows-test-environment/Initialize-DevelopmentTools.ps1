param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Plan', 'Install')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigurationPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-Configuration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Development package configuration is missing at $Path."
    }

    $configuration = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($configuration.schemaVersion -ne 1) {
        throw "Unsupported development package configuration schema version: $($configuration.schemaVersion)."
    }
    if ([string]::IsNullOrWhiteSpace($configuration.installRoot)) {
        throw 'installRoot is required.'
    }
    if ([string]::IsNullOrWhiteSpace($configuration.scheduledTask.name)) {
        throw 'scheduledTask.name is required.'
    }
    if ($configuration.scheduledTask.retryCount -le 0) {
        throw 'scheduledTask.retryCount must be greater than zero.'
    }
    if ([string]::IsNullOrWhiteSpace($configuration.scheduledTask.retryInterval)) {
        throw 'scheduledTask.retryInterval is required.'
    }
    if ($configuration.winGetAvailability.maximumWaitSeconds -le 0 -or $configuration.winGetAvailability.pollIntervalSeconds -le 0) {
        throw 'WinGet availability intervals must be greater than zero.'
    }
    if ($configuration.versionPolicy -ne 'pinned-with-store-managed') {
        throw "Unsupported package version policy: $($configuration.versionPolicy)."
    }
    if ([string]::IsNullOrWhiteSpace($configuration.targetUser.userPrincipalName)) {
        throw 'targetUser.userPrincipalName is required.'
    }
    if ($configuration.targetUser.sid -notmatch '^S-1-12-1-(\d+-){2}\d+-\d+$') {
        throw 'targetUser.sid must be a valid Entra user SID.'
    }

    foreach ($package in @($configuration.machinePackages) + @($configuration.userPackages)) {
        if ([string]::IsNullOrWhiteSpace($package.id)) {
            throw 'Every package requires a non-empty id.'
        }
        if (@('winget', 'msstore') -notcontains $package.source) {
            throw "Package $($package.id) has an unsupported source: $($package.source)."
        }
        if (@('machine', 'user') -notcontains $package.scope) {
            throw "Package $($package.id) has an unsupported scope: $($package.scope)."
        }
        if ($package.source -eq 'winget' -and ($null -eq $package.PSObject.Properties['version'] -or [string]::IsNullOrWhiteSpace($package.version))) {
            throw "Package $($package.id) requires an exact version."
        }
        if ($package.source -eq 'msstore' -and ($null -eq $package.PSObject.Properties['versionPolicy'] -or $package.versionPolicy -ne 'store-managed')) {
            throw "Microsoft Store package $($package.id) must use the store-managed version policy."
        }
    }

    return $configuration
}

function Resolve-WinGetPath {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Availability
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Availability.maximumWaitSeconds)
    $registrationAttempted = $false

    do {
        $candidates = @()
        $command = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $candidates += $command.Source
        }

        $windowsAppsPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $windowsAppsPath -PathType Leaf) {
            $candidates += $windowsAppsPath
        }

        foreach ($candidate in $candidates | Select-Object -Unique) {
            try {
                $process = Start-Process -FilePath $candidate -ArgumentList @('--version') -WindowStyle Hidden -Wait -PassThru
                if ($process.ExitCode -eq 0) {
                    return $candidate
                }
            }
            catch {
                # App Installer can expose the execution alias before registration is complete.
            }
        }

        if (-not $registrationAttempted) {
            $registrationAttempted = $true
            $appInstaller = Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' | Sort-Object Version -Descending | Select-Object -First 1
            if ($null -ne $appInstaller) {
                $manifestPath = Join-Path $appInstaller.InstallLocation 'AppxManifest.xml'
                try {
                    Add-AppxPackage -DisableDevelopmentMode -Register $manifestPath
                }
                catch {
                    # Registration may already be running asynchronously after first sign-in.
                }
            }
        }

        if ([DateTimeOffset]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds $Availability.pollIntervalSeconds
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "Windows Package Manager did not become available within $($Availability.maximumWaitSeconds) seconds."
}

function Invoke-ExternalProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "$Description failed with exit code $($process.ExitCode)."
    }
}

function Install-WinGetPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WinGetPath,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Package
    )

    $arguments = @(
        'install',
        '--id', $Package.id,
        '--exact',
        '--source', $Package.source,
        '--scope', $Package.scope,
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    if ($Package.source -eq 'winget') {
        $arguments += @('--version', $Package.version)
    }
    Invoke-ExternalProcess -FilePath $WinGetPath -ArgumentList $arguments -Description "Installation of $($Package.id)"

    $verificationArguments = @(
        'list',
        '--id', $Package.id,
        '--exact',
        '--source', $Package.source,
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    Invoke-ExternalProcess -FilePath $WinGetPath -ArgumentList $verificationArguments -Description "Verification of $($Package.id)"
}

function Assert-WinGetPackageVersions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WinGetPath,

        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    $exportPath = Join-Path $env:TEMP "jazz-development-packages-$([Guid]::NewGuid().ToString('N')).json"
    try {
        $arguments = @(
            'export',
            '--output', $exportPath,
            '--source', 'winget',
            '--include-versions',
            '--accept-source-agreements',
            '--disable-interactivity'
        )
        Invoke-ExternalProcess -FilePath $WinGetPath -ArgumentList $arguments -Description 'Export of installed WinGet package versions'

        $inventory = Get-Content -LiteralPath $exportPath -Raw | ConvertFrom-Json
        $installedPackages = @($inventory.Sources | ForEach-Object { $_.Packages })
        foreach ($package in $Packages | Where-Object { $_.source -eq 'winget' }) {
            $installed = $installedPackages | Where-Object {
                $_.PackageIdentifier -eq $package.id -and $_.Version -eq $package.version
            }
            if ($null -eq $installed) {
                throw "Package $($package.id) version $($package.version) is not installed."
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $exportPath -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-VsCodeCommand {
    $command = Get-Command 'code.cmd' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'Visual Studio Code command-line interface was not found after installation.'
}

function Install-VsCodeExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodePath,

        [Parameter(Mandatory = $true)]
        [string]$ExtensionId
    )

    Invoke-ExternalProcess -FilePath $CodePath -ArgumentList @('--install-extension', $ExtensionId, '--force') -Description "Installation of VS Code extension $ExtensionId"

    $installedExtensions = @(& $CodePath --list-extensions)
    if ($LASTEXITCODE -ne 0) {
        throw "Verification of VS Code extension $ExtensionId failed with exit code $LASTEXITCODE."
    }
    if ($installedExtensions -notcontains $ExtensionId) {
        throw "VS Code extension $ExtensionId is not installed."
    }
}

$configuration = Read-Configuration -Path $ConfigurationPath
$plan = [ordered]@{
    schemaVersion = $configuration.schemaVersion
    installRoot = $configuration.installRoot
    versionPolicy = $configuration.versionPolicy
    targetUser = $configuration.targetUser
    winGetAvailability = $configuration.winGetAvailability
    scheduledTask = $configuration.scheduledTask
    machinePackages = @($configuration.machinePackages)
    userPackages = @($configuration.userPackages)
    vscodeExtensions = @($configuration.vscodeExtensions)
    commands = @($configuration.commands)
}

if ($Mode -eq 'Plan') {
    $plan | ConvertTo-Json -Depth 8 -Compress
    exit 0
}

if ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
    throw 'Development tools must be installed in an interactive administrator session, not as SYSTEM.'
}

$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if ($currentIdentity.User.Value -ne $configuration.targetUser.sid) {
    Write-Output "Development bootstrap skipped because the logged-in administrator is not $($configuration.targetUser.userPrincipalName)."
    exit 0
}

$winGetPath = Resolve-WinGetPath -Availability $configuration.winGetAvailability
$packages = @($configuration.machinePackages) + @($configuration.userPackages)
foreach ($package in $packages) {
    Install-WinGetPackage -WinGetPath $winGetPath -Package $package
}
Assert-WinGetPackageVersions -WinGetPath $winGetPath -Packages $packages

$codePath = Resolve-VsCodeCommand
foreach ($extensionId in @($configuration.vscodeExtensions)) {
    Install-VsCodeExtension -CodePath $codePath -ExtensionId $extensionId
}

if (Get-ScheduledTask -TaskName $configuration.scheduledTask.name -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $configuration.scheduledTask.name -Confirm:$false
}

Write-Output 'Development tools were installed and verified successfully.'
