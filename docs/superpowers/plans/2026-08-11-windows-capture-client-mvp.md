# Windows Capture Client MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Populate `windows/` with a .NET 8 capture client whose portable engine reproduces the OTLP conformance goldens and produces a `.jazz-archive` that passes `contract/archive/validate_archives.py`, plus a minimal WPF/NotifyIcon tray host that captures real input on Windows 11.

**Architecture:** Mirror of the macOS split — `Sources/JazzCaptureCore` (net8.0, pure BCL, no OS APIs) holds contracts, OTLP projection, journal, and archive writer; `Sources/JazzCapture` (net8.0-windows, WPF) holds Win32 hooks, UIA, and tray UI. Only `contract/` is shared with macOS.

**Tech Stack:** .NET 8 SDK 8.0.423, xUnit 2.5.3, System.Text.Json (parsing only — canonical JSON is hand-written), P/Invoke (user32/kernel32), UIAutomationClient COM interop.

## Global Constraints

- Solution already scaffolded: `windows/JazzCapture.sln` with `Sources/JazzCaptureCore` + `Tests/JazzCaptureCoreTests` (net8.0, nullable enable, implicit usings).
- Core must compile and test on macOS AND Windows: **no Windows-only APIs in JazzCaptureCore**.
- dotnet on macOS: `~/.dotnet/dotnet` (export `PATH="$HOME/.dotnet:$PATH"`, `DOTNET_CLI_TELEMETRY_OPTOUT=1`).
- All files English; no emoji; no hardcoded config values where a config record can carry them.
- NEVER write JSON `null` for an absent optional field — omit the key.
- All manual formatting uses `CultureInfo.InvariantCulture`; all file writes use `new UTF8Encoding(false)` (no BOM); NDJSON lines end with `\n` only.
- Canonical JSON digests use the hand-written JCS (Task 1) — never `JsonSerializer` property order.
- Commit after each green task with a conventional-commit message; do NOT add Co-Authored-By lines.

## Normative annexes (MUST READ per task)

Three digests distilled from the Swift implementation and the contract validators. Absolute paths (session scratchpad):

- **ANNEX-OTLP**: `/private/tmp/claude-501/-Users-padak-github-jazz-desktop-client--claude-worktrees-jazz-desktop-apache-license-f2c4f8/3e5c267f-239c-432b-b4ad-d90c07c0632a/scratchpad/digests/otlp-conformance.md`
- **ANNEX-ARCHIVE**: `.../scratchpad/digests/archive-journal.md` (same directory)
- **ANNEX-HOST**: `.../scratchpad/digests/capture-host.md` (same directory)

When an annex and this plan disagree, the annex wins; when an annex and `contract/` fixtures disagree, the fixtures win.

---

### Task 1: JCS canonicalizer + JSON test comparer

**Files:**
- Create: `windows/Sources/JazzCaptureCore/Json/JsonCanonicalizer.cs`
- Create: `windows/Sources/JazzCaptureCore/Json/JsonStrictParser.cs`
- Test: `windows/Tests/JazzCaptureCoreTests/JsonCanonicalizerTests.cs`, `windows/Tests/JazzCaptureCoreTests/Support/JsonDeepComparer.cs`

**Interfaces:**
- Produces: `static string JsonCanonicalizer.Canonicalize(JsonNode? value)` — RFC 8785 JCS text; `static string JsonCanonicalizer.Sha256Hex(JsonNode? value)` — lowercase hex of sha256(UTF-8 JCS).
- Produces: `static JsonNode? JsonStrictParser.Parse(string text)` — rejects duplicate object keys and NaN/Infinity (throws `FormatException`).
- Produces (test support): `static bool JsonDeepComparer.DeepEquals(JsonNode? a, JsonNode? b)` — objects order-insensitive, arrays order-sensitive, numbers compared by value (decimal, fallback double), `JsonValueKind.String` ≠ `Number` ≠ `True/False`.

