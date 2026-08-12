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

        per-user        no elevation is required and nothing is written under HKLM
        install path    the payload lands in %LOCALAPPDATA%\Jazz\App and nowhere else
        start at login  one HKCU Run value points at the installed executable
        data safety     uninstall removes the App directory and never %LOCALAPPDATA%\Jazz

    verify-msi.sh checks the same claims against the package the cross-platform build produces.

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
$versionProps = & dotnet msbuild (Join-Path $PSScriptRoot 'Jazz.Version.props') `
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
$expected = $versionProps.Properties

$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))

function Invoke-MsiQuery {
    <#
        Emits one object per row, with the given names attached to the selected columns.

        Named objects rather than arrays of strings on purpose: PowerShell unrolls arrays written
        to the output stream, so a function returning rows-as-arrays has to fight the language to
        stop a single-row table collapsing into its columns. One object per row is the shape the
        pipeline is built for, and `$row.Directory` reads better than `$row[2]` besides.
    #>
    param([string] $Sql, [string[]] $Columns)

    try {
        $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($Sql))
    } catch {
        # A table the authoring never populated does not exist in the database at all, which for
        # every query below means "no rows" rather than an error.
        return
    }

    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    while ($true) {
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($null -eq $record) { break }

        $row = [ordered] @{}
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $row[$Columns[$i]] = [string] $record.GetType().InvokeMember(
                'StringData', 'GetProperty', $null, $record, @($i + 1))
        }
        [pscustomobject] $row
    }
    $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
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

$propertyRows = @(Invoke-MsiQuery 'SELECT `Property`, `Value` FROM `Property`' @('Name', 'Value'))
$properties = @{}
Write-Host "`n=== Property ==="
foreach ($row in $propertyRows) {
    $properties[$row.Name] = $row.Value
    Write-Host ("  {0,-28} {1}" -f $row.Name, $row.Value)
}

$directoryRows = @(Invoke-MsiQuery `
    'SELECT `Directory`, `Directory_Parent`, `DefaultDir` FROM `Directory`' `
    @('Id', 'Parent', 'DefaultDir'))
$directories = @{}
foreach ($row in $directoryRows) { $directories[$row.Id] = $row }

$authoredDirectoryIds = @(
    'TARGETDIR', 'LocalAppDataFolder', 'JazzDataFolder', 'INSTALLFOLDER',
    'ProgramMenuFolder', 'ShortcutFolder')
Write-Host "`n=== Directory (the authored ones; the rest are counted) ==="
foreach ($row in @($directoryRows | Where-Object { $_.Id -in $authoredDirectoryIds })) {
    Write-Host ("  {0,-24} parent={1,-24} name={2}" -f $row.Id, $row.Parent, $row.DefaultDir)
}
Write-Host ("  ... and {0} other directory rows" -f
    @($directoryRows | Where-Object { $_.Id -notin $authoredDirectoryIds }).Count)

$registryRows = @(Invoke-MsiQuery `
    'SELECT `Registry`, `Root`, `Key`, `Name`, `Value`, `Component_` FROM `Registry`' `
    @('Id', 'Root', 'Key', 'Name', 'Value', 'Component'))
Write-Host "`n=== Registry ==="
foreach ($row in $registryRows) {
    Write-Host ("  root={0} key={1} name={2} value={3} component={4}" -f
        $row.Root, $row.Key, $row.Name, $row.Value, $row.Component)
}
if ($registryRows.Count -eq 0) { Write-Host "  (empty)" }

$componentRows = @(Invoke-MsiQuery `
    'SELECT `Component`, `ComponentId`, `Directory_`, `Attributes`, `KeyPath` FROM `Component`' `
    @('Id', 'Guid', 'Directory', 'Attributes', 'KeyPath'))
$authoredComponentIds = @('AutoStart', 'StartMenuShortcut')
Write-Host "`n=== Component (authored ones; harvested payload components are counted) ==="
foreach ($row in @($componentRows | Where-Object { $_.Id -in $authoredComponentIds })) {
    Write-Host ("  {0,-20} dir={1,-16} attributes={2} keypath={3}" -f
        $row.Id, $row.Directory, $row.Attributes, $row.KeyPath)
}
Write-Host ("  ... and {0} harvested payload components" -f
    @($componentRows | Where-Object { $_.Id -notin $authoredComponentIds }).Count)

$fileRows = @(Invoke-MsiQuery `
    'SELECT `File`, `Component_`, `FileName`, `FileSize` FROM `File`' `
    @('Id', 'Component', 'FileName', 'FileSize'))
$payloadBytes = ($fileRows |
    ForEach-Object { if ($_.FileSize) { [int64] $_.FileSize } else { [int64] 0 } } |
    Measure-Object -Sum).Sum
Write-Host "`n=== File ==="
Write-Host ("  {0} files, {1:N1} MB uncompressed" -f $fileRows.Count, ($payloadBytes / 1MB))

$removeFileRows = @(Invoke-MsiQuery `
    'SELECT `FileKey`, `Component_`, `FileName`, `DirProperty`, `InstallMode` FROM `RemoveFile`' `
    @('Id', 'Component', 'FileName', 'Directory', 'InstallMode'))
