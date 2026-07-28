# Jazz macOS Capture Agent

A native macOS menu-bar agent that captures **desktop** work — clicks, app/window switches,
scrolls, clipboard actions, typed text (redacted), and spoken narration — with the
**semantic target** of each action (which button/field, in which app/window), and emits the
**`ActivityEvent` contract** the processor consumes. The agent is a **self-sufficient,
local-first collector**: it commits canonical evidence and blobs to a Jazz Archive without a
server connection. After Stop, the user reviews the local result. Only **Confirm** finalizes and
queues one immutable `.jazz-archive`; Reject never starts delivery. No local bridge, kbagent, or
Python service is involved. The former direct OTLP/Keboola Files path remains available only as an
explicit `liveCompatibility` migration policy.

> Captures the **whole desktop** during a session (process discovery spans many apps you
> can't predict). Consent is **session-level** — you explicitly Start/Stop. Privacy is a
> **denylist** (exclude sensitive apps — password managers, banking; sensible defaults
> pre-seeded and editable), always-masked secure text fields, and typed text is redacted
> before it ever leaves the machine.

## How it works

| Layer | API | What it gives |
|-------|-----|----------------|
| Input | `CGEventTap` (listen-only) | clicks, right-clicks, scrolls, ⌘C/⌘X/⌘V, key presses |
| Semantics | Accessibility (`AXUIElement`) | element role + label + value + window title + frame at the click point |
| App context | `NSWorkspace` | frontmost app (bundle id, name); app-switch → `navigate` |
| Screenshots | `ScreenCaptureKit` (`SCScreenshotManager`) | sparse focused-window PNG on clicks |
| Narration | `AVAudioRecorder` | one think-aloud audio artifact per bracketed label |
| Durability | `CaptureJournal` + content-addressed blobs (`~/.jasnost/spool/archives`) | pending producers, gaps, commits, review, and crash recovery |
| Default delivery | confirmed `.jazz-archive` | durable whole-package queue; intent → direct opaque upload grant → finalize → status |
| Optional compatibility | OTLP/JSON + Keboola Files | explicit migration projection of the same canonical IDs and commit; signed sessions durably require both legacy Data Stream and native Jazz acknowledgements |

Each raw interaction becomes an `ActivityEvent` (matching
`../contract/schema/activity-event.schema.json`): `eventType`, `system` = app name,
`url` = `app://<bundleID>`, `pageTitle` = window title,
`target.{role,accessibleName,text,boundingBox}` from the AX element, `isSensitive` for
secure fields. Every admitted producer is recorded in the local journal before asynchronous AX,
screenshot, or audio work begins. Stop closes input, resolves pending work or explicit gaps, and
writes a transport-neutral `CaptureCommit`; it never waits for a network. Confirmation creates a
deterministic ZIP-compatible package and copies its exact bytes into the whole-archive queue. The
same archive ID, logical content digest, raw ZIP SHA-256, length, and bytes survive retries and
relaunches.

The Sessions window can also import another user's `.jazz-archive` for offline evidence playback.
Import uses the pure-Foundation deterministic stored-ZIP32 reader documented in
`../contract/README.md`: the complete package is copied and fingerprinted, bounded, contract- and
digest-verified in staging, then atomically published as a read-only finalized snapshot. A package
with the same archive ID and bytes is idempotent; different bytes are a conflict. The recorder
identity remains the immutable manifest fact. The current local user, installation origin/source,
and device name are recorded separately as append-only import receipts beside the exact package.

```
Sources/
├── JasnostCaptureCore/   # pure Foundation: contracts, journal, archive, review, queue, ids
└── JasnostCapture/       # executable: menu-bar UI + capture (AX, EventTap, ScreenCapture,
                          # Narration) + enrollment and injected HTTP delivery adapters
```

## Build & run

```bash
cd macos
swift build                 # compile
swift test                  # core unit tests (no permissions needed)
./dev-codesign-setup.sh     # ONCE: stable signing so TCC grants survive rebuilds (see below)
./build-app.sh              # assemble "Jazz Capture.app" (Info.plist + code sign)
open "Jazz Capture.app"     # launches into the menu bar (○ Jazz)
```

> **Signing & permissions across rebuilds.** macOS keys the Accessibility and Screen Recording
> grants to the app's *code identity*. With an **ad-hoc** signature (`codesign --sign -`), every
> rebuild produces a new cdhash, so macOS forgets those two grants and the Permissions panel keeps
> showing them as ⚠ even after you toggle them ON — you'd have to re-grant after each build.
> Run **`./dev-codesign-setup.sh` once** to create a stable self-signed identity (it may prompt for
> your login-keychain password); `build-app.sh` then signs with it and your grants persist across
> rebuilds. If grants ever get stuck on a stale entry, reset them with
> `tccutil reset Accessibility dev.jasnost.capture && tccutil reset ScreenCapture dev.jasnost.capture`,
> then grant again. (Microphone is keyed by bundle id and survives rebuilds either way.)

Open **Settings…** and grant all three permissions up front in the **Permissions** section
(so capturing never interrupts you with a prompt mid-session):

1. **Accessibility** — required for the event tap + reading the AX element under the cursor.
2. **Screen Recording** — required for screenshots (ScreenCaptureKit).
3. **Microphone** — required only if narration is enabled.

Each row shows live status (the panel re-checks while open, so it updates the moment you flip a
toggle in System Settings) with a **Grant** button that triggers the system prompt and opens the
matching **System Settings → Privacy & Security** pane. "Request all missing" does all three at
once. Capture itself never prompts — it checks (preflight) at Start and simply uses whatever is
granted (no Screen Recording → screenshots silently off; no Microphone → narration off;
Accessibility is the one hard requirement).

## Release build & distribution

`./build-release.sh` produces a versioned, ready-to-notarize zip of "Jazz Capture.app" and
prints the manual notarization steps. It is safe to run with **no credentials at all** — you
still get a dev-signed zip plus the instructions.

```bash
cd macos
./build-release.sh                        # version = the latest vX.Y.Z git tag
./build-release.sh --version v0.24.0      # or pin it explicitly
# distributable build (Developer ID certificate in your keychain):
JAZZ_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./build-release.sh --version v0.24.0
```

What it does:

1. **Builds + stamps** — reuses `build-app.sh` and writes the release version into both
   `CFBundleShortVersionString` and `CFBundleVersion`.
2. **Signs** — with `JAZZ_SIGNING_IDENTITY` set, codesigns with **hardened runtime +
   secure timestamp** (`codesign --options runtime --timestamp`), both required by
   notarization. `JAZZ_SIGNING_IDENTITY` must be the exact name of a **"Developer ID
   Application: …"** certificate in your keychain (list them with
   `security find-identity -v -p codesigning`). Without it, the bundle keeps the dev
   identity / ad-hoc signature and the script warns loudly that the artifact is **not
   distributable**.
