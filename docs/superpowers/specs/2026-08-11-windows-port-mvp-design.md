# Windows Capture Client MVP — Design

Date: 2026-08-11
Status: Approved (MVP scope of keboola/jazz-desktop-client#18)

## Goal

Populate the reserved `windows/` tree with the first working slice of the native .NET capture
client described in issue #18: a portable engine that reproduces the shared contract exactly, plus
a minimal Windows tray host that captures real desktop activity and commits it to a local Jazz
Archive. The MVP must build and run on a real Windows 11 x64 machine.

Full acceptance of issue #18 (MSI installer, start-at-login, liveCompatibility projection,
enrollment security, upload queue, kill-mid-recording qualification evidence) is deliberately out
of scope and remains tracked by the issue.

## Prior art

- keboola/jazz#149 and keboola/jazz#152 (user manana2520) are reference material only. They assume
  direct OTLP streaming is the capture truth; the current architecture is local-first with the
  Jazz Archive as canonical. Worth lifting: the portable-engine/host split, Win32 low-level input
  hooks, UI Automation click-target resolution, DPAPI secrets (post-MVP), WiX MSI (post-MVP).
- The macOS client (`macos/Sources/JazzCaptureCore` + `JazzCapture`) defines the module
  boundary the Windows client mirrors. No code is shared; only `contract/` is shared.

## Architecture

```
windows/
├── JazzCapture.sln
├── Sources/
│   ├── JazzCaptureCore/    # net8.0 class library, portable, no OS-privileged APIs
│   │                       # (one exception: the guarded directory fsync in Journal/Durability)
│   └── JazzCapture/        # net8.0-windows WPF executable: tray host
└── Tests/
    └── JazzCaptureCoreTests/  # xUnit, runs on macOS and Windows
```

### JazzCaptureCore (portable engine)

- `ActivityEvent` model with canonical JSON encoding matching
  `contract/schema/activity-event.schema.json`.
- Capture capability observation model matching
  `contract/schema/capture-capability-observation.schema.json`; every capability the MVP host does
  not implement (narration audio, for example) is recorded as an explicit capability transition,
  never silently omitted.
- OTLP logs/traces projection that deep-compares byte-for-byte against every fixture in
  `contract/conformance/fixtures`, using the same runner contract as the Swift
  `OtlpMapperConformanceTests`.
- `CaptureJournal` subset: admit producers before asynchronous work starts, record commits,
  survive process kill between admit and commit (crash-safe append-only file).
- Deterministic stored-ZIP32 archive writer producing a `.jazz-archive` that passes
  `contract/archive/validate_archives.py`. Same archive ID, logical content digest, and raw ZIP
  SHA-256 across repeated finalizations of the same capture.

### JazzCapture (Windows tray host)

- WinForms `NotifyIcon` tray inside a WPF app: Start / Stop / Confirm / Reject, recording
  indicator.
- `WH_MOUSE_LL` + `WH_KEYBOARD_LL` listen-only hooks; typed text is redacted in the engine before
  anything is journaled.
- UI Automation (`IUIAutomation`) click-target resolution off the hook thread: role, accessible
  name, window title, bounding box.
- Foreground application tracking (`GetForegroundWindow` + process lookup) emitting `navigate`
  events; `url` is `app://<processName>` (the Windows counterpart of the macOS bundle-id form).
- Focused-window screenshot per click (PrintWindow/BitBlt), stored as a content-addressed blob
  artifact.
- No narration, no enrollment, no upload in the MVP; each absent capability emits the
  corresponding capability observation.

## Data flow

Input hook → engine admits producer into `CaptureJournal` → async UIA/screenshot enrichment →
observation committed → Stop closes input and writes `CaptureCommit` → user Confirms → finalizer
writes deterministic `.jazz-archive` into the local queue directory. Reject keeps local data and
creates no delivery intent. No network anywhere in the MVP path.

## Error handling

- Journal admits are flushed before enrichment starts; a killed process leaves an explicit gap
  record, not a hole.
- Hook or UIA failures degrade to capability observations, never crash the session.
- The archive finalizer is idempotent: re-running on the same committed capture yields
  byte-identical output.

## Testing

- xUnit conformance suite over all `contract/conformance/fixtures` (deep JSON compare) — runs on
  macOS during development and on Windows.
- Journal crash-safety unit tests (kill between admit and commit).
- Archive determinism test: finalize twice, compare SHA-256.
- Contract validators as the outer gate: `uv run --script contract/archive/validate_archives.py`
  against an archive produced by the engine.
- Manual end-to-end on 192.168.0.14: install SDK, build, run tray, record a short session,
  confirm, validate the produced archive.

## Development workflow

Contract-first: engine and tests iterate on macOS (.NET SDK 8 via the official dotnet-install
script); the host builds and runs on the Windows machine (SDK + git via winget), synced over SSH.
Implementation is parallelized across subagents per component (contract model + OTLP projection,
journal + archive writer, Windows host).