Write-Host "`n=== RemoveFile (what uninstall deletes beyond the installed files) ==="
foreach ($row in $removeFileRows) {
    Write-Host ("  {0,-24} dir={1,-20} filename={2,-12} mode={3}" -f
        $row.Id, $row.Directory, $row.FileName, $row.InstallMode)
}
if ($removeFileRows.Count -eq 0) { Write-Host "  (empty)" }

$upgradeRows = @(Invoke-MsiQuery `
    'SELECT `UpgradeCode`, `VersionMin`, `VersionMax`, `Attributes`, `ActionProperty` FROM `Upgrade`' `
    @('UpgradeCode', 'VersionMin', 'VersionMax', 'Attributes', 'ActionProperty'))
Write-Host "`n=== Upgrade ==="
foreach ($row in $upgradeRows) {
    Write-Host ("  {0} min={1} max={2} attributes={3} property={4}" -f
        $row.UpgradeCode, $row.VersionMin, $row.VersionMax, $row.Attributes, $row.ActionProperty)
}
if ($upgradeRows.Count -eq 0) { Write-Host "  (empty)" }

# ------------------------------------------------------------------------------ the assertions ----

function Get-Property {
    param([string] $Name)
    if ($properties.ContainsKey($Name)) { return $properties[$Name] }
    return ''
}

function Get-LongName {
    param([string] $DefaultDir)
    # DefaultDir is "target:source" and each half may be "shortname|longname".
    $target = ($DefaultDir -split ':')[0]
    return ($target -split '\|')[-1]
}

Write-Host "`n=== Assertions ==="

# --- identity and the upgrade rule -------------------------------------------------------------
Assert-That "ProductVersion is $($expected.JazzProductVersion)" `
    ((Get-Property 'ProductVersion') -eq $expected.JazzProductVersion) `
    "found '$(Get-Property 'ProductVersion')'"

Assert-That "ProductCode is derived from the version" `
    ((Get-Property 'ProductCode') -eq "{$($expected.JazzProductCode)}") `
    "found '$(Get-Property 'ProductCode')', expected '{$($expected.JazzProductCode)}'"

Assert-That "UpgradeCode is the stable product identity" `
    ((Get-Property 'UpgradeCode') -eq "{$($expected.JazzUpgradeCode)}") `
    "found '$(Get-Property 'UpgradeCode')'"

