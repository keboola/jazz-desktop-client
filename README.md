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
dotnet build -c Release Sources/JasnostCapture   # tray host (net8.0-windows)
```

The client splits the same way the macOS one does: `Sources/JasnostCaptureCore` is portable and
holds the contract, OTLP projection, capture journal, and archive writer, so it builds and tests on
any platform; `Sources/JasnostCapture` is the Windows-only tray host with the input hooks, UI
Automation, and review UI. `Tools/JazzCaptureSmoke` drives one synthetic session end to end, and
`Tools/JazzUiaProbe` validates the hand-written UI Automation interop on real hardware.

The MVP captures pointer, keyboard, and accessibility context. Screenshots and narration are absent
by policy and are recorded as explicit capability observations rather than silent gaps. An MSI
installer, `liveCompatibility` projection, enrollment, and delivery remain tracked by
[issue #18](https://github.com/keboola/jazz-desktop-client/issues/18).

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
