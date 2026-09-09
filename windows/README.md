# Windows development

The Windows client is a .NET 8 tray application. `JazzCaptureCore` contains the portable capture,
contract, journal, archive, and settings code; `JazzCapture` adds the Windows tray UI, input hooks,
screen capture, audio capture, and UI Automation integration.

Run the commands below from the repository root unless a section says otherwise.

## Prerequisites

- Windows 10 or 11 on x64
- PowerShell 7 (`pwsh`)
- the .NET 8 SDK
- Git
- [`uv`](https://docs.astral.sh/uv/) for the shared contract validators

Confirm the toolchain before changing code:

```powershell
dotnet --version
pwsh --version
uv --version
```

NuGet restores the .NET and WiX dependencies during the first build. The application and MSI are
per-user and do not need an elevated shell.

## Build and run the tray application

Build the Windows host in Release mode:

```powershell
dotnet build windows/Sources/JazzCapture/JazzCapture.csproj --configuration Release
```

The framework-dependent development build is written to
`windows/Sources/JazzCapture/bin/Release/net8.0-windows/`. Start it with:

```powershell
& .\windows\Sources\JazzCapture\bin\Release\net8.0-windows\JazzCapture.exe
```

Jazz appears in the notification area rather than opening a main window. Quit any installed or
previous development copy from its tray menu before starting another build. The single-instance
guard is still tracked in [issue #34](https://github.com/keboola/jazz-desktop-client/issues/34), so
two launches currently produce two tray processes.

Runtime state is kept outside the build tree:

| Path | Purpose |
| --- | --- |
| `%LOCALAPPDATA%\Jazz\settings.json` | persisted tray preferences |
| `%LOCALAPPDATA%\Jazz\captures` | capture journals and local archives |
| `%LOCALAPPDATA%\Jazz\queue` | confirmed archives awaiting delivery |
| `%LOCALAPPDATA%\Jazz\App` | files owned by an MSI installation |

The installer deliberately leaves settings, captures, and the queue in place when it is removed.
Use a separate Windows account or VM when a test needs a completely fresh profile.

## Run tests

Run the full Windows suite the same way as CI:

```powershell
Push-Location windows
try {
    dotnet test --configuration Release
    dotnet build --configuration Release Sources/JazzCapture/JazzCapture.csproj
} finally {
    Pop-Location
}
```

For a quick loop around one component, filter by the test class name. For example:

```powershell
dotnet test windows/Tests/JazzCaptureCoreTests/JazzCaptureCoreTests.csproj `
    --configuration Release `
    --filter FullyQualifiedName~HostSettingsStoreTests
```

The synthetic smoke tool drives the portable engine through a capture, confirmation, and archive
export without recording the desktop:

```powershell
$smokeRoot = Join-Path $env:TEMP ("jazz-smoke-" + [Guid]::NewGuid().ToString("N"))
dotnet run --project windows/Tools/JazzCaptureSmoke --configuration Release -- $smokeRoot
```

`JazzUiaProbe` exercises the hand-written UI Automation interop against the current desktop. It is
useful after changing element resolution or application identity code:

```powershell
dotnet run --project windows/Tools/JazzUiaProbe --configuration Release
```

The probe prints accessibility names and a short prefix of selected text. Run it only against test
content when its terminal output will be retained.

## Validate the shared contract

Run every contract validator before pushing a change that touches the portable capture model. These
commands are also the exact `contract` job in `.github/workflows/ci.yml`:

```powershell
uv run --script contract/validate_schemas.py
uv run --script contract/archive/validate_archives.py
uv run --script contract/live/validate_live_transport.py
uv run --script contract/live/validate_capture_coach_live.py
uv run --script contract/live/generate_capture_coach_fixtures.py --check
uv run --script contract/archive/container/generate_fixtures.py --check
```

A change to an emitted event or its OTLP mapping must update the schema, golden fixtures, Swift
runner, and processor mirror together. CI runs the Swift build and tests on macOS for every PR.

## Build and inspect the MSI

The installer build publishes a self-contained `win-x64` host and packages it with WiX:

```powershell
pwsh windows/installer/build-msi.ps1
pwsh windows/installer/Verify-Msi.ps1
Get-FileHash windows/installer/artifacts/Jazz.msi -Algorithm SHA256
```

The result is `windows/installer/artifacts/Jazz.msi`. `Verify-Msi.ps1` opens the MSI database and
checks the product version, per-user scope, install path, start-at-login registry value, upgrade
rule, and uninstall data safety. The package is currently unsigned, so Windows may show a
SmartScreen warning for an interactive install.

WiX's native helper can fail with `WIX0001` when the checkout path contains non-ASCII characters.
Build through a temporary ASCII drive mapping in that case:

```powershell
$repository = (Resolve-Path .).Path
subst.exe J: $repository
try {
    Push-Location J:\
    pwsh windows/installer/build-msi.ps1
    pwsh windows/installer/Verify-Msi.ps1
} finally {
    Pop-Location
    subst.exe J: /D
}
```

Choose an unused drive letter. The mapping points at the same checkout, so the MSI still appears in
the normal ignored `windows/installer/artifacts` directory.

## Install and test a local MSI

An interactive per-user install is enough for normal testing:

```powershell
$msi = (Resolve-Path windows/installer/artifacts/Jazz.msi).Path
Start-Process msiexec.exe -Wait -ArgumentList @('/i', "`"$msi`"")
```

For a repeatable unattended run with a verbose log:

```powershell
$msi = (Resolve-Path windows/installer/artifacts/Jazz.msi).Path
$log = Join-Path $env:TEMP 'jazz-install.log'
$process = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
    '/i', "`"$msi`"", '/qn', '/norestart', '/L*V', "`"$log`""
)
if ($process.ExitCode -ne 0) {
    Get-Content $log -Tail 100
    throw "MSI installation failed with exit code $($process.ExitCode)"
}
```

Verify the installed payload and running tray process:

```powershell
$exe = Join-Path $env:LOCALAPPDATA 'Jazz\App\JazzCapture.exe'
(Get-Item $exe).VersionInfo | Select-Object FileVersion, ProductVersion
Get-Process JazzCapture | Select-Object Id, Path, Responding, StartTime
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
    -Name JazzCapture
```

To exercise an upgrade, first install the previous released MSI, increase the numeric version in
`windows/installer/Jazz.Version.props`, build the candidate, and install it over the existing copy.
Verify that the executable version changed, the tray starts, and files directly under
`%LOCALAPPDATA%\Jazz` remain present. A same-version build is treated as a repair because its
ProductCode is derived from the version.

When testing a preference change, check both directions: change it in the tray, quit Jazz, start
`%LOCALAPPDATA%\Jazz\App\JazzCapture.exe` again, and confirm the menu still shows the chosen value.
For screenshot policy changes, also start and stop a short capture and inspect the review before
confirming or rejecting it.

## Before opening a PR

At minimum, run the Windows test/build pair, all six contract validators, and the MSI build and
verification commands above. Then install that exact MSI on Windows and exercise the changed path
through a process restart. The GitHub Actions run is the final cross-platform check and publishes
the unsigned `jazz-capture-msi-unsigned` artifact from its Windows job.
