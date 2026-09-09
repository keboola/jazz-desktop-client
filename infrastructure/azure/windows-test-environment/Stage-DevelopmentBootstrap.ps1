param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InitializerBase64,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$InitializerSha256,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigurationBase64,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ConfigurationSha256
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertFrom-VerifiedBase64 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $bytes = [Convert]::FromBase64String($Value)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $actualSha256 = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }

    if ($actualSha256 -ne $ExpectedSha256) {
        throw "$Description SHA-256 verification failed."
    }

    return $bytes
}

function Set-SecureInstallRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer) {
            throw "Bootstrap install root is not a directory: $Path."
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Bootstrap install root must not be a reparse point: $Path."
        }
    }
    else {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }

    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)

    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $usersSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $security.SetOwner($systemSid)
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($systemSid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow))
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administratorsSid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow))
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($usersSid, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $inheritance, $propagation, $allow))
    [IO.Directory]::SetAccessControl($Path, $security)
}

$initializerBytes = ConvertFrom-VerifiedBase64 -Value $InitializerBase64 -ExpectedSha256 $InitializerSha256 -Description 'Initializer'
$configurationBytes = ConvertFrom-VerifiedBase64 -Value $ConfigurationBase64 -ExpectedSha256 $ConfigurationSha256 -Description 'Configuration'
$configuration = [Text.Encoding]::UTF8.GetString($configurationBytes) | ConvertFrom-Json

$installRoot = [IO.Path]::GetFullPath($configuration.installRoot)
$programDataRoot = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
$installRootParent = [IO.Path]::GetDirectoryName($installRoot).TrimEnd('\')
if ($installRootParent -ne $programDataRoot) {
    throw "Bootstrap install root must be a direct child of $programDataRoot."
}

if ([string]::IsNullOrWhiteSpace($configuration.scheduledTask.name)) {
    throw 'scheduledTask.name is required in the development package configuration.'
}
if ($configuration.scheduledTask.retryCount -le 0) {
    throw 'scheduledTask.retryCount must be greater than zero.'
}
$restartInterval = [Xml.XmlConvert]::ToTimeSpan($configuration.scheduledTask.retryInterval)
$executionTimeLimit = [Xml.XmlConvert]::ToTimeSpan($configuration.scheduledTask.executionTimeLimit)

Set-SecureInstallRoot -Path $InstallRoot

$initializerPath = Join-Path $InstallRoot 'Initialize-DevelopmentTools.ps1'
$configurationPath = Join-Path $InstallRoot 'development-packages.json'
Remove-Item -LiteralPath $initializerPath, $configurationPath -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllBytes($initializerPath, $initializerBytes)
[IO.File]::WriteAllBytes($configurationPath, $configurationBytes)

$actionArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Install -ConfigurationPath "{1}"' -f $initializerPath, $configurationPath
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $actionArguments -WorkingDirectory $InstallRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-544' -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount $configuration.scheduledTask.retryCount -RestartInterval $restartInterval -ExecutionTimeLimit $executionTimeLimit

Register-ScheduledTask -TaskName $configuration.scheduledTask.name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "Development bootstrap task '$($configuration.scheduledTask.name)' was staged successfully."
