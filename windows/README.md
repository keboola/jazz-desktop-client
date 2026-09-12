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

Capture is off on a fresh unmanaged profile. There are three ways to turn automatic capture on, and
they resolve through one precedence:

```
managed policy (#60)  >  installer preference (#60)  >  launch switch (#76)  >  user setting
```

with one rule that applies above every layer: **an explicit user pause suppresses automatic start
until the user resumes it**, regardless of which layer would otherwise turn it on. Today, before
#60 lands, only the bottom row of that table (`launch switch > user setting`) is reachable, and it
is reachable in these three ways:

1. **The tray checkbox.** Enable **Start local capture automatically when Jazz opens** in
   **Settings**. This is the persisted user setting, the lowest-ranked layer.
2. **A preset `settings.json`** written before first launch — the recommended path for a
   deployment, since it survives every later launch regardless of how the process starts. See
   [Configure capture at launch without the tray UI](#configure-capture-at-launch-without-the-tray-ui)
   below for the exact document and its one sharp edge.
3. **The `--capture-at-launch` launch switch**, for a shortcut you create yourself (the MSI's own
   Start Menu shortcut and `Run` value carry no switch — see below), a scheduled task, a login
   script, or manual testing, before #60's installer preference and managed policy exist. The same
   section below covers its exact spelling and its process-scoped, never-persisted behaviour.

Choosing **Stop capture** commits the active journal and pauses whichever layer is currently
turning capture on, launch switch included; choose **Start capture** later to resume it. A
provisioned device bundle, delivery credentials, and the Windows login registration do not
themselves enable capture. The tray's **Status and onboarding...** item opens the status window on
demand, and its text reports which of the three effective states is in effect: not configured to
start automatically, starting at launch, or paused by a prior stop — reflecting the effective
value across every layer, not only the tray checkbox.

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

The installer deliberately leaves settings, captures, the queue, and the event spool in place when
it is removed. Use a separate Windows account or VM when a test needs a completely fresh profile.
The staging directory is the one exception to that durability guarantee: unlike every other row
above (including the event spool), it is cleared on every launch, not only on uninstall, so nothing
there is expected to survive even a normal restart of Jazz. See
[Screenshot delivery](#screenshot-delivery) and [Event delivery](#event-delivery) below.

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

The MSI property, the registry-backed policy store, and Intune packaging that would let an
administrator set these without touching a shortcut, a scheduled task or a login script at all are
**not** part of this: that is tracked separately (issue #60) and builds on top of the launch switch
and precedence table described here without changing them.

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

Windows delivers captured activity and screenshots through the legacy path only: Data Stream OTLP
for events (`MvpStreamSender.cs`, drained from the durable `EventSpool`) and the Keboola Files API
for screenshots (`KeboolaFilesClient.cs`). Both run live, independent of any archive-level
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

**At-least-once, per-session FIFO.** An entry is deleted only after a 2xx; a crash between the 2xx
and the delete replays that one event. The duplicate is deterministic (`eventId` is
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
