# Jazz macOS Capture Agent

A native macOS menu-bar agent that captures **desktop** work — clicks, app/window switches,
scrolls, clipboard actions, typed text (redacted), and spoken narration — with the
**semantic target** of each action (which button/field, in which app/window), and emits the
**`ActivityEvent` contract** the processor consumes. The agent is a
**self-sufficient collector**: it ships events as OTLP/JSON straight to your Keboola Data
Stream over HTTPS and uploads screenshots/audio directly to Keboola Files. No local bridge,
no kbagent, no Python services on the capture path.

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
| Narration | `AVAudioRecorder` | one think-aloud audio blob per session |
| Durability | on-disk event spool (`~/.jasnost/spool`) | events survive crashes/offline; sent batches journal locally |
| Transport | OTLP/JSON over HTTPS | `POST <stream>/v1/logs` + one `capture-session` span per session to `/v1/traces` |

Each raw interaction becomes an `ActivityEvent` (matching
`../contract/schema/activity-event.schema.json`): `eventType`, `system` = app name,
`url` = `app://<bundleID>`, `pageTitle` = window title,
`target.{role,accessibleName,text,boundingBox}` from the AX element, `isSensitive` for
secure fields. Events are appended to the durable spool first; a background sender drains
it FIFO and journals each batch only after the stream answered 2xx — so a crash or an
offline week loses nothing. Screenshots upload to Keboola Files (`files/prepare` + direct
object-store PUT) and events reference only the `screenshot_id`.

```
Sources/
├── JasnostCaptureCore/   # pure, testable (no TCC): event model, redaction, OTLP mapper, spool, ids
└── JasnostCapture/       # executable: menu-bar UI + capture (AX, EventTap, ScreenCapture,
                          # Narration) + KeboolaClient/StreamSender (direct HTTPS)
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
./build-release.sh --version v0.22.0      # or pin it explicitly
# distributable build (Developer ID certificate in your keychain):
JAZZ_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./build-release.sh --version v0.22.0
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
expiring device token, and the already-provisioned per-device OTLP endpoint. The agent:

1. validates the bundle's HTTPS Keboola stack and verifies the token there;
2. refuses a master token (ADR 0005: the desktop never holds one);
3. stores the scoped token + stream endpoint in the macOS **Keychain**.

The Data App provisions the source together with its logs/metrics/traces sinks. The desktop never
creates a source, avoiding a healthy-looking source that silently drops events when it has no sinks
(keboola/jasnost#198). The collapsed **Advanced: connect with existing credentials** fallback
accepts only a non-master token plus an admin-provisioned, sink-backed endpoint; it never creates
infrastructure.

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

## Labeling, sessions, replay

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
- The **sessions sidebar** ("Open Jazz…") lists sessions instantly from the local
  spool/journal — start time, duration, kind, labels, event counts, sent/pending — no
  network round-trip. "Open review" loads the session in the hosted review app.
- **Replay** re-runs a captured session's clicks/typing via Accessibility (explicit, paced,
  visible, interruptible).

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
  uploads tagged `label:<id>`) and opens the next. **"Finish"** (on the last question) or **"End
  workshop"** ends the session.
- **The model is built in the review app, not here.** The macOS panel is purely a guided
  recorder — it needs no network or login of its own. Afterwards, open the session in the hosted
  review app's **BDM workshop** tab and click **"Build BDM from recording"**: it replays each
  recorded segment, dredging the segment's audio (transcribed) + screenshots out of Keboola, and
  the LLM **adaptively merges** each one into the Business Data Model. See
  [Jazz processor documentation](https://github.com/keboola/jasnost/tree/main/apps/processor).

## Identity

Sessions are attributed to the email auto-detected from your token (editable in Settings as
an override) — it rides as `enduser.id` on every OTLP record.

## Privacy

- **Denylist gate** — the whole desktop is captured during a session except apps on the
  excluded list (password managers pre-seeded, editable); consent is session-level Start/Stop.
- **Typed text is redacted** client-side before upload; secure text fields
  (`AXSecureTextField`) and secret-looking labels are never recorded at all.
- **Screenshots** are the focused window only, on click, and are sparse.
- **Secrets** (token, stream URL) live in the Keychain; they never appear on a command
  line, in logs, or in UserDefaults.

## Status

The core compiles and is unit-tested in CI (`swift build` + `swift test`). The live capture
path (TCC grants + a real session landing in Keboola) must be exercised interactively on a
Mac — it cannot be granted/verified headlessly.