3. **Zips** — `ditto -c -k --keepParent` into `Jazz-Capture-vX.Y.Z.zip`, the format
   `notarytool` expects (and the file to attach to the GitHub release).

The signing certificate and notary credentials are deliberately **not** in the repo or CI —
notarization stays a manual step, run by the release owner:

```bash
# one-time: store credentials (prompts for the app-specific password — never on argv):
xcrun notarytool store-credentials jazz-notary --apple-id <your-apple-id> --team-id <TEAMID>
xcrun notarytool submit "Jazz-Capture-vX.Y.Z.zip" --keychain-profile jazz-notary --wait
xcrun stapler staple "Jazz Capture.app"
# re-zip the STAPLED bundle (the submitted zip does not contain the ticket), then:
gh release upload vX.Y.Z "Jazz-Capture-vX.Y.Z.zip"
```

> **Why signing matters here more than usual:** macOS keys TCC grants (Accessibility /
> Screen Recording) to the app's *code identity*. An unsigned or dev-signed build has no
> stable, trusted identity on **other machines** — Gatekeeper blocks the first launch, and
> every update resets the TCC grants, forcing users to re-grant Accessibility and Screen
> Recording after each upgrade. Only a Developer ID-signed (and notarized) build installs
> and updates cleanly on machines that aren't yours.

### In-app update check

On launch — and at most **once a day** (persisted across launches) — the app asks GitHub for
the [latest release](https://api.github.com/repos/keboola/jazz-desktop-client/releases/latest) with a
short timeout and compares it to the running bundle's version (semver-ish, `v`-prefix
tolerated; the compare + JSON parsing live in `UpdateCheck` in `JasnostCaptureCore`, unit
tested). When a newer release exists, an unobtrusive menu-bar item **"Update available —
vX.Y.Z"** appears and opens the release page in the browser. Network failure is a silent
no-op — the check never blocks, dialogs, or retries eagerly. No auto-download, no Sparkle;
unbundled dev builds (`swift run`) report version `dev` and never nag.

## Setup: import a per-device enrollment bundle

