<#
.SYNOPSIS
    Measures the CPU, disk and file load of Jazz Capture while the operator uses the computer.

.DESCRIPTION
    Run it in the profile that records, with the capture active. During the measurement, use the
    computer in the planned way (for example, 200 left clicks, one every 250 ms, into a browser page).
    The script samples performance counters once per second and counts the files and folders that
    are created under the Jazz data root. It writes one JSON report and prints a short summary.

    Compare the report with the report of the previous release on the same machine. A release must
    not create more files per user action than the previous one, unless the change is intended.
#>
[CmdletBinding()]
param(
    [ValidateRange(10, 3600)][int] $DurationSeconds = 60,
    [Parameter(Mandatory)][string] $ReportPath,
    [string] $Label = 'capture-load',
    [string] $DataRoot = (Join-Path $env:LOCALAPPDATA 'Jazz')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$process = Get-Process -Name JazzCapture -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $process) { throw 'JazzCapture is not running in this session.' }
if (-not (Test-Path -LiteralPath $DataRoot)) { throw "Jazz data root not found: $DataRoot" }

$watcher = [IO.FileSystemWatcher]::new($DataRoot)
$watcher.IncludeSubdirectories = $true
$watcher.InternalBufferSize = 65536
$sourceId = "jazz-capture-load-$([guid]::NewGuid())"
Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier $sourceId | Out-Null
$watcher.EnableRaisingEvents = $true

$counters = @(
    '\Process(JazzCapture)\% Processor Time',
    '\Process(MsMpEng)\% Processor Time',
    '\Processor(_Total)\% Processor Time',
    '\PhysicalDisk(_Total)\Disk Writes/sec'
)
$cpuBefore = $process.TotalProcessorTime
$startedAt = [DateTimeOffset]::Now
try {
    $samples = Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples $DurationSeconds -ErrorAction SilentlyContinue
} finally {
    $watcher.EnableRaisingEvents = $false
}
$endedAt = [DateTimeOffset]::Now
$process.Refresh()
$cpuAfter = $process.TotalProcessorTime

$created = @(Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue |
    ForEach-Object { $_.SourceEventArgs.FullPath.Substring($DataRoot.Length) })
Unregister-Event -SourceIdentifier $sourceId
Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue | Remove-Event
$watcher.Dispose()

# Replace ids and file names, so that the report groups the created paths by kind of folder.
$idPattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
$byKind = $created |
    ForEach-Object { $_ -replace $idPattern, '<id>' -replace '\\sha256\\.*$', '\sha256\<blob>' -replace '\\[^\\]+\.[A-Za-z0-9]+$', '\<file>' } |
    Group-Object | Sort-Object Count -Descending |
    ForEach-Object { [pscustomobject][ordered]@{ path = $_.Name; created = $_.Count } }

function Get-CounterAverage([string] $Instance, [string] $Counter) {
    $values = @($samples.CounterSamples | Where-Object {
        $_.InstanceName -eq $Instance -and $_.Path -like "*\$Counter"
    } | ForEach-Object { $_.CookedValue })
    if ($values.Count -eq 0) { return $null }
    [Math]::Round(($values | Measure-Object -Average).Average, 1)
}

$report = [pscustomobject][ordered]@{
    schema = 1
    label = $Label
    startedAt = $startedAt.ToString('o')
    endedAt = $endedAt.ToString('o')
    processorCount = [Environment]::ProcessorCount
    jazzVersion = $process.MainModule.FileVersionInfo.ProductVersion
    jazzCpuSeconds = [Math]::Round(($cpuAfter - $cpuBefore).TotalSeconds, 2)
    averageOneCorePercent = [pscustomobject][ordered]@{
        jazzCapture = Get-CounterAverage 'jazzcapture' '% processor time'
        defender = Get-CounterAverage 'msmpeng' '% processor time'
    }
    averageTotalCpuPercent = Get-CounterAverage '_total' '% processor time'
    averageDiskWritesPerSecond = Get-CounterAverage '_total' 'disk writes/sec'
    createdTotal = $created.Count
    createdByKind = @($byKind)
}

$reportDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))
New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
"{0}: {1} created, JazzCapture {2} %, Defender {3} %, disk writes {4}/s" -f $Label, $report.createdTotal,
    $report.averageOneCorePercent.jazzCapture, $report.averageOneCorePercent.defender,
    $report.averageDiskWritesPerSecond