Rules (ANNEX-ARCHIVE §3.1): key sort = `StringComparer.Ordinal` (UTF-16 code-unit order); escape only `"` `\` `\b` `\t` `\n` `\f` `\r` + remaining C0 as `\u00xx` lowercase; raw UTF-8 for everything else; separators `,`/`:`; reject integers outside ±9007199254740991, lone surrogates, NaN/Infinity; ES6 shortest-round-trip number formatting with lowercase `e`, `+` on positive exponents, plain decimal for exponents in [-6, 21).

- [ ] Step 1: Write failing tests: (a) the RFC 8785 self-check vector — canonicalizing the parsed object from ANNEX-ARCHIVE §3.1 self-check must produce sha256 `2d5e01a318d0f0879ab568c4be289c8b1f64ef8921a53c6277d5e069978baacb`; (b) key-order vector `{"\r","1","\u0080","ö","€","😀","דּ"}` sorts in exactly that order; (c) duplicate-key parse throws; (d) number formats `333333333.3333333`, `1e+30`, `4.5`, `0.002`, `1e-27` round-trip to those exact strings; (e) DeepEquals: `64` == `64.0`, `{"a":1,"b":2}` == `{"b":2,"a":1}`, `[1,2]` != `[2,1]`, `"7"` != `7`.
- [ ] Step 2: `dotnet test` — verify FAIL (types missing).
- [ ] Step 3: Implement all three classes.
- [ ] Step 4: `dotnet test` — verify PASS.
- [ ] Step 5: Commit `feat(windows): add RFC 8785 JCS canonicalizer and strict JSON parsing`.

### Task 2: Identifiers + timestamps

**Files:**
- Create: `windows/Sources/JazzCaptureCore/Identifiers.cs`
- Create: `windows/Sources/JazzCaptureCore/Timestamps.cs`
- Test: `windows/Tests/JazzCaptureCoreTests/IdentifiersTests.cs`, `TimestampsTests.cs`

**Interfaces:**
- Produces: `static string Identifiers.UuidV7(DateTimeOffset now, Func<byte[]> rng)` (deterministic injection for tests) and convenience `UuidV7()`; `static string Identifiers.Prefixed(string prefix)` → e.g. `Prefixed("ar")` = `ar-<uuidv7>`; `static string Identifiers.EventId(string sessionId, long sequence)` → `<sessionId>-<sequence>`.
- Produces: `static long? Timestamps.UnixNanos(string iso8601)` — null on unparseable/pre-1970; `static string Timestamps.IsoMillisUtc(DateTimeOffset t)` → exactly `YYYY-MM-DDTHH:mm:ss.SSSZ`.
- Produces: `static string OtlpIds.TraceId()` (32 lowercase hex), `static string OtlpIds.SpanId()` (16 lowercase hex) — in `Identifiers.cs`.

UUIDv7 layout per ANNEX-ARCHIVE §7 (48-bit big-endian epoch ms + random, version/variant nibbles, lowercase hyphenated). UnixNanos algorithm per ANNEX-OTLP §4.7 — integer-exact: split fraction digits as string, pad/truncate to 9, add to `epochSeconds * 1_000_000_000L`; never route the fraction through DateTimeOffset.

- [ ] Step 1: Failing tests. UnixNanos vectors (ANNEX-OTLP §4.7): `"2026-06-13T10:00:00Z"` → `1781344800000000000`; `"...T10:00:00.123Z"` → `1781344800123000000`; `".123456789Z"` → `…123456789`; `"2026-06-13T12:00:00.5+02:00"` → `1781344800500000000`; null for `""`, `"not-a-date"`, `"2026-06-13"`, `"1969-12-31T23:59:59Z"`. UuidV7 regex `^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$` and timestamp prefix from injected clock. TraceId/SpanId length + lowercase hex.
- [ ] Step 2: verify FAIL. Step 3: implement. Step 4: verify PASS.
- [ ] Step 5: Commit `feat(windows): add identifiers, UUIDv7, and OTLP nanosecond timestamps`.

### Task 3: ActivityEvent model + OTLP mapper + conformance runner

**Files:**
- Create: `windows/Sources/JazzCaptureCore/ActivityEvent.cs` (record types `ActivityEvent`, `ApplicationRef`, `EventTarget`, `BoundingBox`, `DragEnd`)
- Create: `windows/Sources/JazzCaptureCore/Otlp.cs` (`OtlpAnyValue`, `OtlpKeyValue`, request writers)
- Create: `windows/Sources/JazzCaptureCore/OtlpMapper.cs` (`SessionContext`, `LogsRequest`, `TraceRequest`)
- Test: `windows/Tests/JazzCaptureCoreTests/OtlpMapperConformanceTests.cs`, `OtlpMapperTests.cs`, `Support/ContractPaths.cs`

**Interfaces:**
- Consumes: `Timestamps.UnixNanos`, `JsonDeepComparer`, `JsonStrictParser`.
- Produces: `sealed record SessionContext(string SessionId, string TraceId, string SpanId, string StartedAt, string? Kind, string User, string InstanceName, string? AreaId, string? AreaName, string ServiceName = "jasnost-capture")`.
- Produces: `static JsonObject OtlpMapper.LogsRequest(IReadOnlyList<ActivityEvent> events, SessionContext ctx, Func<DateTimeOffset>? now = null)` and `static JsonObject OtlpMapper.TraceRequest(SessionContext ctx, string endedAt, Func<DateTimeOffset>? now = null)`.
- Produces (test support): `static string ContractPaths.Root()` — walks ≤8 parents from `AppContext.BaseDirectory` to find `contract/conformance/fixtures`, throws if absent.

Mapping is EXACTLY ANNEX-OTLP §4 (attribute tables 4.4/4.5/4.6 in literal order, AnyValue typing 4.3, envelope 4.1, provenance rules pitfall 6). Runner contract per §5: all `contract/conformance/fixtures/*.json` sorted ordinally; context strings default `""`; `kind`/`area_id`/`area_name` empty→null; deep compare produced vs golden for both logs and traces.

- [ ] Step 1: Write the conformance test first (it is the spec): load every fixture, build context + events, assert `JsonDeepComparer.DeepEquals(produced, golden)` for `logs` and `traces`, with failure message naming file + which side. Add OtlpMapperTests for narration total-replacement (13 keys even when event carries target/sequence) and numeric-omission (no `sequence`/`click_count`/`drag_end.*`/boundingBox keys when absent).
- [ ] Step 2: verify FAIL (6 fixtures × 2 asserts).
- [ ] Step 3: Implement models + mapper. ActivityEvent deserialization via System.Text.Json attributes, unknown properties ignored; mapper builds `JsonObject` attribute lists in literal order.
- [ ] Step 4: `dotnet test` — all conformance fixtures PASS on macOS.
- [ ] Step 5: Commit `feat(windows): ActivityEvent model and OTLP projection passing conformance goldens`.

### Task 4: Capability observations + state machine

**Files:**
- Create: `windows/Sources/JazzCaptureCore/CaptureCapability.cs`
- Test: `windows/Tests/JazzCaptureCoreTests/CaptureCapabilityTests.cs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `enum Capability { PointerCapture, KeyboardCapture, AccessibilityContext, ScreenCapture, AudioCapture }` with `string Token` mapping (`pointer.capture` etc.); `sealed record CapabilitySample(Capability Capability, string Authorization, string Availability, string Reason, string? Detail)`; `sealed class CapabilityStateMachine` with `CapabilityObservation? Observe(CapabilitySample sample, string observedAt)` returning null for unchanged (authorization, availability) pairs; `CapabilityObservation.ToPayload()` → `JsonObject` matching `capture-capability-observation.schema.json` v1.

Transition derivation table and legal-triple validation per ANNEX-OTLP §6 / ANNEX-HOST §5 (initial/granted/revoked/restored/temporarily_disabled/source_failed/authorization_changed; `authorization != granted ⟹ availability == unavailable`; previous pair present iff transition ≠ initial and must differ).

- [ ] Step 1: Failing tests: initial emission; repeated identical poll → null; granted→revoked; unavailable(source_failure)→restored; `capture_disabled_by_policy` initial for a policy-disabled modality; payload JSON keys/values for one observation validated against the schema file (load `contract/schema/capture-capability-observation.schema.json`, check required keys + const schemaVersion 1 by direct assertions).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS.
- [ ] Step 5: Commit `feat(windows): capture capability observation state machine`.

### Task 5: CaptureJournal (crash-safe subset)

**Files:**
- Create: `windows/Sources/JazzCaptureCore/Journal/CaptureJournal.cs`, `Journal/JournalDocuments.cs`, `Journal/Durability.cs`
- Test: `windows/Tests/JazzCaptureCoreTests/CaptureJournalTests.cs`

**Interfaces:**
- Consumes: `JsonCanonicalizer.Sha256Hex`, `Identifiers`.
- Produces: `sealed class CaptureJournal` with:
  - `static CaptureJournal Prepare(string root, string archiveId, string captureId, string streamId)` — creates `.capture-journal/<archiveId>/` as exclusive claim (throws if exists), persists checkpoint, lifecycle `starting`.
  - `void StartRecording()` → lifecycle `recording`.
  - `ReservationToken Reserve()` — allocates next streamSequence, durable pending WAL entry, fsync, returns token `{ReservationId, ArchiveId, CaptureId, StreamId, StreamSequence}`.
  - `void ResolveObservation(ReservationToken token, JsonObject record)` — write-ahead intent (resolvingObservation + JCS digest), then in-memory record store, then observation state; idempotent on same digest, conflict on different.
  - `void ResolveGap(ReservationToken token, string reason, string detail)`.
  - `void CloseInput()` / `void BeginDraining()` — lifecycle gates.
  - `CommitResult Commit(string endedAt)` — refuses unresolved reservations; returns ordered records + gaps for the archive writer.
  - `static CaptureJournal Reopen(string root, string archiveId)` — checkpoint + WAL replay (contiguous, filename `%020d.json` order), pending→gap conversion via `RecoverInterrupted(endedAt)`.
- Durability: `Durability.WriteAtomic(path, bytes)` = temp + `File.Move(overwrite: false)` pattern + `FileStream.Flush(true)`; directory flush documented as best-effort on Windows (P/Invoke FlushFileBuffers on FILE_FLAG_BACKUP_SEMANTICS handle), per ANNEX-ARCHIVE §8.23.

Semantics per ANNEX-ARCHIVE §5: admit-before-async, WAL mutation guards, poison-on-fsync-failure, token identity, idempotence rules.

- [ ] Step 1: Failing tests: (a) Reserve assigns 0,1,2…; (b) ResolveObservation then Reopen → record retained with matching digest; (c) kill between Reserve and Resolve (simulate: new journal instance from disk without resolving) → RecoverInterrupted converts to gap `recovery_truncation`; (d) double Prepare on same archiveId throws; (e) ResolveObservation with different record for same token throws conflict; (f) Commit with pending reservation throws; (g) WAL replay from checkpoint reproduces identical state (compare Commit outputs).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS.
- [ ] Step 5: Commit `feat(windows): crash-safe capture journal with WAL and recovery`.

### Task 6: Archive documents, digests, and directory finalizer

**Files:**
- Create: `windows/Sources/JazzCaptureCore/Archive/ArchiveDocuments.cs` (manifest/session/commit/record/inventory builders as `JsonObject` factories)
- Create: `windows/Sources/JazzCaptureCore/Archive/ArchiveDigests.cs`
- Create: `windows/Sources/JazzCaptureCore/Archive/ArchiveWriter.cs`
- Test: `windows/Tests/JazzCaptureCoreTests/ArchiveDigestsTests.cs`, `ArchiveWriterTests.cs`

**Interfaces:**
- Consumes: `JsonCanonicalizer`, `Identifiers`, journal `CommitResult`.
- Produces: `static string ArchiveDigests.TextDigest(IEnumerable<string> lines)`; `static string ArchiveDigests.OrderedObservationDigest(IReadOnlyList<JsonObject> records)`; `static string ArchiveDigests.ArtifactSetDigest(IReadOnlyList<JsonObject> artifacts)`.
- Produces: `sealed record ArchiveIdentity(string ArchiveId, string OriginId, string CaptureId, string StreamId, string SessionId, string ActorId, string SourceId, string CommitId)`; `static ArchiveIdentity ArchiveIdentity.Mint()`.
- Produces: `sealed class ArchiveWriter` with `string WriteFinalized(string outputDir, ArchiveIdentity ids, SessionMetadata meta, IReadOnlyList<JsonObject> records, IReadOnlyList<GapEntry> gaps, IReadOnlyList<CapabilityObservation> capabilityObservations)` → returns the archive directory path. `SessionMetadata` = `record(string StartedAt, string EndedAt, string ConsentedAt, string PolicyVersion, string[] Modalities, string[] ExcludedApplications, string ProducerName, string ProducerVersion, string SourceKind, string[] SourceCapabilities, string[] UnavailableCapabilities)`.

Build order EXACTLY ANNEX-ARCHIVE §3.7. Layout §2, minimal archive shape §4.2 (capability observations become additional `jazz.capture-capability-observation` records on the same stream, with contract entries added to `manifest.contracts`). records.ndjson sorted by (streamId, streamSequence), LF-only, compact JSON with keys in a FIXED emission order (canonical digest is order-insensitive; file bytes just need to be stable for inventory).

- [ ] Step 1: Failing tests: (a) TextDigest of empty list == `e3b0c442…b855`; (b) reproduce the worked minimal-archive digests from ANNEX-ARCHIVE §4.2: build that exact record/commit and assert `orderedObservationDigest == 73616818e3891db9b8662adf47c43f92da2fd42a2999fc0267fd64951865b264` and commit JCS digest == `b2cd59aa0380c74e58617150d9a885fbfa5198cf634859bd19c60cfe7bc35c94`; (c) WriteFinalized twice into two dirs → identical contentDigest and identical inventory digests; (d) full outer gate: `uv run --script contract/archive/validate_archives.py <outputDir>` exits 0 (invoke via `Process`, skip test with clear message if `uv` absent).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS including the validator subprocess test on macOS.
- [ ] Step 5: Commit `feat(windows): deterministic Jazz Archive writer passing contract validation`.

### Task 7: Deterministic stored-ZIP32 container writer

**Files:**
- Create: `windows/Sources/JazzCaptureCore/Archive/JazzArchiveContainer.cs`
- Test: `windows/Tests/JazzCaptureCoreTests/JazzArchiveContainerTests.cs`

**Interfaces:**
- Consumes: nothing (pure bytes).
- Produces: `static void JazzArchiveContainer.Export(string archiveDir, string outputZipPath)` — walks files excluding `sync/**`, sorts entry names `StringComparer.Ordinal`, writes local headers / central directory / EOCD per ANNEX-ARCHIVE §1.1 with `BinaryWriter` little-endian; `static string JazzArchiveContainer.Sha256File(string path)`.

Do NOT use `System.IO.Compression`. CRC-32 via `System.IO.Hashing.Crc32` (add package reference; verify byte order — the ZIP field is the standard CRC value little-endian in the header struct).

- [ ] Step 1: Failing golden test: run `Export` over `contract/archive/fixtures/02-labeled-narration` and assert the output file is byte-identical to `contract/archive/container/fixtures/01-canonical-v1.jazz-archive` — 25 072 bytes, sha256 `49453bce721306d13da8befa69fc9632351a9ef477017aac2f3e4a1c375aaeda`. Also: name validation rejects backslash/`..`; determinism (export twice → identical bytes).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS — this single golden pins every container rule.
- [ ] Step 5: Commit `feat(windows): deterministic stored-ZIP32 jazz-archive container writer`.

### Task 8: CaptureEngine orchestration

**Files:**
- Create: `windows/Sources/JazzCaptureCore/CaptureEngine.cs`, `CaptureEngineTypes.cs` (RawInput DTOs the host feeds in)
- Test: `windows/Tests/JazzCaptureCoreTests/CaptureEngineTests.cs`

**Interfaces:**
- Consumes: everything above.
- Produces: `sealed class CaptureEngine` (single-threaded via `Channel<EngineCommand>` internally):
  - `static CaptureEngine Start(EngineConfig config)` — config = `record(string RootDir, string User, string InstanceName, string ProducerVersion, string[] ExcludedApplications, bool ScreenshotsEnabled /* false in MVP */, Func<DateTimeOffset> Clock)`. Mints identity, prepares journal, appends `session_start` (url `app://session`), emits initial capability observations (pointer/keyboard/accessibility granted+available; screen/audio `capture_disabled_by_policy` when disabled).
  - `void Observe(HostEvent e)` — host-normalized event (`Click`, `Drag`, `ContextMenu`, `Scroll`, `Input`, `Keydown`, `Copy/Cut/Paste`, `Navigate` variants carrying the fields from ANNEX-HOST §1); engine assigns sequence via journal Reserve→ResolveObservation, builds the ActivityEvent payload + record envelope, stamps redaction (`Redaction.RedactTyped` — implement the two rules from ANNEX-HOST §2: email → `•••@•••`, ≥7-digit runs → same-length `•`, sanitize to 200 chars).
  - `void ObserveCapability(CapabilitySample s)`.
  - `StopResult Stop()` — session_end, drain, commit; returns committed state summary.
  - `string ConfirmAndExport(string queueDir)` — writes finalized archive directory + assertion (`decision: confirm` in `sessions/<dir>/assertions.ndjson` — NOTE: write BEFORE finalization digests so inventory covers it), exports `.jazz-archive` via Task 7, returns zip path. `void Reject(string reason)` — appends reject assertion, nothing queued.
