# Changelog

## Unreleased

### Screenshots on Windows

- **A picture of every completed click, drag and right-click.** The Windows client now captures the
  focused window of the application the action was attributed to, as JPEG, with the cursor left out.
  Nothing else takes a picture: a keystroke, an application switch or a session boundary has no
  visual evidence worth the privacy cost. A drag is photographed where it ended, because that is
  where the user put the thing they were dragging, even though the accessibility evidence still
  describes where it started.
- **The frame is dated as an interval, not an instant.** A screenshot finishes some measurable time
  after it was asked for, so every one of them records when it was requested, when it completed, and
  how long that took on a monotonic clock — and is marked partial with that duration as its timing
  error. A wall-clock step during acquisition cannot make a frame appear to arrive before it was
  requested.
- **Pixels that cannot be accounted for are never kept.** If the window belongs to a different
  application than the event does, or no window of that application contains the target, no image is
  produced at all. Unlike macOS, the Windows client has no whole-screen fallback: Windows offers no
  way to keep a denylisted application out of a full-screen grab, so falling back would mean
  photographing the password manager the capture policy promised never to record.
- **A failed screenshot never costs the event.** The click still reaches the archive, marked as
  having no picture, and the screen capture capability is recorded as unavailable until a later
  frame succeeds — so a reader can tell an action nobody photographed from an action that never
  happened.
- **Screenshots are on by default and can be turned off from the tray.** The change applies to the
  next recording, because the capture policy an archive declares is frozen before the first event.

### Think-aloud narration on Windows

- **The microphone records inside a label and nowhere else.** Declaring what you are working on
  starts a clip; ending the label seals it. There is no session-long recording and no way to ask for
  one, so a recording always belongs to a task you named — which is what makes it reviewable — and
  someone who never declares a label never has their microphone opened at all.
- **Narration is off until you turn it on, from the tray or from Settings, and then it stays on.**
  It defaults off where the macOS client defaults on, because macOS puts up its own microphone
  consent dialog on the first recording and Windows does not: microphone access to desktop apps is
  granted once, globally, in the privacy pane, so on Windows the client itself has to be the place
  the question gets asked. Once you have answered, the answer is remembered. Like screenshots, a
  change applies to the next recording rather than the one in progress.
- **While a clip is running the tray says so.** The open-label line reads `MIC - Label: ...` for
  exactly as long as the microphone is live, and it reports what the recorder actually achieved
  rather than what the setting asked for — so a refused microphone never leaves an indicator lit.
- **A refused microphone and a broken one are different facts.** If Windows privacy settings deny
  access, the archive records a denial; if the device fails, it records a failure; either way the
  label brackets an explicit gap saying the audio is missing and why, instead of silence a reader
  would have to guess about.
- **Clips are 16 kHz mono WAV, and pauses take up their real time.** Silence inside a clip is
  recorded as silence rather than skipped, so the audio stays aligned with the events around it. A
  clip is capped at half an hour of audio, so a label left open over lunch stops the recorder rather
  than the disk.

## v0.26.0 — A Windows client, and the product is called Jazz everywhere (2026-08-11)

Two changes: Windows work can now be recorded with the same evidence guarantees as macOS work, and
the last traces of the pre-rename name are gone from the code.

### Capture on Windows

- **A native .NET 8 tray client.** Clicks, drags, right-clicks, scrolls, typed text and clipboard
  actions are recorded with the semantic target of each action — which control, in which window, in
  which application — resolved through UI Automation. Sessions start and stop from the tray icon,
  and the review window confirms or rejects the result.
- **Indistinguishable at the contract boundary.** The Windows engine reproduces every OTLP
  conformance golden byte for byte and finalizes a `.jazz-archive` that passes the same validator as
  a macOS recording. Two runs of the same capture differ only in the identities they mint.
- **The same local-first promise.** Observations reach a crash-safe journal before any asynchronous
  work begins, a producer that never finishes becomes an explicit gap rather than a silent hole, and
  killing the client mid-recording loses nothing that was already admitted. Nothing leaves the
  machine: this client has no network code at all.
