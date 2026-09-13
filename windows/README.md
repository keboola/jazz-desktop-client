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

Jazz starts straight into the notification area; no window is shown. Quit any installed or previous
development copy from its tray menu before starting another build. A second launch while an
instance already owns the per-user singleton raises that instance's status window and exits
immediately, rather than leaving a second tray process running; the tray icon itself was already
there and needs no activating.

Capture is off on a fresh unmanaged profile. There are up to five ways to turn automatic capture
on, and they resolve through one precedence:

```
managed policy (#60)  >  installer preference (#60)  >  launch switch (#76)  >  user setting
```

with one rule that applies above every layer: **an explicit user pause suppresses automatic start
until the user resumes it**, regardless of which layer would otherwise turn it on — including a
managed policy that enforces capture on. An administrator can make Jazz start capturing on its
own; nobody can take away the user's own one-action Stop.

**Slice 1 of #60 has landed: the client reads both managed ranks from the registry, but nothing in
this repository writes them yet.** The per-user MSI property that will write the installer
preference is slice 2, tracked separately. Until then:

1. **The tray checkbox.** Enable **Start local capture automatically when Jazz opens** in
   **Settings**. This is the persisted user setting, the lowest-ranked layer.
2. **A preset `settings.json`** written before first launch — the recommended path for a
   deployment, since it survives every later launch regardless of how the process starts. See
   [Configure capture at launch without the tray UI](#configure-capture-at-launch-without-the-tray-ui)
   below for the exact document and its one sharp edge.
3. **The `--capture-at-launch` launch switch**, for a shortcut you create yourself (the MSI's own
   Start Menu shortcut and `Run` value carry no switch — see below), a scheduled task, a login
   script, or manual testing.
4. **An installer preference**, `HKCU\Software\Keboola\Jazz\Policy\CaptureAtLaunch`. Nothing in
   this repository writes it yet (that is slice 2), but any user-context deployment script can
   write it today, and the client already honours it. See
   [Managed capture-at-launch policy](#managed-capture-at-launch-policy) below.
5. **A managed policy**, `HKLM\Software\Policies\Keboola\Jazz\CaptureAtLaunch`, deployed by an
   administrator through Intune settings catalog / ADMX ingestion, GPO, or a device-context script.
   Same section below.

Choosing **Stop capture** commits the active journal and pauses whichever layer is currently
turning capture on, managed policy included; choose **Start capture** later to resume it. A
provisioned device bundle, delivery credentials, and the Windows login registration do not
themselves enable capture. The tray's **Status and onboarding...** item opens the status window on
demand, and its text reports which of the effective states is in effect: not configured to start
automatically, starting at launch, paused by a prior stop, or — a managed value that could not be
read — not starting automatically due to a misconfiguration, with a plain-language reason and no
instruction to touch a Settings checkbox that is disabled. All four reflect the effective value
across every layer, not only the tray checkbox.

A process launched with no switch and no ticked checkbox can still read an existing pause, but it
cannot tell *why* it is there — whether a switch on a different shortcut recorded it. A plain Stop
right after a plain Start from such a process still re-records the pause the Start resumed, so an
ordinary Start-then-Stop round trip does not erase it. Quitting instead of stopping is different,
and is not covered the same way: the Start already cleared the pause to let capture run, and
quitting without stopping first does not re-record it, so a Start followed by Quit leaves the
profile unpaused — the same outcome an explicit "Start capture" from the tray has always produced,
not a new gap. This is another reason the preset `settings.json` (below) is the recommended path
for anything login-critical: a single document every process reads the same way has no
per-process blind spot at all.

Runtime state is kept outside the build tree:

| Path | Purpose |
| --- | --- |
| `%LOCALAPPDATA%\Jazz\settings.json` | persisted tray preferences; also the supported preset-configuration path |
| `%LOCALAPPDATA%\Jazz\captures` | capture journals and local archives |
| `%LOCALAPPDATA%\Jazz\queue` | confirmed archives awaiting delivery |
| `%LOCALAPPDATA%\Jazz\App` | files owned by an MSI installation |
| `%LOCALAPPDATA%\Jazz\staging\screenshots` | screenshot bytes staged for background upload to Keboola Files — **not durable**, wiped at every process launch |
| `%LOCALAPPDATA%\Jazz\spool\events` | OTLP event bodies awaiting delivery — **durable**, survives restart, bounded by size and age |
| `%LOCALAPPDATA%\Jazz\spool\narration` | narration clip blob+sidecar pairs awaiting upload to Keboola Files — **durable**, survives restart, bounded by size and age (issue #84) |
| `HKCU\Software\Keboola\Jazz\Policy\CaptureAtLaunch` | installer preference (#60) — read-only to this client; provenance and precedence over the user setting, not tamper-resistance |
| `HKLM\Software\Policies\Keboola\Jazz\CaptureAtLaunch` | managed policy (#60) — read-only to this client; the only genuinely enforced rank, since a standard user cannot write under `HKLM\Software\Policies` |

The installer deliberately leaves settings, captures, the queue, the event spool and the narration
spool in place when it is removed. Use a separate Windows account or VM when a test needs a
completely fresh profile. The staging directory is the one exception to that durability guarantee:
unlike every other row above (including both spools), it is cleared on every launch, not only on
uninstall, so nothing there is expected to survive even a normal restart of Jazz. See
[Screenshot delivery](#screenshot-delivery), [Event delivery](#event-delivery) and
[Narration delivery](#narration-delivery) below.

## Configure capture at launch without the tray UI

A deployment can turn capture-at-launch on before anyone ever opens the tray, by either of two
supported paths. Both feed the same `CaptureStartupGate` evaluation the tray checkbox does, and an
explicit user pause still beats both — see the precedence table above.

**The preset `settings.json` path.** Place the settings document at
`%LOCALAPPDATA%\Jazz\settings.json` after install and before first launch — an MSI install creates
`%LOCALAPPDATA%\Jazz` as `INSTALLFOLDER`'s parent but never writes a file into it, so this is safe
to do immediately afterward. Loading never writes, so a preset placed before first launch is read
as-is, not overwritten by a defaults save. The canonical document, in the exact key order this
client writes:

```json
{"captureAtLaunchEnabled":true,"captureAtLaunchPaused":false,"excludedApplications":["1password","bitwarden","consent.exe","credentialuibroker","dashlane","keepass","lastpass","logonui.exe"],"highlightClicks":false,"narrationEnabled":false,"schemaVersion":1,"screenshotsEnabled":true}
```

**The sharp edge:** three keys are mandatory — `schemaVersion` (must be `1`), `excludedApplications`
(an array of strings), and `highlightClicks` (a boolean). A minimal `{"captureAtLaunchEnabled":true}`
is *not* a valid document: it fails to parse, the client falls back to the seeded defaults, and
**capture stays off**, with an unreadable-file notice the settings window shows but nobody on an
unattended machine is there to read. Always write the full canonical document above, not a
single-key fragment.

Two more things worth knowing: a preset applied *after* first launch is picked up on the next
launch, but can be overwritten by a tray-driven save in the meantime, since every save serializes
the whole document from memory; and the document carries no secret — it is a boolean preference
file, never a token, endpoint, or bundle (#62 constraint 2).

**The `--capture-at-launch` launch switch**, on `JazzCapture.exe`. Exactly this spelling, matched
case-insensitively, with no value form and no alias (`/capture-at-launch` and
`--capture-at-launch=1` are not recognised). It enables capture for that process only and is
**never written to `settings.json`** — folding it into the persisted user setting would make it
indistinguishable from a user's own choice and would make #60's policy-removal semantics
impossible to define, so it always stays a layer above the persisted preference, never inside it.
An unrecognised argument — a typo, an unrelated flag — is ignored rather than treated as fatal;
this process is launched by Explorer, a shortcut, the `HKCU` `Run` value, and by hand, and a stray
argument must never turn into a total capture outage.

**A launch switch only ever affects the process that owns the per-user singleton.** If another
Jazz Capture instance is already running, this process loses the single-instance race before the
switch is ever read, sends the single word `Activate` through the existing activation pipe, raises
the running instance's status window, and exits — capture is completely unaffected. This is
intentional: the activation channel has exactly one verb and stays that way (see
`windows/Sources/JazzCapture/UserActivation.cs`), so a launch switch cannot be used to remote-start
capture on an already-running client.

**The switch is not a reliable way to enable capture at login on an MSI-installed machine.** The
installed MSI's own `HKCU` `Run` value launches `JazzCapture.exe` with **no arguments**
(`installer/Package.wxs`; unchanged by this issue — see #60), and Windows does not guarantee
ordering between that entry and a separately-added login script, scheduled task, or shortcut that
does carry the switch. Whichever process wins the per-user singleton race owns capture for that
login; if it is the argument-less Run entry, the switch on the other one is a complete no-op for
that session, silently. **Use the preset `settings.json` document for login-time enablement** —
it has no such race, since every launch reads the same file regardless of which shortcut started
it — and reserve the launch switch for a shortcut, a scheduled task run on demand, qualification,
or manual testing, where you control exactly which process starts and when.

The MSI property and Intune packaging that would let an administrator set these without touching a
shortcut, a scheduled task or a login script at all are **not** part of this section — see
[Managed capture-at-launch policy](#managed-capture-at-launch-policy) below, and note that slice 2
(the MSI property itself) is still tracked separately (issue #60).

## Managed capture-at-launch policy

Slice 1 of #60 (this client's read side). The client reads two registry locations at launch,
immediately beside the #76 launch switch, and ranks both above it and above the user's own tray
setting:

| Rank | Location | Written by | Real guarantee |
| --- | --- | --- | --- |
| Managed policy | `HKLM\Software\Policies\Keboola\Jazz`, value `CaptureAtLaunch` | Never by this client. An administrator, through Intune settings catalog / ADMX ingestion, GPO, or a device-context script. | Genuinely enforced. A standard user cannot write `HKLM\Software\Policies`. |
| Installer preference | `HKCU\Software\Keboola\Jazz\Policy`, value `CaptureAtLaunch` | The per-user MSI (slice 2, not yet built) or any user-context deployment script. Never by this client. | Provenance and precedence over the user's own setting, not tamper-resistance: the client never writes it, but a user with `regedit` can. |

Both keys accept a `REG_DWORD` or a `REG_SZ` value — Intune's settings catalog and ADMX ingestion
both write DWORDs, while the MSI's `[JAZZ_CAPTURE_AT_LAUNCH]` property formatting (slice 2) can
only ever produce a string. Only the 64-bit registry view is read (this payload is `win-x64`), so a
value written by a 32-bit tool into `WOW6432Node` is not seen.

**`1` enforces capture on. `0` and an absent value both mean "no opinion" and fall through to the
next rank — at both locations.** An administrator cannot enforce "off" through either channel:
deploying `0`, or removing a previously deployed value, are the same thing, and both simply hand
the decision back to the layer below (ultimately, the user's own tray checkbox). This is a
deliberate product decision, not an oversight: a policy can only ever turn capture *on*, never
force it off against the person using the machine.

**Any other value is a misconfiguration, and the only thing that ever forces capture off at either
rank.** Since neither rank can enforce "off" as a decision, a value that is not exactly `1` or `0`
(after trimming whitespace — no `"true"`, no `"yes"`, no partial match) is the sole path that stops
automatic capture from a managed source. In that state:

- **Settings** shows the checkbox disabled with: *"A setting deployed to this machine could not be
  read, so this cannot be changed here."*
- **Status and onboarding...** shows: *"Jazz Capture is not starting capture on its own"* — *"A
  setting deployed to this machine could not be read, so Jazz Capture is not starting capture
  automatically. You can still start a capture yourself from the notification-area menu. If this
  is unexpected, ask whoever manages this machine to check it."*

Neither message says the organisation decided this (it did not; a value failed to parse), neither
sends the user to a Settings checkbox that is disabled, and neither ever contains the value that
failed to parse.

**A genuinely enforced value renders as enforced, not as an ordinary toggle.** When either rank
decides `1`, the Settings checkbox shows ticked and disabled, with: *"This is set by your
organisation's policy and cannot be changed here."* Saving any other preference in that state never
writes the policy's value into the user's own persisted `captureAtLaunchEnabled` — the checkbox's
disabled, policy-mirroring display is never fed back into `settings.json`, so the user's own
preference underneath the policy survives intact and resurfaces unchanged the moment the policy is
later removed.

**A pause still beats a managed policy.** The cross-cutting rule above the precedence table applies
here exactly as it does to every other layer: choosing **Stop capture** on a policy-enforced machine
still pauses automatic start until the user chooses **Start capture** again, even at the next login.
An administrator will reasonably expect an enforced policy to mean the machine always starts
recording; a user who has explicitly stopped it will see it stay idle until they explicitly start it
again. This is correct and deliberate (#53 scope 6), not a bug to file against the policy.

**The policy is read once per process, immediately beside the launch switch.** A policy change —
deploying, updating, or removing a value — takes effect at the next launch, the same as every other
input this client reads once at startup. A registry read failure (an access-denied key, for
instance) is treated as absent for that rank rather than a startup failure: a policy read must never
become a capture outage.

**A managed policy governs capture *at launch* only.** A manual "Start capture" from the tray is
never gated on a policy value; nothing here changes what a person sitting at the machine can do by
hand.

**Reading `HKLM` here is a client-side registry read, not an installer write.** The per-user
constraint this client enforces (`Verify-Msi.ps1:274`, `:279`, `:305`) is about what the *installer*
writes to the machine, not about what the running client reads from it. Nothing in this repository
writes to `HKLM` — the managed-policy value is deployed and owned entirely by whoever manages the
machine.

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

## Qualify an unsigned MVP device bundle

This narrow development path accepts only the `enrollmentProfile: "mvp"` document emitted by
`windows/Tools/make-device-bundle.py --profile mvp`. It is not an Intune workflow and it does not
enable signed enrollment or archive delivery. It **does** provision prepare-early screenshot
delivery to Keboola Files: that delivery routes on the bundle's Storage token and stack URL alone,
independent of the OTLP stream endpoint, so a validated MVP bundle enables real Files uploads for
any screenshot captured afterward — screenshots are on by default. See
[Screenshot delivery](#screenshot-delivery) below before running this procedure.

Before touching Windows, an operator with the protected values verifies the endpoint with an
empty OTLP body (`POST <stream-endpoint>/v1/logs`, `Content-Type: application/json`, body
`{"resourceLogs":[]}`) and verifies the non-master token with `GET
<stack>/v2/storage/tokens/verify` and `X-StorageApi-Token`. Keep both values in the approved
secret tool rather than shell history or command-line arguments.

On a fresh disposable Windows profile, create `%LOCALAPPDATA%\Jazz\provisioning` and copy the
bundle through an approved secret channel to `device-bundle.json`; restrict that directory and
file to the current Windows user before starting Jazz. Never put its token or stream endpoint in a
command line, transcript, issue, or log. If an ACL-protected file cannot be supplied, use the tray's
**Provision device bundle...** command and paste the JSON directly from the approved secret tool.
For a file already delivered by that channel, run this path-only ACL step (it neither reads nor
prints the bundle):

```powershell
$bundlePath = Join-Path $env:LOCALAPPDATA 'Jazz\provisioning\device-bundle.json'
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = New-Object Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($currentUser, 'FullControl', 'Allow')))
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('SYSTEM', 'FullControl', 'Allow')))
Set-Acl -LiteralPath $bundlePath -AclObject $acl
```

The preflight values must likewise be read by the approved secret tool into process memory and
sent with its redacted UI/API facility; do not use `curl`, shell variables, exception output, or
verbose tracing for either credential.
The tray must say that
provisioning is active before a capture is started. It refuses a missing/wrong MVP marker, master
token, token-id or expiry mismatch, and expired credential without stopping local capture.

Start a short capture and inspect the tray: `Streaming: sending N` falling to `up to date` confirms
successful OTLP POSTs; `retrying N` (endpoint unreachable, or a 401/403 parking delivery -- see
"Event delivery" below) is safe and local journaling continues either way. The sender posts
canonical OTLP-mapped events to the configured capability URL plus `/v1/logs`, with no authorization
header. Do not attempt this procedure until the operator supplies a non-master test token and
endpoint, and do not record either value in qualification evidence.

Real Azure VM evidence now exists: the maintainer has confirmed this procedure was run on the
designated disposable VM with protected test inputs -- the same qualification run recorded under
[Screenshot delivery](#screenshot-delivery) below, where a real screenshot reached Keboola Files
and its event row carried the matching `screenshot_id`. That event row is itself a successful
`logs` table result, since it only exists because the sender posted it to the configured
endpoint. The sanitized evidence for that run is held with issue
[#73](https://github.com/keboola/jazz-desktop-client/issues/73) rather than in this repository, for
the same reason given there: it is produced from protected test inputs. It proves exactly that
screenshot round trip and its matching event row, and nothing more about this endpoint beyond
that.

A change to an emitted event or its OTLP mapping must update the schema, golden fixtures, Swift
runner, and processor mirror together. CI runs the Swift build and tests on macOS for every PR.

## Delivery architecture

Windows delivers captured activity, screenshots, and (issue #84) narration audio through the legacy
path only: Data Stream OTLP for events (`MvpStreamSender.cs`, drained from the durable `EventSpool`)
and the Keboola Files API for both screenshots (`KeboolaFilesClient.cs`) and narration clips (the
same client, kind-aware since issue #84). All three run live, independent of any archive-level
confirmation, as soon as a device credential is provisioned — there is no `liveCompatibility` switch
anywhere in `windows/Sources/`. Local-first capture is unaffected: the client still journals
canonically and still writes local Jazz Archives.

Confirmed whole-archive delivery, the desktop default described in
[ADR 0003](../docs/adr/0003-confirmed-archive-delivery.md), is declined for Windows per
[issue #62](https://github.com/keboola/jazz-desktop-client/issues/62) (closed as
[#46](https://github.com/keboola/jazz-desktop-client/issues/46)): every route it depends on is
registered only on an undeployed gateway in `keboola/jazz`, while the legacy path is what actually
produces timelines, L4, and BPMN today. `Sources/JazzCaptureCore/Delivery`'s queue, coordinator, and
retry policy stay in the tree with only a test fake behind `IArchiveDeliveryTransport` and nothing
draining them — issue #48's durable event spool is a wholly separate, new component
(`windows/Sources/JazzCapture/EventSpool.cs`) and has no diff against, and no interaction with,
`Sources/JazzCaptureCore/Delivery`. #62's revisit condition is explicit: revisit if the native
gateway is deployed.

This is an accepted exception to the documented delivery architecture, not a gap to close — read
[ADR 0003 § Windows](../docs/adr/0003-confirmed-archive-delivery.md#windows) before proposing to
"finish" the archive transport or add a `liveCompatibility` gate here. See
[Screenshot delivery](#screenshot-delivery) below for what this means concretely for screenshots.

## Screenshot delivery

Prepare-early screenshot delivery uploads captured screenshots to Keboola Files under an accepted
eventual-inconsistency design (issue #73). On the capture path, `POST /v2/storage/files/prepare`
runs under a bounded budget; on success the returned Files id is stamped on the event as
`screenshot_id` and the bytes are staged for a background uploader, while a prepare failure,
budget expiry, or an expired Storage credential emits the event with no `screenshot_id` and stages
nothing — the capture path never retries a prepare. The background uploader makes a bounded,
jittered-backoff, single-shot PUT to GCS per attempt; on terminal failure it drops the staged blob
and leaves the Files id dangling on an event that has already gone out. A dangling `screenshot_id`
is expected and tolerated, not a bug: the Jazz processor already drops a failed screenshot download
and continues.

**Accepted limitation: an unreachable endpoint has a real, unbounded-in-aggregate cost on the
capture path.** `ScreenshotDeliveryPreparer.Prepare` runs synchronously, inside the capture
engine's own lock, and `CaptureCoordinator` drains every observation through one reader over an
*unbounded* channel. Against an unreachable Files endpoint, each screenshot-bearing observation can
therefore cost up to `PrepareBudget + PrepareWaitGrace` on that path before the reader moves on to
the next queued item, and repeated screenshots (e.g. rapid clicks) queue up behind one another and
make later, non-screenshot events wait too. The per-screenshot cost is bounded by configuration,
but the aggregate cost across a burst is not, because the bound applies per screenshot while the
channel has no depth limit. Canonical capture is not at risk either way: `CaptureEngine.Append`
journals the observation durably before the preparer ever runs, so a slow or unreachable endpoint
cannot affect what the archive records — only the latency of the live projection and the depth of
the in-memory queue degrade. A circuit breaker (skipping prepares for a cooldown after repeated
failures) was considered and deliberately not added; this is recorded here as an accepted
trade-off rather than built around, so it does not need rediscovering.

A retryable upload failure re-arms itself: `ScreenshotDeliveryWorker.DrainOnceAsync` reports back
how long until the earliest staged entry is next due, and `DeliveryDrainScheduler` sleeps for
exactly that long before draining again, so a retry runs on schedule even if nothing else ever
stages another screenshot or calls `Nudge()` in the meantime. A restored credential (after an
outage or a fresh device bundle) also nudges the scheduler directly, so anything staged while
delivery was unusable retries promptly instead of waiting on the next screenshot. There is no
polling timer anywhere in this path — issue #73 forbids one — so an expired Storage credential is
instead re-checked at the point of use, on every prepare and every tray status refresh, against the
expiry captured when the credential was last read.

The tray's `Screenshots:` line reports this independently of `Streaming:`: `not provisioned` (no
usable Storage credential), `up to date`, `uploading N` / `retrying N` while screenshots are staged,
and `N undelivered` once at least one upload has been terminally abandoned. The undelivered count is
sticky — it stays visible even after the queue drains back to empty, because `up to date` would
otherwise misreport a degraded outcome as a clean one.

Every operational bound — the prepare budget, upload attempt count and backoff, the GCS call
budget, and the staging directory's size and age limits — lives in `Settings.ScreenshotDelivery`
(`ScreenshotDeliverySettings.cs`). These are compiled-in operational defaults, not user
preferences: they never round-trip through `settings.json` or the settings window, and an invalid
value fails startup rather than surfacing at the first screenshot.

Live qualification of this path has been performed and confirmed by the maintainer: a real
screenshot reached Keboola Files and its event row carried the matching `screenshot_id`. The
sanitized evidence for that run is held with issue
[#73](https://github.com/keboola/jazz-desktop-client/issues/73) rather than in this repository,
because it is produced from protected test inputs. What that run proves is exactly the round trip
above and nothing more: it is not evidence about throughput, about the retry and eviction paths, or
about any behaviour on a profile other than the one it ran on.

## Event delivery

Issue #48 replaces the non-durable, drop-under-pressure `MvpStreamDispatcher` with a durable,
bounded, on-disk spool for OTLP event bodies, and a drain worker/scheduler pair modelled on
[screenshot delivery](#screenshot-delivery)'s.

**Layout and why the digest is in the filename.** One file per event under
`%LOCALAPPDATA%\Jazz\spool\events\<sessionId>\<sequence:D10>[-<collision>].<64 lowercase hex
sha256>.otlp.json`. The file *is* the exact `/v1/logs` request body — no sidecar, no record
document — because issue #48's acceptance is "exact bytes survive retry/restart" and its non-goals
list "rebuilding bytes on retry" explicitly. The SHA-256 is embedded in the name so exact-byte
integrity is verifiable *after a restart*, with no in-memory record to check against, the same idea
as the journal's own content-addressed blob layout. Zero-padding the per-session sequence to 10
digits makes ordinal file-name order equal numeric order.

**At-least-once, per-session FIFO.** One outcome removes an entry as *delivered*: a **2xx**. A crash
between the 2xx and the delete replays that one event. Four remove it *undelivered*, and each is
counted into the `N undelivered` tally rather than discarded quietly — a terminal **400 or 422**, a
failed **length or digest verification** when the bytes are read back, **eviction** at either bound
below, and a **refusal** at admission. None of the four is ever retried or replayed. The duplicate is deterministic (`eventId` is
`sessionId + "-" + sequence`, projected onto both rows), so the two rows are byte-identical and
joinable — **and the Jazz processor does not de-duplicate on `eventId`** (`apps/processor/src/jasnost_processor/sessions.py`'s
timeline query has no `DISTINCT` and does not group on `event_id`), so a crash-during-send produces
a visible duplicate row in a session's timeline. This is accepted: it is strictly better than the
silent total loss it replaces, and downstream de-duplication on `eventId` is trivial to add later.
The spool itself withholds a session's later entries whenever that session's own earliest surviving
entry is not yet due (backing off from a previous failure), and the drain worker additionally stops
attempting a session's remaining entries within one pass the moment one of them comes back
retryable — together, a later event is never delivered ahead of an earlier one of the same session
still being retried, across drain passes and not merely within one. The sink batches
server side, so this client POSTs exactly one observation per request — #62's confirmed decision,
not an oversight; an offline hour produces an hour's worth of individual POSTs on reconnection,
paced only by the sequential drain.

**Classification, mirroring `KeboolaFilesClient`'s shipped rule:** 2xx acknowledges (delete); 400
and 422 are terminal (the body is the problem, delete and count abandoned); 401 and 403 are not the
body's fault either, but **park delivery rather than retrying it** — a deliberate correction made
during this PR's review to the plan's original §2.5 table, which classified them as an ordinary
retry. Issue #48's own acceptance criterion is "revocation/expiry stops networking without deleting
evidence" (in force per the plan's §1.6), and retrying a revoked capability URL every few minutes for
up to 48 hours is still networking, not stopping. The spooled entry is left exactly as untouched as
any other retry — nothing is deleted or evicted differently, and the retention bound is still the
only backstop — but the delivery worker stops attempting any further send through itself once this
happens, and only resumes once `App.RefreshDeliveryTarget` (the existing seam that already reacts to
a real provisioning change) replaces it with a fresh one. Everything else — 3xx (structurally
unreachable since the transport never follows a redirect, but still not the body's fault), 408/429/
5xx, a transport exception, or the send call budget elapsing — is an ordinary retry.

**No attempt budget, deliberately.** Unlike a screenshot, an event is not a decoration on the
record; it *is* the record downstream, so a retryable send failure retries indefinitely rather than
being dropped after a fixed number of attempts. The entry leaves the spool only by succeeding, by a
terminal classification, or by one of the two bounds below.

**Two bounds, and every eviction or refusal is counted.** `SpoolByteCeiling` (32 MiB) and
`SpoolRetention` (48 hours) — amended down from an earlier 128 MiB / 7 days proposal for a small,
bounded on-disk footprint on every deployed machine. **The practical consequence, stated plainly:** a
machine that records while unprovisioned — the ordinary case #53 scope 4 describes, where capture
starts before a device bundle ever arrives — begins discarding its **oldest** spooled activity once
either bound is exceeded, well before a week has passed; a bundle that arrives on a Monday for a
machine recording, unprovisioned, since the previous Friday will not recover everything from that
Friday. Eviction is oldest-first, so a permanently dead endpoint does not freeze the spool on its
first ceiling forever. Both an eviction and an admission refusal are counted into the tray's sticky
tally — unlike screenshot delivery, where a refusal is *not* counted, because a refused event is
exactly the silent loss this issue exists to make visible, whereas a refused screenshot merely
leaves a dangling `screenshot_id` the processor already tolerates.

**Tray states**, on the same `Streaming:` line that used to render `"backpressure; events dropped"`:
`not provisioned`, `up to date`, `sending N`, `retrying N`, `N undelivered` (sticky for the life of
the process, surviving the spool draining back to empty), and `spool unavailable; events not
delivered` (the spool itself could not be constructed — deliberately distinguishable, unlike the
identical screenshot staging failure mode, because a null event spool means events are produced and
discarded). None of these carries the tray's `!` error prefix: a missing credential or a bounded
eviction is policy, not a fault (#53 scope 5). **`N undelivered` outranks `not provisioned`, not the
other way round:** unlike screenshot delivery, where nothing is ever staged without a credential, an
unprovisioned machine is the *ordinary* case the amended bounds above are sized for, and the spool
evicts and refuses on the capture path the whole time regardless of provisioning. If the abandoned
tally were hidden behind `not provisioned`, exactly as the screenshot precedent does, a
never-provisioned machine could never render `N undelivered` at all.

**Shutdown does not drain the spool.** Every spooled event's bytes are already durable by the time
the capture path's write returned, so there is nothing to flush at exit — shutdown is strictly
faster than before this change.

Every operational bound lives in `Settings.EventDelivery` (`EventDeliverySettings.cs`), compiled-in
exactly like `Settings.ScreenshotDelivery`: never a user preference, never round-tripped through
`settings.json`, and validated once at startup.

**The event spool now has a second producer (issue #84).** `App.SendCapturedEventAsync` still
spools every non-narration event on the capture path, but `NarrationDeliveryWorker` also spools a
narration event — once its clip's upload has resolved, successfully or terminally — from its own
background task, through the same `EventSpool.Spool` and the same shared `App.TrySpoolEvent` helper.
`EventSpool`'s coarse lock already made this safe before this second caller existed; nothing about
`Spool`'s own body changed. See [Narration delivery](#narration-delivery) below.

## Narration delivery

Issue #84 closes the second half of #48: narration audio never reached Keboola Files, because
`CaptureEngine` gated artifact delivery on `attachment.Kind == "screenshot"`, so every narration row
this client ever emitted carried the **archive artifact id** in `audio_file_id` — a column a reader
takes for a Files id — rather than one, or an empty value. This is a wrong-value fix, not a mapping
change: `OtlpMapper.cs` and `Otlp.cs` are not modified.

**The ordering is inverted from screenshot delivery, and inverted on purpose.** A screenshot event
is emitted immediately, with a Files id stamped on success or nothing at all on failure — the bytes
upload afterward. A narration event cannot mean anything before its upload resolves: it carries no
`eventId`/`sequence` on the wire (`OtlpMapper.NarrationAttributes` is a *total replacement* of 13
keys, not an addition), so the wire's only content-bearing signal is `audio_file_id` itself. So the
host takes durable custody of the clip and the projected event at capture time
(`EngineConfig.NarrationDeliveryHandler`, the deliberate inverse of `ScreenshotDeliveryPreparer`),
and the engine withholds the event from the ordinary observer until an upload resolves. The engine
never drops an event nobody took: a declined or failed custody attempt, or no handler configured at
all, still emits the event immediately, with `AudioFileId` null.

**One further, accepted crash window, disclosed rather than left implicit.** The narration record is
committed to the journal (`CaptureEngine.Append`'s `ResolveObservation` call) *before* the handler
that takes custody of the clip ever runs — the same ordering, and the same reasoning, `SendCapturedEventAsync`
already has for every other event: the archive is capture truth and must never depend on the outcome
of a live delivery step. A crash in the narrow window between that commit and custody being taken
means no sidecar (and therefore no spool entry) is ever created for that one clip — the archive
still has the label, the journal still has the audio bytes, but no narration row is ever emitted for
it, and nothing at the next launch retries taking custody after the fact, because the in-memory
`ActivityEvent` needed to do so no longer exists. This is the identical class of loss the durable
event spool (issue #48) already documents and accepts for an ordinary event's own one-write-wide
window before it is ever spooled — narration's window is not qualitatively different, only wider in
absolute time, since custody-taking's own write can be tens of megabytes rather than a few kilobytes.
Closing it would mean making the journal commit and the spool write one atomic operation across two
independent durability subsystems, which is a materially larger change than this issue's own scope.

**Two further crash windows, found in round 3 review and disclosed rather than fixed.** First,
`NarrationDeliveryWorker.TerminalDrop` spools the amendment-2 row (`AudioFileId` null) *before*
calling `NarrationSpool.Remove` — required, so a crash cannot land between removing the pair and
emitting the row (see amendment 2's own section above). But nothing durably marks that the row was
already spooled: if the process crashes in the narrow window after `_trySpoolEvent` succeeds and
before `Remove` runs, the pair is still on disk, unstamped, and is adopted again at the next launch
exactly as if nothing had happened. A second attempt that also fails terminally re-emits an
identical duplicate row (the same accepted, bounded class of loss `EventSpool` already tolerates for
its own single-write-wide window); a second attempt that *succeeds* this time is worse — it emits a
**second** row with a real Files id for a clip already reported undelivered, which is exactly the
"two different values for one clip, unreconcilable downstream" case R4 of the plan's risks exists to
prevent, just reached from the opposite direction. Closing it needs a durable marker for "this row
was already emitted, do not re-attempt" distinct from `TryStampFilesId`'s "this upload already
succeeded" marker — a new persisted field on the sidecar, parsed and validated everywhere
`PendingNarration` already is — which is a larger change than a value fix. Second, `Stage`'s own
rollback on a refusal (every `return Refuse(key)` after the pair has already been written to disk)
best-effort-deletes both files but does not guarantee it: if the delete of either one fails (a
transient ACL or locking issue) and the process then crashes or restarts before the deferred
`_deletionDebt` retry ever succeeds, the leftover pair is indistinguishable from an ordinary staged
one and is silently adopted at the next launch — a refusal that briefly stops being one. This is not
new to round 3's own fix; every refusal path in `Stage` has always had this same shape. Both are
narrow (they need a crash inside an already-narrow window, on top of either a network failure or a
file-system failure) and are left disclosed here rather than fixed in this issue.

**The pair, and why the sidecar exists.** One narration clip is a blob-plus-sidecar pair under
`%LOCALAPPDATA%\Jazz\spool\narration\<sessionId>\<sequence:D10>[-<collision>].<64 lowercase hex
sha256>.narration.audio` / `....narration.json`. The blob alone is not enough: the sidecar carries
everything needed to rebuild the event and its `SessionContext` once a Files id exists, including
the session's `traceId`/`spanId` — minted fresh in memory per capture and persisted nowhere else in
this process. The blob is written first, durably; the sidecar, written second and atomically, is the
commit marker, mirroring the journal's own "bytes before the record that cites them" rule. A blob
with no sidecar, a sidecar with no blob, and an unparsable sidecar are all swept at the next launch
and counted, not silently discarded.

**The durable `filesId` stamp, and the dangling-allocation rule.** Once an upload succeeds,
`NarrationSpool.TryStampFilesId` rewrites the sidecar atomically with the real Files id — never the
blob — before anything else. This is the upload's actual commit point: a crash before the event is
finally spooled re-enters directly at that step on the next launch, so at most one duplicate row is
possible, never a second upload or a second id. Unlike screenshot delivery, which never deletes a
Files allocation because the event carrying its id has always already been emitted, narration
**must** delete a dangling allocation on both a retryable and a terminal upload failure, because the
event has not gone out yet and an allocation whose PUT failed references nothing at all — the same
fix macOS's own uploader records shipping ("delete the dangling file id we just minted so retries
never pile up empty records").

**No attempt budget**, for the identical reason the event spool has none: a narration clip is not a
decoration on the record, it *is* the record, so a retryable failure retries indefinitely rather
than being dropped.

**The two bounds, and the accepted consequence, in plain words.** `MaximumClipBytes` (64 MiB) admits
a real maximal (30-minute, 16 kHz mono PCM) sealed clip — 54.93 MiB — with headroom. `SpoolByteCeiling`
(512 MiB, roughly nine maximal clips) and `SpoolRetention` (48 hours, deliberately equal to the
*event* spool's own window — a narration row, once emitted, immediately falls under that window too,
so holding a clip longer would eventually describe a label whose surrounding activity had already
aged out) bound the whole spool, oldest first among what is actually evictable. A machine that
records narration while unprovisioned — the ordinary case #53 scope 4 describes — begins discarding
its **oldest evictable** clips once either bound is exceeded, and a discarded clip means **no
narration row is ever emitted for that label**: unlike an evicted event, the audio itself, not merely
its delivery, is gone. A clip whose Files id is already stamped is never one of these (round 2
review finding, R5): it has already been uploaded, only its own row still needs to reach the event
spool at zero further cost, so evicting it would permanently orphan a Files object rather than
merely lose an undelivered one. If every remaining candidate is stamped, a *new* admission that needs
the room is refused instead — a visible, counted loss, rather than the alternative of silently
orphaning an already-uploaded clip to make room for it. Every eviction, refusal, or terminal drop is
counted into the tray's sticky `N undelivered` tally so this is visible rather than silent.

**Terminal upload failure still emits the row — deliberately, and this reverses the plan's original
position.** A 400 from prepare or the PUT, or staged bytes that no longer match the sidecar's own
length or digest, are the only terminal causes (an unparsable sidecar found at adoption is a fourth,
but it can build no row at all). On any of the first three, the pair is removed **and** the row is
still spooled, built and sent *before* the pair is removed, with `AudioFileId` null — which
`OtlpMapper` projects as `""`. On the wire, the column now has exactly two meanings and never a
third: **a valid Files id means the audio is in Files; an empty value means audio was recorded and
could not be delivered.** It is never a wrong id pointing at something that is not a Files object —
the defect this issue exists to close. The audio itself is not lost either way: it remains in the
local archive and the journal: only the spooled clip and its sidecar are removed.

**Rows already emitted before this fix** carry the archive artifact id and cannot be repaired from
this client; whether the Jazz processor should treat an `audio_file_id` that does not resolve in
Files as absent is a `keboola/jazz` question, out of scope here.

**The tray's `Narration:` line hides itself when it has nothing to say** — unlike `Streaming:` and
`Screenshots:` — because narration is off by default (#53 scope 4's reasoning extends to it) and a
permanent line on a profile that never records audio is noise: `NotProvisioned` / `UpToDate` /
`Uploading N` / `Retrying N` / `N undelivered` (sticky) / `spool unavailable; narration not
delivered` (the spool itself could not be constructed). `Abandoned` outranks `NotProvisioned` for
the identical reason the event tally does. None of these carries the tray's `!` error prefix.

**The clip is written twice, and up to three copies live in memory at once, both accepted costs.**
Once by the journal's own content-addressed blob store, once by the narration spool — delivery must
not depend on the archive's internal layout or on issue #12's unwritten retention, exactly as
screenshot delivery already accepts for its own staging area. In memory: the capture engine's own
defensive snapshot, and `ArtifactDeliveryDescriptor`'s private array; `NarrationSpool.Stage` and the
capture-path stager both operate on `ReadOnlySpan<byte>` end to end, so neither adds a further copy.
**This second write runs synchronously, inside the capture engine's own lock**, exactly like
`ScreenshotDeliveryPreparer.Prepare` does for its own (much smaller) network call — see
[Screenshot delivery](#screenshot-delivery) above for the identical concern applied to a network
call rather than a local write. A closed label therefore costs one more synchronous write of up to
`NarrationDeliverySettings.MaximumClipBytes` on the capture path, once per closed label — not once
per click or keystroke.

**Three accepted trade-offs, stated plainly rather than left implicit.** First, `NarrationSpool`'s
background reads (`ReadBlob`, re-verifying a staged clip's digest before upload) and its capture-path
write (`Stage`) share one coarse lock, exactly like `EventSpool`'s — but unlike an OTLP body (at most
`MaximumBodyBytes`, 1 MiB), a narration clip can be tens of megabytes, so a closed label can, in the
worst case, block briefly on a concurrent background re-verification of a different clip already in
flight. This mirrors the identical, already-accepted trade-off in `EventSpool`'s own coarse-lock
design, just at a larger scale; splitting file I/O out from under the lock was judged more risk than
the contention is worth for a modality that produces a handful of clips per session, not a hot loop.
Second, unlike `EventDeliveryWorker`, `NarrationDeliveryWorker` does not park itself on a 401/403 the
way the event drain worker does — `KeboolaFilesClient`'s own response classification has no
distinct "revoked" outcome to key off without widening the transport, and a pass that already stops
at its first retryable failure (see above) does not hammer a revoked endpoint anywhere near as hard
as an unparked per-event worker would. A revoked Storage credential is retried on the ordinary
10 s–15 min backoff until `App.RefreshNarrationDelivery` replaces the client with a fresh one.
Third, `App.RefreshNarrationDelivery` is itself only re-invoked when `RefreshDeliveryTarget` runs —
on startup, on a new provisioning read, or on the OTLP stream target's own scheduled expiry
(`ScheduleExpiryRefreshAsync`) — since narration has no equivalent live check of its own the way
`ScreenshotDeliveryPreparer.Prepare` re-checks its credential's expiry on every call (prepare happens
on the worker's own background task, not the capture path). Review finding, Copilot round 2:
`ScheduleExpiryRefreshAsync` used to only push the tray's event-delivery status and nudge that
scheduler once the watched target's expiry passed, never touching narration at all — so a bundle
that *did* carry a `streamEndpoint` (the ordinary case) still left `NarrationDeliveryWorker` retrying
every not-yet-uploaded clip against an expired Storage token indefinitely, one live HTTP round trip
per attempt, for as long as nothing else happened to trigger a fresh `RefreshDeliveryTarget` call.
Fixed: that same watch now also calls `RefreshNarrationDelivery(null)` once its target's expiry has
passed, forcing the same "no usable credential" path a failed or missing bundle read already takes,
since both credentials share one `DeviceBundle.ExpiresAt`. A device bundle that carries a valid
Storage credential but **no** `streamEndpoint` at all is narrower, and remains disclosed rather than
fixed: it never schedules that watch in the first place (`ScheduleExpiryRefreshAsync` is keyed to the
stream target, which does not exist for such a bundle), so a Storage-only bundle's own expiry still
self-heals only on the next actual provisioning event. No data is lost purely from retrying against
an expired token — clips stay durably staged and are retried rather than dropped for that reason
alone. The two bounds above still apply to an unstamped clip exactly as they always do: one stuck
retrying prepare or upload against an expired token for long enough can still be evicted like any
other (a visible, counted loss, same as ever). A clip that had already been stamped *before* the
token expired is different: as the bounds' own paragraph above states, a stamped entry is never
evicted by either sweep regardless of how long its row emission has been separately stuck retrying —
that case is bounded only by the event spool eventually accepting the row, not by either narration
bound. A Storage-only bundle is not the profile this client is
provisioned with in practice today (`jazz-win-dev` carries a stream endpoint too); closing this
narrower case needs an expiry watch keyed to the Storage credential independently of the stream
target, which is a larger change than this fix.

**A `Nudge()` does not shorten an in-flight sleep-until-due, and this matters more here than for its
siblings (disclosed, not fixed, Copilot round 2).** `DeliveryDrainScheduler`'s own remarks already
name this as a known, accepted limitation from issue #48/#72: a `Nudge()` that arrives while the
scheduler is sleeping out one item's own backoff does not wake it early, because for its two existing
callers (screenshot, event) the row was already emitted immediately regardless of that delay — only
the background delivery attempt is postponed. Narration's hold-until-uploaded design breaks that
assumption: the event is *not* emitted until upload succeeds, so if `NarrationDeliveryWorker` halts a
pass on an older clip's retryable failure and sleeps out that clip's own backoff (up to
`UploadBackoffCeiling`, 15 minutes by default), a *different* clip staged moments later — with
custody already taken, its own event already withheld, and its own `NextAttemptAt` due immediately —
still cannot be attempted until that sleep elapses, since the pass-halting rule (see above) means
that same older clip is re-tried first on every re-entry regardless. In the worst case this defers a
freshly-staged clip's row by up to that same 15 minutes. Fixing it needs `DeliveryDrainScheduler`
itself to support cancelling an in-flight sleep-until-due on a fresh nudge — shared, previously
reviewed and accepted infrastructure all three delivery paths depend on — which is a larger and
riskier change than this issue's own scope, so it is disclosed here rather than attempted late in
this review cycle.

**No drain at shutdown.** Every staged pair, and every stamped Files id, is already durable by the
time `Stage`/`TryStampFilesId` returned, so there is nothing to flush at exit.

Every operational bound lives in `Settings.NarrationDelivery` (`NarrationDeliverySettings.cs`),
compiled-in exactly like the screenshot and event bounds.

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

The release-candidate triplet is additionally emitted as
`JazzCapture-<version>-win-x64-unsigned.msi`, `.sha256`, and `.manifest.json`. Promotion must
consume and revalidate that triplet; it must never rebuild the MSI.
Only the Windows WiX candidate triplet is promotable. The `wixl` cross-build is structural parity
evidence and is never a substitute release artifact.

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