- Produces: `static (string? Value, bool WasMasked) Redaction.RedactTyped(string raw)` in `Redaction.cs`.

- [ ] Step 1: Failing tests: (a) Start→3 clicks→Stop→ConfirmAndExport produces a zip; unzip-free check: validator passes on the pre-zip directory (subprocess as in Task 6); (b) sequences strictly increasing, session_start first, session_end last; (c) typed input `"john@doe.com 12345678"` → value `"•••@••• ••••••••"`, inputMasked true; (d) Reject leaves directory intact and produces no zip; (e) ConfirmAndExport twice → identical zip bytes.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS.
- [ ] Step 5: Commit `feat(windows): capture engine orchestrating journal, redaction, and archive export`.

### Task 9: Windows tray host

**Files:**
- Create: `windows/Sources/JazzCapture/JazzCapture.csproj` (`net8.0-windows`, `<UseWPF>true</UseWPF>`, `<UseWindowsForms>true</UseWindowsForms>`, `<EnableWindowsTargeting>true</EnableWindowsTargeting>` so it restores on macOS)
- Create: `App.xaml`, `App.xaml.cs`, `TrayHost.cs` (NotifyIcon menu), `Capture/InputHooks.cs` (WH_MOUSE_LL + WH_KEYBOARD_LL on a dedicated pump thread), `Capture/UiaResolver.cs` (STA worker, ElementFromPoint with CacheRequest, 300 ms timeouts), `Capture/ForegroundTracker.cs` (SetWinEventHook EVENT_SYSTEM_FOREGROUND), `Capture/KeyClassifier.cs` (host-side VK mapping feeding engine), `ReviewWindow.xaml(.cs)` (Confirm/Reject + status)
- Modify: `windows/JazzCapture.sln` (add project)

