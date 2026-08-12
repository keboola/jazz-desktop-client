<#
.SYNOPSIS
    Dumps and asserts the contents of the built Jazz Capture MSI.

.DESCRIPTION
    An MSI that builds is not an MSI that installs correctly. WiX will happily compile authoring
    that installs per-machine, that puts the payload somewhere nobody expected, or that lists the
    user's capture directory for deletion on uninstall. None of that shows up as a build error, and
    none of it can be caught by a job that only compiles the app.

    So this script opens the finished database with the Windows Installer API, prints the Property,
    Directory, Registry, Component, File, RemoveFile and Upgrade tables into the log as the record
    of what was actually produced, and then asserts the four claims the installer makes:

        per-user      no elevation is required and nothing is written under HKLM
        install path  the payload lands in %LOCALAPPDATA%\Jazz\App and nowhere else
        start at login  one HKCU Run value points at the installed executable
        data safety   uninstall removes the App directory and never %LOCALAPPDATA%\Jazz

    Run it after build-msi.ps1:

        pwsh windows/installer/Verify-Msi.ps1

.PARAMETER MsiPath
    The package to inspect. Defaults to the artifact produced by build-msi.ps1.
#>
[CmdletBinding()]
param(
    [string] $MsiPath = (Join-Path $PSScriptRoot 'artifacts\Jazz.msi')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $MsiPath)) { throw "No package to verify at $MsiPath. Run build-msi.ps1 first." }
$MsiPath = (Resolve-Path $MsiPath).Path

# The identity to check against comes from the same file the build read, so this script cannot
# drift into asserting a version the installer stopped producing.
$expected = & dotnet msbuild (Join-Path $PSScriptRoot 'Jazz.Version.props') `
    -getProperty:JazzProductVersion `
    -getProperty:JazzProductCode `
    -getProperty:JazzUpgradeCode `
    -getProperty:JazzDataFolderName `
    -getProperty:JazzInstallFolderName `
    -getProperty:JazzRunKey `
    -getProperty:JazzRunValueName `
    -getProperty:JazzExecutableName `
    -nologo | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Could not read Jazz.Version.props" }
$expected = $expected.Properties

$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))

function Invoke-MsiQuery {
    param([string] $Sql, [int] $ColumnCount)

    try {
        $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($Sql))
    } catch {
        # A table the authoring never populated does not exist in the database at all, which for
        # every query below means "no rows" rather than an error.
        return @()
    }

    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    $rows = New-Object System.Collections.ArrayList
    while ($true) {
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($null -eq $record) { break }
        $values = @()
        for ($i = 1; $i -le $ColumnCount; $i++) {
            $values += [string] $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @($i))
        }
        [void] $rows.Add($values)
    }
    $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
    return $rows.ToArray()
}

$failures = New-Object System.Collections.ArrayList
function Assert-That {
    param([string] $Claim, [bool] $Condition, [string] $Detail = '')

    if ($Condition) {
        Write-Host "  PASS  $Claim"
    } else {
        Write-Host "  FAIL  $Claim$(if ($Detail) { " -- $Detail" })"
        [void] $failures.Add($Claim)
    }
}

# ---------------------------------------------------------------- the tables, for the record ----

$properties = @{}
$propertyRows = Invoke-MsiQuery 'SELECT `Property`, `Value` FROM `Property`' 2
Write-Host "`n=== Property ==="
foreach ($row in $propertyRows) {
    $properties[$row[0]] = $row[1]
    Write-Host ("  {0,-28} {1}" -f $row[0], $row[1])
}

$directories = @{}
$directoryRows = Invoke-MsiQuery 'SELECT `Directory`, `Directory_Parent`, `DefaultDir` FROM `Directory`' 3
foreach ($row in $directoryRows) {
    $directories[$row[0]] = [pscustomobject]@{ Parent = $row[1]; DefaultDir = $row[2] }
}
Write-Host "`n=== Directory (the named ones; harvested subdirectories are listed by count) ==="
$named = $directoryRows | Where-Object { $_[0] -notmatch '^[a-z0-9]{32}$' }
foreach ($row in $named) {
    Write-Host ("  {0,-28} parent={1,-24} name={2}" -f $row[0], $row[1], $row[2])
}
Write-Host ("  ... and {0} generated directory rows" -f ($directoryRows.Count - $named.Count))

