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

## Qualify an MSI on Windows

Never install a test MSI into an account that already has Jazz state. Use a disposable runner or a
dedicated clean Windows account. The guarded lifecycle harness checks for an existing product,
process, data root, install root, Run entry and shortcut before mutation; its explicit switch cannot
override a dirty profile.

Run the mutation-free helper tests anywhere:

```powershell
pwsh windows/installer/tests/Test-MsiQualificationHelpers.ps1
```

On a clean disposable profile, qualify the exact package through install, launch, same-package
repair and uninstall:

```powershell
$version = dotnet msbuild windows/installer/Jazz.Version.props `
    -getProperty:JazzProductVersion -nologo
pwsh windows/installer/tests/Invoke-MsiLifecycleQualification.ps1 `
    -MsiPath windows/installer/artifacts/Jazz.msi `
    -ExpectedVersion $version.Trim() `
    -EvidenceDirectory windows/installer/artifacts/qualification `
    -AllowInstalledProductMutation
```

The report proves the exact process path and survival interval, not visible tray/UI behavior. Real
tray, capture/review, microphone, scaling, display, elevated-target, secure-desktop, second-profile
and SmartScreen behavior follows the resumable `Prepare`, `Resume`, and `Complete` procedure in
[`docs/REAL_WINDOWS_QUALIFICATION.md`](../docs/REAL_WINDOWS_QUALIFICATION.md).

Upgrade, downgrade, changed-same-version and failing-upgrade rollback qualification is tracked in
[#40](https://github.com/keboola/jazz-desktop-client/issues/40); do not infer it from a passing
same-package repair. First-run, single-instance, discoverability and update UX are tracked in
[#42](https://github.com/keboola/jazz-desktop-client/issues/42).

The implemented upgrade policy, isolated package identities, clean-runner matrix, evidence fields,
and manual rows are documented in
[`docs/WINDOWS_UPGRADE_QUALIFICATION.md`](../docs/WINDOWS_UPGRADE_QUALIFICATION.md). Never run its
mutating driver in a normal development profile; the script itself also rejects non-CI execution.

## Windows implementation guardrails

Use this checklist before coding and again during self-review. It records failure modes found while
building the installer and exact-release qualification path; applying it up front should keep them
from becoming repeated review iterations.

### Identity and runtime boundaries

- Keep product name, version, ProductCode, UpgradeCode, paths, registry names, executable name, and
  shortcut identity in `installer/Jazz.Version.props`. Build scripts, both authorings, verifiers,
  qualification tools, release workflows, and documentation must consume that source rather than
  repeat literals.
- A verifier or qualification script that runs on an installed or clean release machine must not
  require a developer SDK unless that SDK is an explicit prerequisite of the test. Read MSI tables
  or the checked-in properties directly when the release machine should need only Windows,
  PowerShell, and the self-contained package.
- Treat WiX and `wixl` as different compilers for one product contract. Verify the generated MSI
  database from both paths; source-level equality or a successful build is not evidence that the
  tables and action sequence agree.

### Lifecycle mutation and native resources

- Fail closed before any install, repair, upgrade, uninstall, or process stop. If product state,
  executable ownership/path, profile cleanliness, or another guard cannot be read conclusively,
  abort without mutation. Never add a force-clean or broad cleanup escape hatch.
- Stop or kill only the exact process created or proven to belong to the candidate executable.
  Failure to inspect a process path is a blocking result, not permission to continue. Never match
  by process name alone when mutation follows.
- Put a timeout around every `msiexec` and helper-process wait. On timeout, terminate only the exact
  owned process, record the failure, and preserve user data and diagnostic evidence.
- Release every Windows Installer, shell-link, Restart Manager, and other COM/native handle in a
  `finally` path. Tests must cover success, partial initialization, timeout, and failure cleanup.
- The current development profile may already contain a running Jazz process, an installed product,
  login registration, settings, captures, journals, or queued archives. Run mutating lifecycle
  scenarios only on a disposable clean CI runner or a dedicated clean account. Local helper and
  structural tests must remain mutation-free.
- Maintenance shutdown may stop producers, drain admitted work, and call `CaptureEngine.Stop()` to
  commit a journal. It must never call confirmation, finalization, export, or enqueue implicitly.
  A timeout or failed drain preserves the journal and fails the installer operation closed.
- Keep capture presentation aligned with admission and lifecycle state. Once producers have stopped,
  the tray icon, tooltip, and status must not claim active recording even while `_capturing` retains
  ownership of an uncommitted engine/journal. Model and test explicit stopping, retry, and fault
  presentation states.
- Do not validate mixed journal/archive trees by recursively reading every file as text. Verify
  lifecycle through the journal API or one specific known structured document; treat draft and
  archive blobs as binary unless their contract explicitly defines text.

### Evidence and release workflows

- Bind release evidence to all of: immutable tag-to-commit resolution, release target commit,
  exact asset name, byte length, SHA-256, and package identities. Download and test those bytes;
  do not rebuild a substitute. Never replace a published asset or move a release tag.
- GitHub draft releases are not visible to a normal `contents: read` workflow token. If draft
  visibility needs `contents: write`, isolate it in a resolver job that has no checkout and runs no
  repository code. Pass only the verified bytes and metadata to a separate read-only qualification
  job; use `persist-credentials: false` for its checkout.
- Keep elevated token scope at the narrowest job. Do not expose a write-capable token to checked-out
  scripts, build output, test code, or package execution. Revalidate transferred bytes in the
  read-only job before running repository code.
- Sanitize logs, JSON, and Markdown generically, including other users' profile paths, mixed slash
  styles, spaces, Windows 8.3 aliases, SIDs, usernames, and machine names. Run a final independent,
  fail-closed privacy scan before artifact upload; missing or rejected evidence must disable upload.
- State exactly what evidence proves. Process creation, exact path, and survival are not proof of a
  visible tray icon, foreground UI, microphone behavior, scaling, multiple displays, SmartScreen,
  or another interactive outcome.

### Required self-review pass

Before requesting Copilot review, search the complete diff for duplicated installer identity,
developer-only runtime dependencies, unchecked native/COM cleanup, unbounded waits, fail-open
guards, broad process or filesystem cleanup, credentials persisted into repository code, release
rebuilt in place of downloaded bytes, and unsanitized evidence. After every material review fix,
repeat that search and request a fresh Copilot review as required by the repository root
`AGENTS.md`.

## Before opening a PR

At minimum, run the Windows test/build pair, all six contract validators, the helper tests, and the
MSI build and structural verification commands above. The clean GitHub Actions Windows job runs the
mutating lifecycle gate before publishing the unsigned `jazz-capture-msi-unsigned` artifact. Follow
the real-Windows guide for interactive qualification and exact draft/published release bytes.
