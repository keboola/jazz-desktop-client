$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installRoot = 'C:\ProgramData\JazzDevelopmentSetup'
$initializerPath = Join-Path $installRoot 'Initialize-DevelopmentTools.ps1'
$configurationPath = Join-Path $installRoot 'development-packages.json'

if (-not (Test-Path -LiteralPath $initializerPath -PathType Leaf)) {
    throw "Development initializer is missing at $initializerPath."
}

if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
    throw "Development package configuration is missing at $configurationPath."
}

$planJson = & $initializerPath -Mode Plan -ConfigurationPath $configurationPath
$plan = $planJson | ConvertFrom-Json

if ($plan.installRoot -ne $installRoot) {
    throw 'Development bootstrap uses an unexpected install root.'
}

if ($plan.versionPolicy -ne 'pinned-with-store-managed') {
    throw 'Development package version policy must pin catalog packages and delegate only Store package updates.'
}

if ($plan.targetUser.sid -ne 'S-1-12-1-3113713020-1309877108-1640456099-1991994069') {
    throw 'Development bootstrap is not restricted to the approved Entra user SID.'
}

if ($plan.targetUser.userPrincipalName -ne 'ondrej.hlavacek@keboolaconnection.onmicrosoft.com') {
    throw 'Development bootstrap does not identify the approved Entra user.'
}

$expectedMachinePackages = @(
    'Git.Git',
    'Microsoft.DotNet.SDK.8',
    'Microsoft.PowerShell',
    'Microsoft.VisualStudioCode',
    'GitHub.cli'
)
$expectedUserPackages = @(
    'astral-sh.uv',
    'GitHub.GitHubDesktop',
    '9PLM9XGG6VKS'
)
$expectedPackageVersions = @{
    'Git.Git' = '2.55.0.3'
    'Microsoft.DotNet.SDK.8' = '8.0.425'
    'Microsoft.PowerShell' = '7.6.6.0'
    'Microsoft.VisualStudioCode' = '1.136.2'
    'GitHub.cli' = '2.100.0'
    'astral-sh.uv' = '0.12.11'
    'GitHub.GitHubDesktop' = '3.6.5'
}

$actualMachinePackages = @($plan.machinePackages | ForEach-Object { $_.id })
$actualUserPackages = @($plan.userPackages | ForEach-Object { $_.id })

if (Compare-Object $expectedMachinePackages $actualMachinePackages) {
    throw 'Machine package plan does not match the approved development toolset.'
}

if (Compare-Object $expectedUserPackages $actualUserPackages) {
    throw 'User package plan does not match the approved development toolset.'
}

if ($plan.machinePackages | Where-Object { $_.scope -ne 'machine' }) {
    throw 'Every machine package must use machine scope.'
}

if ($plan.userPackages | Where-Object { $_.scope -ne 'user' }) {
    throw 'Every user package must use user scope.'
}

$catalogPackages = @($plan.machinePackages) + @($plan.userPackages | Where-Object { $_.source -ne 'msstore' })
if ($catalogPackages | Where-Object { [string]::IsNullOrWhiteSpace($_.version) }) {
    throw 'Every non-Store package must have an exact version.'
}
foreach ($package in $catalogPackages) {
    if ($package.version -ne $expectedPackageVersions[$package.id]) {
        throw "Package $($package.id) is not pinned to the reviewed version."
    }
}

$chatGpt = $plan.userPackages | Where-Object { $_.id -eq '9PLM9XGG6VKS' }
if ($chatGpt.source -ne 'msstore') {
    throw 'ChatGPT must be installed from the Microsoft Store source.'
}
if ($chatGpt.versionPolicy -ne 'store-managed') {
    throw 'ChatGPT updates must be explicitly delegated to Microsoft Store.'
}

if (@($plan.vscodeExtensions) -notcontains 'ms-dotnettools.csharp') {
    throw 'The C# debugger extension is missing from the first-login plan.'
}

if (@($plan.commands) | Where-Object { $_ -match '\b(auth|login)\b' }) {
    throw 'Bootstrap must not authenticate GitHub or ChatGPT.'
}

if ($plan.winGetAvailability.maximumWaitSeconds -le 0 -or $plan.winGetAvailability.pollIntervalSeconds -le 0) {
    throw 'WinGet availability requires a bounded positive wait policy.'
}

if ($plan.scheduledTask.retryCount -le 0 -or [string]::IsNullOrWhiteSpace($plan.scheduledTask.retryInterval) -or [string]::IsNullOrWhiteSpace($plan.scheduledTask.executionTimeLimit)) {
    throw 'The first-login scheduled task requires an automatic retry policy.'
}

$installRootItem = Get-Item -LiteralPath $installRoot -Force
if (($installRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Development bootstrap install root must not be a reparse point.'
}

$acl = Get-Acl -LiteralPath $installRoot
if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-18') {
    throw 'Development bootstrap install root must be owned by SYSTEM.'
}

$expectedAclSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')
$actualAclSids = @($acl.Access | ForEach-Object {
    $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
})
if (Compare-Object $expectedAclSids $actualAclSids) {
    throw 'Development bootstrap install root has unexpected access control entries.'
}

$usersRule = $acl.Access | Where-Object {
    $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-545'
}
$writeRights = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Modify -bor [Security.AccessControl.FileSystemRights]::FullControl
if (($usersRule.FileSystemRights -band $writeRights) -ne 0) {
    throw 'Standard users must not be able to modify the development bootstrap.'
}

$task = Get-ScheduledTask -TaskName $plan.scheduledTask.name
$administratorsName = ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value
if ($task.Principal.GroupId -ne $administratorsName -or $task.Principal.RunLevel -ne 'Highest') {
    throw 'Development bootstrap task must run elevated for an interactive administrator.'
}

$expectedPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ($task.Actions.Execute -ne $expectedPowerShellPath) {
    throw 'Development bootstrap task must use the explicit Windows PowerShell path.'
}

if ($task.Settings.RestartCount -ne $plan.scheduledTask.retryCount -or $task.Settings.RestartInterval -ne $plan.scheduledTask.retryInterval) {
    throw 'Development bootstrap task retry settings do not match the reviewed plan.'
}

Write-Output 'Development bootstrap plan is valid.'