Assert-That "a major-upgrade rule replaces older builds" `
    (@($upgradeRows | Where-Object { $_.UpgradeCode -eq "{$($expected.JazzUpgradeCode)}" }).Count -ge 1) `
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
    ((Get-Property 'ALLUSERS') -ne '1') `
    "ALLUSERS='$(Get-Property 'ALLUSERS')'"

$hklmRows = @($registryRows | Where-Object { $_.Root -eq '2' })
Assert-That "nothing is written under HKLM" `
    ($hklmRows.Count -eq 0) `
    "$($hklmRows.Count) HKLM registry rows"

# Component attribute bit 256 is msidbComponentAttributes64bit. The payload is win-x64, so a
# component without it would be subject to the WOW64 file and registry redirections.
$not64Bit = @($componentRows | Where-Object { (([int] $_.Attributes) % 512) -lt 256 })
Assert-That "every component is marked 64-bit" `
    ($not64Bit.Count -eq 0) `
    "$($not64Bit.Count) components are not"

# Every directory must hang off TARGETDIR through either the user's local app data or the user's
# start menu. Anything rooted elsewhere is a per-machine write hiding in a per-user package.
function Get-DirectoryRoot {
    param([string] $Id)

    $current = $Id
    for ($hop = 0; $hop -lt 64; $hop++) {
        if (-not $directories.ContainsKey($current)) { return $current }
        $parent = $directories[$current].Parent
        if (-not $parent -or $parent -eq $current -or $parent -eq 'TARGETDIR') { return $current }
        $current = $parent
    }
    return $current
}

$roots = @($directoryRows | ForEach-Object { Get-DirectoryRoot $_.Id } | Sort-Object -Unique)
$strayRoots = @($roots | Where-Object { $_ -notin @('TARGETDIR', 'LocalAppDataFolder', 'ProgramMenuFolder') })
Assert-That "every directory is rooted in the user's profile" `
    ($strayRoots.Count -eq 0) `
    "stray roots: $($strayRoots -join ', ')"

# --- the install path --------------------------------------------------------------------------
Assert-That "the payload directory is a child of the data root" `
    ($directories.ContainsKey('INSTALLFOLDER') -and $directories['INSTALLFOLDER'].Parent -eq 'JazzDataFolder') `
    "INSTALLFOLDER parent is '$(if ($directories.ContainsKey('INSTALLFOLDER')) { $directories['INSTALLFOLDER'].Parent })'"

Assert-That "the payload directory is named $($expected.JazzInstallFolderName)" `
    ($directories.ContainsKey('INSTALLFOLDER') -and
     (Get-LongName $directories['INSTALLFOLDER'].DefaultDir) -eq $expected.JazzInstallFolderName) `
    "named '$(if ($directories.ContainsKey('INSTALLFOLDER')) { Get-LongName $directories['INSTALLFOLDER'].DefaultDir })'"

Assert-That "the data root is %LOCALAPPDATA%\$($expected.JazzDataFolderName)" `
    ($directories.ContainsKey('JazzDataFolder') -and
     $directories['JazzDataFolder'].Parent -eq 'LocalAppDataFolder' -and
     (Get-LongName $directories['JazzDataFolder'].DefaultDir) -eq $expected.JazzDataFolderName) `
    "JazzDataFolder parent='$(if ($directories.ContainsKey('JazzDataFolder')) { $directories['JazzDataFolder'].Parent })'"

$exeRows = @($fileRows | Where-Object { (Get-LongName $_.FileName) -eq $expected.JazzExecutableName })
Assert-That "the tray host executable is in the payload" `
    ($exeRows.Count -eq 1) `
    "$($exeRows.Count) files named $($expected.JazzExecutableName)"

if ($exeRows.Count -eq 1) {
    $exeComponentRows = @($componentRows | Where-Object { $_.Id -eq $exeRows[0].Component })
    $exeDirectory = if ($exeComponentRows.Count -eq 1) { $exeComponentRows[0].Directory } else { '' }

    # Walked rather than compared: a harvester is free to hang the payload off a generated
    # directory under INSTALLFOLDER, and that is still the payload directory.
    $under = $false
    $current = $exeDirectory
    for ($hop = 0; $hop -lt 16 -and $current; $hop++) {
        if ($current -eq 'INSTALLFOLDER') { $under = $true; break }
        $current = if ($directories.ContainsKey($current)) { $directories[$current].Parent } else { '' }
    }
    Assert-That "the tray host installs into the payload directory" `
        $under `
        "its component installs into '$exeDirectory'"
}

# Nothing may be installed straight into the data root: that directory belongs to the user's
# recordings, and a file the installer owns there would be a file uninstall deletes there.
$componentsInDataRoot = @($componentRows | Where-Object { $_.Directory -in @('JazzDataFolder', 'LocalAppDataFolder') })
Assert-That "no component installs into the data root itself" `
    ($componentsInDataRoot.Count -eq 0) `
    "components: $(($componentsInDataRoot | ForEach-Object { $_.Id }) -join ', ')"

# --- start at login ------------------------------------------------------------------------------
$runRows = @($registryRows | Where-Object { $_.Key -eq $expected.JazzRunKey })
Assert-That "exactly one Run value is registered" `
    ($runRows.Count -eq 1) `
    "$($runRows.Count) rows under $($expected.JazzRunKey)"

if ($runRows.Count -eq 1) {
    $run = $runRows[0]
    Assert-That "the Run value is under HKCU" ($run.Root -eq '1') "Root=$($run.Root)"
    Assert-That "the Run value is named $($expected.JazzRunValueName)" `
        ($run.Name -eq $expected.JazzRunValueName) "named '$($run.Name)'"
    Assert-That "the Run value launches the installed executable" `
        ($run.Value -eq "`"[INSTALLFOLDER]$($expected.JazzExecutableName)`"") `
        "value '$($run.Value)'"
}

# --- uninstall leaves captured data alone --------------------------------------------------------
$removesInstallFolder = @($removeFileRows | Where-Object { $_.Directory -eq 'INSTALLFOLDER' })
Assert-That "uninstall removes the payload directory" `
    ($removesInstallFolder.Count -ge 1) `
    "no RemoveFile row targets INSTALLFOLDER, so an empty %LOCALAPPDATA%\$($expected.JazzDataFolderName)\$($expected.JazzInstallFolderName) would be left behind"

# The claim this repository cannot afford to get wrong. Recordings, queued archives and the
# settings document live directly in %LOCALAPPDATA%\Jazz; if uninstall ever lists that directory,
# it deletes evidence the user has not exported yet.
$removesDataRoot = @($removeFileRows | Where-Object { $_.Directory -in @('JazzDataFolder', 'LocalAppDataFolder') })
Assert-That "uninstall never touches the capture data root" `
    ($removesDataRoot.Count -eq 0) `
    "RemoveFile rows targeting the data root: $(($removesDataRoot | ForEach-Object { $_.Id }) -join ', ')"

$removesStartMenuRoot = @($removeFileRows | Where-Object { $_.Directory -eq 'ProgramMenuFolder' })
Assert-That "uninstall never removes the shared Start Menu folder" `
    ($removesStartMenuRoot.Count -eq 0) `
    "RemoveFile rows targeting ProgramMenuFolder: $(($removesStartMenuRoot | ForEach-Object { $_.Id }) -join ', ')"

# --------------------------------------------------------------------------------------------------

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) assertion(s) failed:"
    foreach ($failure in $failures) { Write-Host "  - $failure" }
    exit 1
}

Write-Host "The package is per-user, installs into %LOCALAPPDATA%\$($expected.JazzDataFolderName)\$($expected.JazzInstallFolderName), starts at login through HKCU, and leaves captured data alone on uninstall."
Write-Host "It is unsigned: SmartScreen will warn on first run."
