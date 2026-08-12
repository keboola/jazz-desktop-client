# Jazz Desktop Client

Native, consent-based desktop capture clients for Jazz. Each client adopts the same capture wire
without sharing platform-specific code.

```
contract/  language-neutral capture contracts and OTLP golden fixtures
macos/     Swift 6 menu-bar client
windows/   .NET 8 tray client
```

The clients capture only during an explicitly started session. The default path records canonical
observations, screenshots, and narration into a crash-safe local journal and needs no network.
Stopping commits the local capture; only an explicit archive-level confirmation deterministically
finalizes and queues one immutable `.jazz-archive` for delivery. Rejection stays local and creates
no upload intent. An explicit `liveCompatibility` policy retains the older OTLP/Keboola Files
projections during migration, using the same canonical IDs and CaptureCommit. No client runs a
local bridge or stores a master token.

`liveCompatibility` is capture-scoped and frozen when recording starts. It projects the complete
canonical record surface—not only pointer/keyboard activity—including capability transitions and
auditable Capture Coach interactions, artifact metadata, and the final commit. Sending raw
microphone PCM for live Coach analysis is a separate opt-in and is never implied by compatibility
delivery.

## Contract ownership

contract/ is the source of truth for client-facing capture contracts. Every desktop implementation
must reproduce the OTLP goldens in contract/conformance/fixtures. The processor pins this
repository as a Git submodule and reads contract/ from it, so its mirror mapping is checked against
exactly the same fixtures.