$registryRows = Invoke-MsiQuery 'SELECT `Registry`, `Root`, `Key`, `Name`, `Value`, `Component_` FROM `Registry`' 6
Write-Host "`n=== Registry ==="
foreach ($row in $registryRows) {
    Write-Host ("  root={0} key={1} name={2} value={3} component={4}" -f $row[1], $row[2], $row[3], $row[4], $row[5])
}

$componentRows = Invoke-MsiQuery 'SELECT `Component`, `ComponentId`, `Directory_`, `Attributes`, `KeyPath` FROM `Component`' 5
Write-Host "`n=== Component (authored ones; harvested file components are listed by count) ==="
$authoredComponents = $componentRows | Where-Object { $_[0] -in @('AutoStart', 'StartMenuShortcut') }
foreach ($row in $authoredComponents) {
    Write-Host ("  {0,-20} dir={1,-16} attributes={2} keypath={3}" -f $row[0], $row[2], $row[3], $row[4])
}
Write-Host ("  ... and {0} harvested payload components" -f ($componentRows.Count - $authoredComponents.Count))

$fileRows = Invoke-MsiQuery 'SELECT `File`, `Component_`, `FileName`, `FileSize` FROM `File`' 4
Write-Host "`n=== File ==="
Write-Host ("  {0} files, {1:N1} MB uncompressed" -f $fileRows.Count, (($fileRows | ForEach-Object { [int64] $_[3] } | Measure-Object -Sum).Sum / 1MB))

$removeFileRows = Invoke-MsiQuery 'SELECT `FileKey`, `Component_`, `FileName`, `DirProperty`, `InstallMode` FROM `RemoveFile`' 5
Write-Host "`n=== RemoveFile (what uninstall deletes beyond the installed files) ==="
foreach ($row in $removeFileRows) {
    Write-Host ("  {0,-24} dir={1,-20} filename={2,-12} mode={3}" -f $row[0], $row[3], $row[2], $row[4])
}
if ($removeFileRows.Count -eq 0) { Write-Host "  (empty)" }

$upgradeRows = Invoke-MsiQuery 'SELECT `UpgradeCode`, `VersionMin`, `VersionMax`, `Attributes`, `ActionProperty` FROM `Upgrade`' 5
Write-Host "`n=== Upgrade ==="
foreach ($row in $upgradeRows) {
    Write-Host ("  {0} min={1} max={2} attributes={3} property={4}" -f $row[0], $row[1], $row[2], $row[3], $row[4])
}

# ------------------------------------------------------------------------------ the assertions ----

Write-Host "`n=== Assertions ==="

# --- identity and the upgrade rule -------------------------------------------------------------
Assert-That "ProductVersion is $($expected.JazzProductVersion)" `
    ($properties.ContainsKey('ProductVersion') -and $properties['ProductVersion'] -eq $expected.JazzProductVersion) `
    "found '$(if ($properties.ContainsKey('ProductVersion')) { $properties['ProductVersion'] })'"

Assert-That "ProductCode is derived from the version" `
    ($properties.ContainsKey('ProductCode') -and $properties['ProductCode'] -eq "{$($expected.JazzProductCode)}") `
    "found '$(if ($properties.ContainsKey('ProductCode')) { $properties['ProductCode'] })', expected '{$($expected.JazzProductCode)}'"

Assert-That "UpgradeCode is the stable product identity" `
    ($properties.ContainsKey('UpgradeCode') -and $properties['UpgradeCode'] -eq "{$($expected.JazzUpgradeCode)}") `
    "found '$(if ($properties.ContainsKey('UpgradeCode')) { $properties['UpgradeCode'] })'"

$majorUpgradeRow = $upgradeRows | Where-Object { $_[0] -eq "{$($expected.JazzUpgradeCode)}" }
Assert-That "a major-upgrade rule replaces older builds" `
    ($null -ne $majorUpgradeRow -and @($majorUpgradeRow).Count -ge 1) `
    "the Upgrade table has no row for the UpgradeCode, so a newer build would install beside the old one"