An administrator creates the device on the Data App's **Devices** page and copies its one-time
enrollment bundle. In the macOS **Keboola** settings, paste that JSON and click **Import enrollment
bundle**. The bundle contains the exact stack (including dedicated/single-tenant stacks), a scoped
expiring device token, exact Keboola project/stack, Company + Area scope, canonical Jazz Archive
ingest URL, and (when enabled) a pre-provisioned OTLP endpoint.

The production path is a signed, device-bound bootstrap. The R&D runtime instead emits an explicit
`enrollmentProfile: "mvp"` administrator handoff. The desktop never infers MVP trust merely because
a signature is missing. For that compatibility profile it live-verifies the exact token id, expiry,
project and bucket scope before storing anything; production continues to require its code-signed
issuer trust. The agent:

1. requires either the explicit MVP profile or the flattened Ed25519 JWS v2 production profile,
   whose signature is verified against an out-of-band issuer, audience, and rotation-safe
   public-key set embedded in the code-signed app;
2. validates time bounds, canonical routes and exact scope, then durably admits the monotonic
   per-device generation and globally unique `bundleId` before any token-bearing request can run;
3. verifies the token on the signed exact Keboola stack, requires the live owner to equal the
   signed `projectId`, and refuses a master, over-broad, stale, disabled, or mismatched token;
4. stores the scoped token and optional stream endpoint in the macOS **Keychain**, while the
   non-secret project/stack/scope/route tuple is replaced atomically in local settings.

A raw-token connection never inherits archive routing from an earlier enrollment. Confirmed
archive delivery stays disabled until a complete bundle is imported. The enrollment Area is
authoritative for new captures and the manifest's optional `enrolledDeviceIdentity` is the exact
`jazz.device` claim; hostname remains only a source identity.

Release builds receive trust through `JAZZ_ENROLLMENT_TRUST_PLIST`; the file is consumed before
code signing and is not read at runtime. It contains `JazzEnrollmentIssuer` (canonical HTTPS
origin), `JazzEnrollmentAudience`, `JazzEnrollmentEd25519PublicKeys` (dictionary of `kid` to
unpadded base64url Ed25519 public key), and `JazzEnrollmentRedemptionOrigins` (array of canonical
HTTPS origins allowed to receive the short-lived native bootstrap header). The native gateway may
differ from the signed issuer and may use a deployment path prefix; only its code-signed origin is
trusted while the copied `redemptionURL` supplies the path. Multiple signing keys permit overlap
during rotation. A
distributable Developer ID build fails when the trust plist is absent; an unconfigured development
build runs normally but rejects every enrollment before inspecting its credential or opening the
network.