- **Absent modalities are recorded, not hidden.** Screenshots and narration are not captured in this
  release. Rather than omitting them quietly, each is written into the archive as an explicit
  capability observation, so a reader can tell the difference between "nothing happened" and "this
  client could not see it".

### The name

- **Jasnost is gone from the code.** Swift and .NET module names, the macOS bundle identifier and
  Keychain service, local spool paths, the schema `$id` URIs, and the OTLP service and scope names
  all carry the product name now. The `keboola/jasnost` server repository keeps its own name and is
  still referenced by it.

### Under the hood

- Every archive, live and container fixture was regenerated so the committed digests match the
  renamed payload schema URIs. The canonical container golden shrinks from 25072 to 25045 bytes.
- CI gains a Windows job: the portable engine is tested and the tray host is compiled on
  `windows-latest`, alongside the existing contract and macOS gates.

### Upgrading from v0.25.0

**The macOS bundle identifier moved to `dev.jazz.capture`.** macOS keys Accessibility and Screen
Recording grants to the app's identity, so both must be granted again after upgrading; the app
appears as a new entry in System Settings. Recordings and spools under the old `~/.jasnost`
directory are not migrated — finalize or export anything you still need before upgrading.

**The contract identifiers changed, so the processor must be updated in lockstep.** Archives from
this release declare `https://jazz.dev/schema/…` payload schemas and project OTLP under the
`jazz-capture` service name. A processor pinned to the v0.25.0 contract will reject them.