The contract currently contains the emitted ActivityEvent schema and the Area registry read by a
client for guided labels. Process, BDM, ontology, and other processor-only schemas remain in
[keboola/jasnost](https://github.com/keboola/jasnost).

## macOS development

```bash
cd macos
swift build
swift test
./dev-codesign-setup.sh
./build-app.sh
open "Jazz Capture.app"
```

See [macos/README.md](macos/README.md) for permissions, signing, and release instructions.
Automated tests are not the physical release gate; use the
[Real-Mac qualification evidence](docs/REAL_MAC_QUALIFICATION.md) runbook to produce one
deterministic, privacy-safe evidence bundle for the exact candidate desktop/server pair.

## Windows development

```bash
cd windows
dotnet test                                     # portable engine: contract conformance and archive
dotnet build -c Release Sources/JazzCapture   # tray host (net8.0-windows)
```

The client splits the same way the macOS one does: `Sources/JazzCaptureCore` is portable and
holds the contract, OTLP projection, capture journal, and archive writer, so it builds and tests on
any platform; `Sources/JazzCapture` is the Windows-only tray host with the input hooks, UI
Automation, and review UI. The core is not literally OS-API-free: the journal's directory metadata
barrier has no BCL equivalent, so `Journal/Durability.cs` calls `FlushFileBuffers` behind an
`OperatingSystem.IsWindows()` guard and degrades to the file-level `fsync` on other platforms. It
stays in the journal deliberately — the journal owns its own crash-safety guarantee, and a barrier
the host injects is a barrier a host can forget to wire. `Tools/JazzCaptureSmoke` drives one synthetic session end to end, and
`Tools/JazzUiaProbe` validates the hand-written UI Automation interop on real hardware.

`Sources/JazzEnrollmentSecurity` mirrors the macOS module of the same name: the flattened Ed25519
JWS verifier for a copied enrollment bundle, its durable replay ledger, and the device-bound claim
and sealed-bundle grammar. It is verified against the shared vectors under `contract/enrollment/`,
so the two clients cannot quietly disagree about which bundle is acceptable. `net8.0` has no Ed25519
in `System.Security.Cryptography`, so signature verification uses Bouncy Castle's managed RFC 8032
implementation; everything else is BCL.

**Device-bound enrollment is not yet trustworthy on Windows.** macOS seals the device identity to
the Secure Enclave. The Windows counterpart is CNG with a TPM-backed key, and it does not exist yet:
what ships is `DevelopmentUnprotectedKeyBackend`, which holds the private scalar in process memory
and persists it in the clear, so the identity is copyable and a stolen bootstrap could be redeemed
from a second machine. A host must implement `IDeviceEnrollmentKeyBackend` against CNG before that
path reaches a user. The vault refuses the development backend unless the caller asks for it by
name, and the backend identifier it writes into the persisted record contains the word `INSECURE`,
so a hardware-backed vault will not load an identity it created. Redemption's HTTPS transport
(`IDeviceRedemptionTransport`) is likewise a seam this module does not fill.

**Confirmed archives are queued durably; nothing sends them yet.** `Sources/JazzCaptureCore/Delivery`
ports the macOS whole-archive delivery model: confirming a reviewed capture exports one immutable
`.jazz-archive` into the queue root and commits one durable record beside it, carrying the archive,
origin and capture identities, the format version and revision, the logical content digest, the raw
ZIP SHA-256 and the byte length. Every attempt re-verifies the package against that record before the
bytes are handed anywhere, so a retry can only ever send what was confirmed. An attempt is committed
before the request that makes it, retryable and permanent failure are distinct outcomes, and the
retry backoff is bounded and jittered from the durable delivery identity, so it survives a relaunch
and different archives do not wake together. The contract-shaped state is written to
`sync/delivery.ndjson` inside the archive directory, which the inventory never hashes and the
container writer never exports. Rejection creates no upload intent of any kind.

What is missing is the last leg. `IArchiveDeliveryTransport` is an interface with a fake behind it
for the tests and no HTTP client: there is no archive-ingest server to try one against on this
machine, and an untested network path would be worth less than an honest gap. A host must implement
that interface — intent, opaque direct upload, finalize, status, per
[ADR 0003](docs/adr/0003-confirmed-archive-delivery.md) — and supply the scoped device credential,
which depends on the CNG work above. Until then a confirmed archive sits in the queue, and the tray
says how many are waiting.

The MVP captures pointer, keyboard, and accessibility context. Screenshots and narration are absent
by policy and are recorded as explicit capability observations rather than silent gaps.
`liveCompatibility` projection, credential activation, and the delivery transport remain tracked by
[issue #18](https://github.com/keboola/jazz-desktop-client/issues/18).

### Windows installer

One command, on Windows, with the .NET 8 SDK:

```powershell
pwsh windows/installer/build-msi.ps1     # -> windows/installer/artifacts/Jazz.msi
pwsh windows/installer/Verify-Msi.ps1    # asserts what the package actually does
```

**The MSI is not code signed.** There is no code-signing certificate for this client, so Windows
SmartScreen shows an "unrecognized app" warning and Defender may quarantine the download. That is
expected for every build produced from this repository today, and the only way past it is
*More info* then *Run anyway*. Signing is not a build flag someone forgot; it needs a certificate
this project does not have.

The package is per-user and asks for no administrator prompt. It installs the self-contained tray
host into `%LOCALAPPDATA%\Jazz\App`, adds a Start Menu shortcut, and registers one `HKCU` `Run`
value so the client starts at login the way the macOS client's login item does. Installing a newer
build replaces the older one: the UpgradeCode is fixed and the ProductCode is derived from the
version.

Uninstalling removes `%LOCALAPPDATA%\Jazz\App`, the shortcut, and the `Run` value — and nothing
else. Recordings, queued archives, and settings live one level up in `%LOCALAPPDATA%\Jazz`, which
the installer never writes into and never removes. `Verify-Msi.ps1` asserts that against the built
database rather than trusting the authoring, and CI runs it on every package it builds.

The same package can be built on macOS or Linux without a Windows machine, for developers who work
there. It needs GNU msitools (`brew install msitools`; Debian and Ubuntu ship the package without
`wixl`), and it is a second WiX authoring in a second schema, so treat the Windows build as the one
that ships:

```bash
windows/installer/build-msi.sh      # -> windows/installer/artifacts/Jazz.msi
windows/installer/verify-msi.sh     # the same assertions, via msiinfo
```

Neither path is byte-reproducible: Windows Installer requires a fresh package code in every
package, so two builds of one commit differ in that GUID and in the cabinet's timestamps. Everything
that determines what gets installed comes from `windows/installer/Jazz.Version.props`.

## Releases

The current release notes are in [CHANGELOG.md](CHANGELOG.md). Versions continue the Jazz release
line from the original `keboola/jasnost` monorepo and are published as `vX.Y.Z` GitHub tags.

## License

This repository, including the shared contract/ material, is licensed under the
[Apache License, Version 2.0](LICENSE). Redistribution must carry the attribution in
[NOTICE](NOTICE).

## Verification

```bash
uv run --script contract/validate_schemas.py
uv run --script contract/archive/validate_archives.py
uv run --script contract/live/validate_live_transport.py
uv run --script contract/live/validate_capture_coach_live.py
uv run --script contract/live/generate_capture_coach_fixtures.py --check
uv run --script contract/archive/container/generate_fixtures.py --check
cd macos && swift build && swift test
```