# --- per-user, no elevation --------------------------------------------------------------------
# PID_WORDCOUNT bit 3 (value 8) on an MSI means "elevated privileges are not required to install".
$summary = $installer.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $installer, @($MsiPath, 0))
$wordCount = [int] $summary.GetType().InvokeMember('Property', 'GetProperty', $null, $summary, @(15))
Write-Host "  (summary word count = $wordCount)"
Assert-That "the package declares that it needs no elevation" `
    (($wordCount -band 8) -eq 8) `
    "word count $wordCount does not have the 'no elevation required' bit set"

Assert-That "ALLUSERS is not set to a per-machine install" `
    (-not $properties.ContainsKey('ALLUSERS') -or $properties['ALLUSERS'] -ne '1') `
    "ALLUSERS='$(if ($properties.ContainsKey('ALLUSERS')) { $properties['ALLUSERS'] })'"

$hklmRows = $registryRows | Where-Object { $_[1] -eq '2' }
Assert-That "nothing is written under HKLM" `
    (@($hklmRows).Count -eq 0) `
    "$(@($hklmRows).Count) HKLM registry rows"

# Component attribute bit 256 is msidbComponentAttributes64bit. The payload is win-x64, so a
# component without it would be subject to the WOW64 file and registry redirections.
$not64Bit = $componentRows | Where-Object { (([int] $_[3]) % 512) -lt 256 }
Assert-That "every component is marked 64-bit" `
    (@($not64Bit).Count -eq 0) `
    "$(@($not64Bit).Count) components are not"

# Every directory must hang off TARGETDIR through either the user's local app data or the user's
# start menu. Anything rooted elsewhere is a per-machine write hiding in a per-user package.
function Get-DirectoryRoot {
    param([string] $Id)

    $seen = @{}
    $current = $Id
    while ($current -and $directories.ContainsKey($current) -and -not $seen.ContainsKey($current)) {
        $seen[$current] = $true
        $parent = $directories[$current].Parent
        if (-not $parent -or $parent -eq $current) { return $current }
        if ($parent -eq 'TARGETDIR') { return $current }
        $current = $parent
    }
    return $current
}

$roots = @($directoryRows | ForEach-Object { Get-DirectoryRoot $_[0] } | Sort-Object -Unique)
Assert-That "every directory is rooted in the user's profile" `
    (@($roots | Where-Object { $_ -notin @('TARGETDIR', 'LocalAppDataFolder', 'ProgramMenuFolder') }).Count -eq 0) `
    "roots: $($roots -join ', ')"

# --- the install path --------------------------------------------------------------------------
function Get-LongName {
    param([string] $DefaultDir)

    # DefaultDir is "target:source" and each half may be "shortname|longname".
    $target = ($DefaultDir -split ':')[0]
    $parts = $target -split '\|'
    return $parts[-1]
}

Assert-That "the payload directory is a child of the data root" `
    ($directories.ContainsKey('INSTALLFOLDER') -and $directories['INSTALLFOLDER'].Parent -eq 'JazzDataFolder') `
    "INSTALLFOLDER parent is '$(if ($directories.ContainsKey('INSTALLFOLDER')) { $directories['INSTALLFOLDER'].Parent })'"

Assert-That "the payload directory is named $($expected.JazzInstallFolderName)" `
    ($directories.ContainsKey('INSTALLFOLDER') -and (Get-LongName $directories['INSTALLFOLDER'].DefaultDir) -eq $expected.JazzInstallFolderName) `
    "named '$(if ($directories.ContainsKey('INSTALLFOLDER')) { Get-LongName $directories['INSTALLFOLDER'].DefaultDir })'"

Assert-That "the data root is %LOCALAPPDATA%\$($expected.JazzDataFolderName)" `
    ($directories.ContainsKey('JazzDataFolder') -and
     $directories['JazzDataFolder'].Parent -eq 'LocalAppDataFolder' -and
     (Get-LongName $directories['JazzDataFolder'].DefaultDir) -eq $expected.JazzDataFolderName) `
    "JazzDataFolder parent='$(if ($directories.ContainsKey('JazzDataFolder')) { $directories['JazzDataFolder'].Parent })' name='$(if ($directories.ContainsKey('JazzDataFolder')) { Get-LongName $directories['JazzDataFolder'].DefaultDir })'"

