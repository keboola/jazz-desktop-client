[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline)][string[]] $MsiPath,
    [Parameter(Mandatory)][ValidateSet('Baseline', 'Candidate')][string] $Role
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
}

process {
    foreach ($candidate in $MsiPath) {
        $path = (Resolve-Path -LiteralPath $candidate).Path
        $installer = $null
        $database = $null
        try {
            $installer = New-Object -ComObject WindowsInstaller.Installer
            $database = $installer.GetType().InvokeMember(
                'OpenDatabase', 'InvokeMethod', $null, $installer, @($path, 0))

            function Read-MsiRow([string] $Sql, [string[]] $Columns) {
                $view = $null
                $record = $null
                $rows = [System.Collections.Generic.List[object]]::new()
                try {
                    try {
                        $view = $database.GetType().InvokeMember(
                            'OpenView', 'InvokeMethod', $null, $database, @($Sql))
                    } catch {
                        return @()
                    }
                    $view.GetType().InvokeMember(
                        'Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
                    while ($null -ne ($record = $view.GetType().InvokeMember(
                                'Fetch', 'InvokeMethod', $null, $view, $null))) {
                        $row = [ordered] @{}
                        for ($index = 0; $index -lt $Columns.Count; $index++) {
                            $row[$Columns[$index]] = [string] $record.GetType().InvokeMember(
                                'StringData', 'GetProperty', $null, $record, @($index + 1))
                        }
                        $rows.Add([pscustomobject] $row)
                        [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record)
                        $record = $null
                    }
                    return @($rows)
                } finally {
                    if ($null -ne $view) {
                        try {
                            $view.GetType().InvokeMember(
                                'Close', 'InvokeMethod', $null, $view, $null) | Out-Null
                        } catch {
                            Write-Debug 'MSI view close failed during final cleanup.'
                        }
                    }
                    foreach ($value in @($record, $view)) {
                        if ($null -ne $value -and [Runtime.InteropServices.Marshal]::IsComObject($value)) {
                            [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($value)
                        }
                    }
                }
            }

            $properties = @(Read-MsiRow 'SELECT `Property`,`Value` FROM `Property`' @('Name', 'Value'))
            $actions = @(Read-MsiRow 'SELECT `Action`,`Type`,`Source`,`Target` FROM `CustomAction`' @('Action', 'Type', 'Source', 'Target'))
            $sequence = @(Read-MsiRow 'SELECT `Action`,`Condition`,`Sequence` FROM `InstallExecuteSequence`' @('Action', 'Condition', 'Sequence'))
            $databaseText = @(
                $properties + $actions + $sequence |
                    ForEach-Object { $_ | ConvertTo-Json -Compress }
            ) -join "`n"
            if ($databaseText -match '(?i)JAZZ_TEST_ONLY|JazzTestOnly|FailAfterRemoveExisting') {
                throw "Release MSI contains forbidden test-only content: $([IO.Path]::GetFileName($path))"
            }

            if ($Role -eq 'Candidate') {
                $initialize = @($sequence | Where-Object Action -eq 'InstallInitialize')
                $remove = @($sequence | Where-Object Action -eq 'RemoveExistingProducts')
                $finalize = @($sequence | Where-Object Action -eq 'InstallFinalize')
                $safeSequence = $initialize.Count -eq 1 -and
                    $remove.Count -eq 1 -and
                    $finalize.Count -eq 1 -and
                    [int] $initialize[0].Sequence -lt [int] $remove[0].Sequence -and
                    [int] $remove[0].Sequence -lt [int] $finalize[0].Sequence
                if (-not $safeSequence) {
                    throw "Candidate release MSI has an unsafe upgrade sequence: $([IO.Path]::GetFileName($path))"
                }
            }

            Write-Output "PASS release MSI safety ($Role): $([IO.Path]::GetFileName($path))"
        } finally {
            foreach ($value in @($database, $installer)) {
                if ($null -ne $value -and [Runtime.InteropServices.Marshal]::IsComObject($value)) {
                    [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($value)
                }
            }
        }
    }
}