**Interfaces:**
- Consumes: `CaptureEngine`, `HostEvent` DTOs, `CapabilitySample`.
- Produces: a running tray app: Start/Stop capture menu items, REC state with event count, Review window with Confirm (→ `ConfirmAndExport("%LOCALAPPDATA%\\Jasnost\\queue")`) and Reject, hook re-arm watchdog emitting capability samples.

Threading and API mapping EXACTLY per ANNEX-HOST §7 (hook callbacks: struct read + enqueue only, <300 ms; ToUnicodeEx with `1<<2` flag; UIA on STA worker with CacheRequest; own-process exclusion at three layers; foreground `navigate` via WinEvent hook). MVP simplifications allowed: no screenshots (`ScreenshotsEnabled: false` + `capture_disabled_by_policy` observation), no narration (same), no click-highlight overlay, no drag coalescing beyond the two-phase click/drag distinction, scroll throttle 0.8 s.

- [ ] Step 1: Build check on macOS: `dotnet build windows/Sources/JazzCapture` (EnableWindowsTargeting makes this compile-only). No unit-test cycle for Win32 plumbing — verification is Task 10's live run. KeyClassifier IS unit-testable: add `windows/Tests/JazzCaptureCoreTests`-style tests only if the classifier lands in Core; otherwise test on-device.
- [ ] Step 2: Implement incrementally: TrayHost skeleton → InputHooks → ForegroundTracker → UiaResolver → wiring to engine → ReviewWindow.
- [ ] Step 3: `dotnet build -c Release` green on macOS.
- [ ] Step 4: Commit `feat(windows): WPF tray host with low-level hooks and UIA click targets`.