**The Windows client is a preview.** There is no installer, no code signing, no upload delivery and
no enrollment yet: it records, reviews and exports a `.jazz-archive` locally. Those remain tracked
by [issue #18](https://github.com/keboola/jazz-desktop-client/issues/18).

## v0.25.0 — Local-first Jazz Archive and Capture Coach (2026-07-29)

This release changes the desktop client from a network-oriented event sender into an offline-first
process evidence recorder. Nothing leaves your Mac until you have looked at it and said yes.

### The shift: record, review, then send

- **Your recording is yours until you confirm it.** Clicks, labels, narration, screenshots,
  capability changes, provenance and explicit gaps are committed to a durable local journal first.
  You review the result, and only then is one deterministic `.jazz-archive` finalized and queued for
  upload. Rejecting a recording never creates a server upload.
- **One file, verifiable anywhere.** A confirmed capture becomes a single package whose content
  digest, byte length and exact bytes survive retries, restarts and transfer between machines.
  UUIDv7-based identities for archives, captures, streams, observations, artifacts, labels and
  upload operations make a package safe to share without collisions.
- **Confirmed upload is the default.** The previous live streaming mode remains available as an
  explicit `liveCompatibility` setting; it projects the same canonical identities, artifacts and
  commit while the archive stays the source of truth.

### New in v0.25.0

- **Capture Coach.** While you record, Jazz can prompt for the things a reader will need later —
  the purpose of a step, the decision rule, the expected result, what happens on an exception.
  Prompts and answers are journaled as auditable evidence. Coach can never block capture, stop or
  confirmation, and its live channel is opt-in and off by default.
- **Richer interaction evidence.** Text selection, clipboard payloads, double-click versus two
  single clicks, drag ranges, and the real page URL when an application exposes it. Browser
  accessibility enrichment now accepts a richer focused target only when it actually covers the
  physical click, so a click on a list row is no longer attributed to whatever field has focus.
- **Signed, device-bound enrollment.** Enrollment bundles are verified as flattened Ed25519 JWS
  against a code-signed issuer, and redeemed with a Secure Enclave key so the credential is sealed
  to this Mac. Rollback, reused bundle ids and authority substitution fail closed before any
  token-bearing network call.
- **Evidence playback and guided replay.** Replay a recording to understand it, or hand a reviewed
  process to another enrolled Mac. Guided replay assists a human with evidence and semantic
  locators; it never treats raw screen coordinates as cross-machine authority.
- **Interruptions stay visible.** Reopening a process label creates a separate evidence interval
  linked by validated lineage rather than silently resuming, and capability observations now
  distinguish a denied permission from temporary OS suppression and from source failure.
- **Fail closed instead of quietly incomplete.** Capture refuses to start a screenshot-enabled
  session until Screen Recording is active, and review diagnostics name the missing permission
  rather than producing a promised-but-empty visual modality. A journal write failure stops capture
  immediately and leaves the durable prefix for relaunch recovery, instead of letting the menu bar
  keep counting interactions that are no longer being recorded.

### Under the hood

- The capture journal is now a write-ahead log with checkpoints. Per-observation cost is constant
  regardless of how long you record; a 30-minute session no longer pays quadratic re-hashing.
- The upload queue lists without re-hashing every queued package, retries with bounded jittered
  backoff, and one damaged package no longer hides unrelated deliveries.
- New `JazzCaptureTests` target covering the executable layer, alongside the existing core and
  enrollment suites.

### Upgrading from v0.24.0

Delivery now defaults to **confirmed archive**: recordings wait for your review instead of
streaming as they happen. If you depend on the previous behaviour, switch Delivery to
`liveCompatibility` in Settings. Existing spools are left untouched and are not re-sent.

Screen Recording is now required to start a session with screenshots enabled. Grant it in
Settings → Permissions and use **Quit & Reopen** — macOS applies the grant only to a fresh launch.

## v0.24.0 — Jazz Desktop Client gets its own home (2026-07-22)

This is the first release from the standalone
[`keboola/jazz-desktop-client`](https://github.com/keboola/jazz-desktop-client) repository. It
continues the Jazz version line after `v0.23.0`, previously released from the
[`keboola/jasnost`](https://github.com/keboola/jasnost) monorepo.

### What the desktop client can do today

- **Capture real desktop work on macOS.** The native menu-bar app records clicks, right-clicks,
  scrolling, app and window changes, clipboard actions, and redacted typing. Accessibility
  metadata adds the semantic target of an action: the app, window, control role, label, value,
  and on-screen position.
- **Add visual and spoken context.** Jazz can capture focused-window screenshots and narration.
  Process-mapping sessions use bracketed activity labels, while BDM workshops combine a floating
  interview panel, dense screenshots, narration, and adaptive follow-up questions from the Jazz
  review app with a built-in scripted fallback.
- **Connect recordings to the business context.** Sessions distinguish process mapping from BDM
  workshops. Area registries can turn free-form labels into guided process selection and stamp
  stable process identifiers onto captured events and narration.
- **Keep data durable and send it directly to Keboola.** Events are written to an on-disk spool
  before delivery as OTLP/JSON; narration has its own durable spool. Network failures and restarts
  retain pending data. Events go directly to the configured Keboola Data Stream and screenshots
  and audio go directly to Keboola Files—there is no local bridge or helper service.
- **Protect credentials and sensitive data.** Capture starts only with explicit user consent,
  excluded apps are never recorded, secure fields are always masked, and typed text is redacted
  before upload. Device tokens and stream endpoints live in the macOS Keychain and never in Git,
  command-line arguments, or UserDefaults.
- **Review and reuse sessions.** The app has a local session browser with upload status and labels,
  embeds the hosted Jazz review app, supports visible and interruptible replay, and checks GitHub
  Releases daily for newer versions.

### New in v0.24.0

- Added one-time, per-device enrollment bundles issued by the Jazz Data App.
- Verify each bundle against its exact canonical Keboola stack, including dedicated
  `.keboola.cloud` stacks, and remember that stack for reconnects.
- Reject master tokens in both enrollment bundles and the advanced existing-credentials flow.
- Require an already provisioned, sink-backed OTLP endpoint. Stream source and sink provisioning
  now stays server-side, so the desktop client cannot create a source that silently drops data.
- Moved the native client and its language-neutral schemas, OTLP mappings, and conformance fixtures
  into this dedicated repository. The shared contract is ready for a future Windows client while
  platform APIs remain isolated in the macOS implementation.

### Requirements

- macOS 14 or newer
- Accessibility permission for capture
- Screen Recording permission for screenshots
- Microphone permission only when narration is enabled
- A device enrollment bundle generated by a Jazz administrator