The Data App provisions the source together with its logs/metrics/traces sinks. The desktop never
creates a source, avoiding a healthy-looking source that silently drops events when it has no sinks
(keboola/jasnost#198). The collapsed **Advanced: connect with existing credentials** fallback
accepts only a non-master token plus an admin-provisioned, sink-backed endpoint; it never creates
infrastructure.

### Device-bound claim identity

Production enrollment binds a one-time bootstrap to two separate P-256 keys created by the Mac:
ES256 proof of possession and ECDH-ES response wrapping. The bootstrap bearer, server-derived
authority context, and exact claim bytes are committed to one Keychain pending record before their
respective network boundaries. Claim/poll retries therefore survive relaunch and continue
automatically with bounded backoff; Settings also offers an explicit discard for abandoned or
terminal pending enrollment. The production identity vault
requires the Secure Enclave, commits both opaque key references and their metadata as one
device-only Keychain value, and exact-reloads that pair after a restart. It never exports a private
scalar and never silently falls back to software keys. First-create races return one exact winner;
the keyset is bound to device plus the signed authority digest—not to a short-lived bootstrap—so a
new bootstrap under the same authority proves continuity with the same keys. Device/authority
changes fail closed, key rotation is explicitly fenced, and revocation leaves a tombstone that
disables already loaded capabilities.

This is a physical-device claim boundary, not archive encryption or a biometric feature. It adds no
user-presence prompt and does not change Jazz Archive bytes. See
[`ADR 0004`](../docs/adr/0004-device-bound-enrollment-identity.md) for lifecycle and ownership
details.

**Disconnect** forgets both Keychain secrets (the remote Data Stream is left intact).
"Reconnect automatically on launch" re-verifies the stored token against its persisted stack each
start, so dedicated stacks work after restart and an expired token surfaces instead of failing
silently.

Also in Settings: the **review app URL** — your hosted Jazz review Data App (use a
placeholder like `https://your-review-app.example.com` until you have one). "Open Jazz…"
shows the native session list next to the embedded review app.

## Two session kinds

Every session carries an explicit **`session.kind`**, chosen when you start it and stamped onto
the data:

- **Process mapping** (`process-mapping`) — free-form "Start capture": you work normally and
  bracket what matters with ⌥⌘L labels.
- **BDM workshop** (`bdm-workshop`) — a *guided, narrated* recording driven by a floating panel
  (see below).

Both kinds appear in the **sessions sidebar** ("Open Jazz…") with their type tag ("Process
mapping" / "BDM workshop"); the hosted review app's sidebar shows the same tag.

## Labeling, review, evidence playback, and governed execution

- **Label what you're doing** while capturing — a label is a *bracketed segment* ("now I'm
  showing you how I do X" … "done"). Press **⌥⌘L** anywhere (or use the menu-bar item) and type
  the task ("Invoice approval for Acme") to **start** a label; ⌥⌘L again **ends** the open one
  (a new label auto-ends the previous; the session/quit ends it too). One label is active at a
  time. Each boundary is a `label_start`/`label_end` event and the active label name is stamped
  onto every event inside it — downstream, labels are authoritative activity boundaries. The
  **microphone records ONLY while a label is open** (gated by the "Record voice during labeled
  activities" toggle + Microphone permission); plain capture is mic-off.
- **Guided vs Explore labels.** When the session's **Area** (picked in the menu before Start)
  has an **Area registry** with declared processes — one JSON document per Area, a Storage File
  tagged `jasnost-area-registry` + `area:<id>`, written by the Data App — the agent fetches it
  in the background at Start and the ⌥⌘L panel switches to **Guided mode**: a picker over the
  Area's declared processes, with "Something else…" as the free-text fallback. A pick (or free
  text that unambiguously matches a declared name) stamps `process.id`/`process.name` onto every
  event in the segment (and its narration record), tying the recording to the declared process
  inventory. No Area, no registry, or a failed fetch → **Explore mode**: the classic free-text
  label, no process stamp — the fetch never blocks or breaks capture. Free text never mints a
  process id client-side; declared ids come only from the registry.
- The **sessions sidebar** ("Open Jazz…") lists canonical local archive revisions — start time,
  duration, kind, labels, event/artifact counts, review state, and archive-delivery state — without
  a network round-trip. Confirm, reject, correct, export, retry, cancel, and reconnect are explicit.
- A correction before first finalization is an append-only review assertion. A correction after
  finalization creates a new `archiveId`, increments `revision`, sets `supersedesArchiveId`, and
  links new CaptureCommits to the prior revision. It must be confirmed separately before delivery.
- **Evidence playback** is native and offline. It rebuilds the timeline from canonical records,
  explicit CaptureCommit gaps, and digest-verified archive-owned screenshot/audio/video artifacts;
  a missing or corrupt artifact blocks the load rather than showing a misleading partial replay.
  Technical capability transitions remain in the archive for diagnostics but do not appear as
  business-process steps. Content-addressed media has no filename extension, so playback supplies
  its contract-verified MIME type directly to AVFoundation.
  The separately named **Open server analysis** action is the only path from session detail into
  the hosted review canvas. Playback never executes recorded keystrokes or coordinates. Execution
  is available only from a reviewed, immutable RunbookVersion with explicit capabilities,
  preconditions, side-effect approval, and verification.

## Guided execution

**Guided execution…** is a separate native window; it is never entered from a raw capture or the
evidence-playback timeline. In production, the authenticated Jazz web app exports a version-2
launch packet for one exact enrolled target device. The packet contains the approved
RunbookVersion, ProcessExecution decision, and a short-lived opaque replay capability; it contains
no device credential. The macOS client derives the only permitted governance URL from its signed
archive-enrollment route (preserving the deployment prefix), requires the packet's device and
Company/Area pins to match that enrollment, and reads the current scoped token from Keychain at
each request. The token, exact device id, and capability are sent only as three request headers;
redirects, cookies, caches, credential storage, and oversized responses fail closed. A version-1
manual URL/credential remains an explicit local/development fallback only when no signed enrollment
exists.

Version 2 binds each packet to one exact server-authorized operator and enrolled Mac; the packet
operator must exactly match the local configured identity. A reviewed Alice → Bob process handoff
therefore gives Bob a new READY decision and a separate capability minted under Bob's authenticated
policy context. Alice's already issued packet cannot be transferred or reassigned by editing local
settings. The exact local identity check is a fail-closed consistency assertion, not Apple/MDM
attestation: signed enrollment proves continuity of the device credential, not which physical
person is at the keyboard.

The desktop admits the content-addressed decision losslessly, verifies the approved runbook pin,
the authorized operator, current app version, capabilities, preconditions, business-object pins,
and one unambiguous Accessibility locator. It then recovers that exact decision from the server and
compares the canonical bytes before persisting anything. If the authority expired before import,
the desktop sends only newly observed native runtime facts under the shared refresh contract; the
server re-resolves current connector-backed business-object anchors and atomically replaces only an
expired, unclaimed decision while the handoff itself is still live. An expired unclaimed handoff
requires a fresh export. PREPARE and CLAIM do not reveal the instruction. Immediately before
START, the client resolves the semantic target again. Only an exact server start receipt exposes
one instruction and a click-through highlight; the operator performs the action manually. The
client has no path that presses the AX element, injects keys, or falls back to recorded coordinates.

Completion is an explicit structured result. Required postconditions, observed side effects,
branch/handoff outcome, and evidence references are checked by the current server completion
resolver before its immutable receipt is appended locally. Stopping before START calls the
proof-bound server cancellation endpoint. Stopping after START never releases or retries the side
effect: the attempt stays durable and must be completed through receipt reconciliation or recorded
as unresolved. The raw 256-bit claim proof exists only in the permission-restricted active local
lifecycle journal (never in Jazz Archives, logs, UI, or server artifacts) so an uncertain CLAIM can
be retried exactly after relaunch; terminal transitions erase it before the attempt moves to
history. Decisions, claims, start/reconciliation responses, and receipts also survive relaunch
under the local `guided-execution/` journal.

## BDM workshop (guided narrated recording)

A **BDM workshop** is a focused recording for building a **Business Data Model** — what the
business tracks, in which systems, and how those things relate. Pick **"Start BDM workshop
session"** from the menu (offered only while idle) and a **floating panel** appears
(always-on-top, **non-activating** — it never steals focus, so you keep clicking through your
real apps while it stays in view).

- **Mic records from the start, screenshots are dense.** Unlike a process-mapping capture
  (mic-off until a label opens), a workshop **forces** the microphone on for the whole session
  and captures screenshots densely — the whole point is a narrated walk-through.
- **The panel walks scripted methodology questions.** It shows one question at a time from
  Keboola's BDM methodology (Steps 0–5: scope → systems & entities → define → relations &
  transactions → test → iterate; the question set lives in `BdmInterviewScript` in
  `JasnostCaptureCore`). The questions are **scripted, not AI-generated** — they guide the
  conversation; the adaptive model-building happens later in the review app.
- **Answer by speaking *and* showing.** Each question asks you to both narrate and open the real
  system (registry, CRM, …) and click through it.
- **One question = one bracketed-label segment.** Asking a question opens a label (named after
  the question, which turns the mic on); **"Next question"** closes that segment (its audio
  closes and persists as a label-bound canonical audio artifact, then opens the next. **"Finish"**
  (on the last question) or **"End
  workshop"** ends the session.
- **The model is built in the review app, not here.** The macOS panel is purely a guided
  recorder — it needs no network or login of its own. Afterwards, open the session in the hosted
  review app's **BDM workshop** tab and click **"Build BDM from recording"**: it replays each
  recorded segment, dredging the segment's audio (transcribed) + screenshots out of Keboola, and
  the LLM **adaptively merges** each one into the Business Data Model. See
  [Jazz processor documentation](https://github.com/keboola/jasnost/tree/main/apps/processor).

## Identity

Sessions are attributed to the email auto-detected from the scoped token (editable in Settings as
an override). The actor claim is stored in the archive and, in compatibility mode, projected as
`enduser.id` on OTLP records.

## Privacy

- **Denylist gate** — the whole desktop is captured during a session except apps on the
  excluded list (password managers pre-seeded, editable); consent is session-level Start/Stop.
- **Typed text is redacted** client-side before local persistence; secure text fields
  (`AXSecureTextField`) and secret-looking labels are never recorded at all.
- **Screenshots** are the focused window only, on click, and are sparse.
- **Secrets** (token, stream URL) live in the Keychain; they never appear on a command
  line, in logs, or in UserDefaults.
- **Archive files are not encrypted by Jazz.** This client assumes the managed Mac and its disk
  protection are the local security boundary; transport and server storage apply their own controls.

## Status

The core compiles and is unit-tested in CI (`swift build` + `swift test`). The live capture
path (TCC grants + a real session landing in Keboola) must be exercised interactively on a
Mac — it cannot be granted/verified headlessly.