### Task 10: Deploy, run, and validate on 192.168.0.14

**Files:** none new (scripts inline).

- [ ] Step 1: Sync sources: `tar czf` the `windows/` + `contract/` trees, `scp` to the Windows box, extract (PowerShell `tar` is available on Win11).
- [ ] Step 2: `"C:\Program Files\dotnet\dotnet.exe" test windows\JazzCapture.sln -c Release` over ssh — conformance + archive suites must pass on Windows too.
- [ ] Step 3: `dotnet publish Sources/JazzCapture -c Release -r win-x64 --self-contained false`; launch the tray app in the interactive session (ssh runs in session 0 — use `schtasks /create /sc once /it` or ask the user to double-click; document what was done).
- [ ] Step 4: Record a short real session (user interaction needed OR synthetic: run the engine E2E test binary on the box), Confirm, produce `.jazz-archive`.
- [ ] Step 5: `scp` the archive back to the Mac; run `uv run --script contract/archive/validate_archives.py` on the unpacked archive and verify the zip's byte profile (own reader or `python zipfile` check for method 0 + ordering).
- [ ] Step 6: Commit any fixes; final commit `feat(windows): validated Windows capture client MVP end-to-end`.

---

## Self-review notes

- Spec coverage: engine conformance (Tasks 1–3), capability evidence (4), crash-safe journal (5), archive + validator gate (6), deterministic container (7), lifecycle + review semantics (8), host capture + UI (9), real-Windows run (10). Out-of-MVP items (MSI, narration, screenshots, liveCompatibility, enrollment) intentionally absent per spec.
- Type consistency: `ReservationToken`, `CommitResult`, `ArchiveIdentity`, `SessionMetadata`, `HostEvent`, `CapabilitySample` are defined once (Tasks 5, 6, 8) and consumed by name in later tasks.
- The two byte-golden tests (Task 7 container fixture; Task 1 JCS vector) plus the validator subprocess (Tasks 6, 8) are the outer gates that make "indistinguishable at the contract boundary" testable without a server.