$exeComponent = $fileRows | Where-Object { (Get-LongName $_[2]) -eq $expected.JazzExecutableName }
Assert-That "the tray host executable is in the payload" `
    (@($exeComponent).Count -eq 1) `
    "$(@($exeComponent).Count) files named $($expected.JazzExecutableName)"

if (@($exeComponent).Count -eq 1) {
    $exeComponentId = @($exeComponent)[0][1]
    $exeDirectory = @($componentRows | Where-Object { $_[0] -eq $exeComponentId })[0][2]

    # Walked rather than compared: a harvester is free to hang the payload off a generated
    # directory under INSTALLFOLDER, and that is still the payload directory.
    $under = $false
    $current = $exeDirectory
    for ($hop = 0; $hop -lt 16 -and $current; $hop++) {
        if ($current -eq 'INSTALLFOLDER') { $under = $true; break }
        $current = if ($directories.ContainsKey($current)) { $directories[$current].Parent } else { $null }
    }
    Assert-That "the tray host installs into the payload directory" `
        $under `
        "its component installs into '$exeDirectory'"
}

# Nothing may be installed straight into the data root: that directory belongs to the user's
# recordings, and a file the installer owns there would be a file uninstall deletes there.
$componentsInDataRoot = $componentRows | Where-Object { $_[2] -in @('JazzDataFolder', 'LocalAppDataFolder') }
Assert-That "no component installs into the data root itself" `
    (@($componentsInDataRoot).Count -eq 0) `
    "components: $(@($componentsInDataRoot | ForEach-Object { $_[0] }) -join ', ')"

# --- start at login ------------------------------------------------------------------------------
$runRows = @($registryRows | Where-Object { $_[2] -eq $expected.JazzRunKey })
Assert-That "exactly one Run value is registered" `
    ($runRows.Count -eq 1) `
    "$($runRows.Count) rows under $($expected.JazzRunKey)"

if ($runRows.Count -eq 1) {
    $run = $runRows[0]
    Assert-That "the Run value is under HKCU" ($run[1] -eq '1') "Root=$($run[1])"
    Assert-That "the Run value is named $($expected.JazzRunValueName)" `
        ($run[3] -eq $expected.JazzRunValueName) "named '$($run[3])'"
    Assert-That "the Run value launches the installed executable" `
        ($run[4] -eq "`"[INSTALLFOLDER]$($expected.JazzExecutableName)`"") `
        "value '$($run[4])'"
}

# --- uninstall leaves captured data alone --------------------------------------------------------
$removesInstallFolder = @($removeFileRows | Where-Object { $_[3] -eq 'INSTALLFOLDER' })
Assert-That "uninstall removes the payload directory" `
    ($removesInstallFolder.Count -ge 1) `
    "no RemoveFile row targets INSTALLFOLDER, so an empty %LOCALAPPDATA%\$($expected.JazzDataFolderName)\$($expected.JazzInstallFolderName) would be left behind"

# The claim this repository cannot afford to get wrong. Recordings, queued archives and the
# settings document live directly in %LOCALAPPDATA%\Jazz; if uninstall ever lists that directory,
# it deletes evidence the user has not exported yet.
$removesDataRoot = @($removeFileRows | Where-Object { $_[3] -in @('JazzDataFolder', 'LocalAppDataFolder') })
Assert-That "uninstall never touches the capture data root" `
    ($removesDataRoot.Count -eq 0) `
    "RemoveFile rows targeting the data root: $(@($removesDataRoot | ForEach-Object { $_[0] }) -join ', ')"

$removesStartMenuRoot = @($removeFileRows | Where-Object { $_[3] -eq 'ProgramMenuFolder' })
Assert-That "uninstall never removes the shared Start Menu folder" `
    ($removesStartMenuRoot.Count -eq 0) `
    "RemoveFile rows targeting ProgramMenuFolder: $(@($removesStartMenuRoot | ForEach-Object { $_[0] }) -join ', ')"

# --------------------------------------------------------------------------------------------------

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) assertion(s) failed:"
    foreach ($failure in $failures) { Write-Host "  - $failure" }
    exit 1
}

Write-Host "The package is per-user, installs into %LOCALAPPDATA%\$($expected.JazzDataFolderName)\$($expected.JazzInstallFolderName), starts at login through HKCU, and leaves captured data alone on uninstall."
Write-Host "It is unsigned: SmartScreen will warn on first run."
