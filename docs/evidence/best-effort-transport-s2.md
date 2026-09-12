# S2 bounded best-effort transport runtime — first implementation

**Implemented and unit/fault tested, not activated in the installed capture path.** This is reusable
Foundation runtime code, not another qualification script. No production mode/authority, archive
rules, emitted schemas, OTLP mapping, credentials, installed app or pending deliveries changed.

Base: `6e10be3c68b061e84077cc28934e326df7baaac8` (desktop #35). Branch
`feat/bounded-best-effort-transport`, separate worktree `jazz-desktop-best-effort-transport`.

## Runtime and reuse

[`BestEffortTransport.swift`](../../macos/Sources/JazzCaptureCore/BestEffortTransport.swift) owns
actual immutable queued payload bytes and encoder/HTTP reservations. It reuses Foundation locks,
Data/UUID and the existing `JazzArchiveJSONValue` decoder. Its generation input is the same local
UUID used by `CaptureStartIntent`; it does not create a competing capture lifecycle or authority
service. Existing encoders/File/HTTP seams remain the adapter boundary. No dependency, task-per-offer,
network client, daemon, broker, disk queue or new canonical evidence type was added.

- Capture calls **`reserve` before encoding**. `NSLock.try()` never waits behind worker IO admission;
  contention/full/closed/invalid requests return nil and must not schedule acquisition/encoding.
  Reservation accounts the maximum encoded event/media bytes and encoder slots before allocation.
- Worker calls `finishEncoding` for actual encoder return, including failure. Payloads are compactly
  copied: a small slice/externally mutable backing buffer cannot retain arbitrary memory in Core
  or mutate retry bytes. Masking must already have happened in the existing encoder/capture layer.
- Worker pulls using `withNextAttempt`; admission and non-blocking operation registration/start are
  serialized with Stop/Pause fences. The start closure must not block, await, read Keychain or
  reenter Core. Credentials/authorized request preparation must precede it. This caller contract
  still needs the real URLSession/File adapter qualification; arbitrary blocking code in that
  closure would delay a fence, and this component does not claim otherwise.
- `advance(generation:now:)` uses an injected monotonic clock and returns network and encoder
  cancellation requests. An existing bounded worker/timer must call it; no timer is hidden in Core.
  Old queued work cannot dispatch after its age limit even without prior ticking.
- **Timeout/cancel is not physical return.** Encoder/HTTP bytes and slots remain charged until
  `finishEncoding` / `finishAttempt` reports actual return. Non-cooperative work blocks reuse and
  fresh start rather than permitting unbounded hidden producers. Core cannot enforce an adapter
  that falsely reports return; native producer/URLSession fencing remains mandatory.
- Exponential retries are bounded by attempts, delay cap, Retry-After and original unit age.
  Retry-After is never shortened to squeeze a retry inside a deadline. Retry bytes/unit IDs are
  unchanged; new attempt IDs reject duplicate callbacks. Retry permission is not proof of nonacceptance:
  exhaustion, eviction or later rejection after a retryable response remains unknown, not a claim
  that nothing reached the receiver. This does not supply server deduplication.
- Lost/malformed/partial ACKs become **unknown**, without replaying a possibly accepted batch or
  inventing rejected IDs. Explicit retryable responses (429/502/503/504) use the bounded retry path.
  Unauthorized responses revoke the owner. Unexpected statuses such as499/201 stay uncertain.
- Event/media dispositions are independent (`hopAccepted`, `unavailable`, `unknown`, `notExpected`).
  Reports bind unit ID **and generation**. Two hop ACKs never become an archive/analysis completion.
  Coverage is always unknown; bounded report overflow is visible. Busy admission and process death
  cannot promise an exact loss ledger.
- Pause/Stop/lock/sleep/revocation synchronously fence admission, discard only this volatile owner's
  queued payloads, and request cancellation of physical owners. Explicit fresh start requires their
  actual return. Reconnect/ticks cannot Resume. Revocation or invalid monotonic clock requires a new
  owner and independently validated authority, not reactivation of the same instance.
- Fresh processes start disarmed with no payload/history restoration and unknown coverage. Nothing
  here reads/deletes/resubmits an archive, journal, spool, File or recording. Existing durable paths
  are unchanged and must never be passed into a best-effort eviction policy.

### Explicit engineering limits

Defaults (validated/tunable constructor inputs, **not adopted production SLOs**):64 delivery units,
16MiB total reserved/queued/in-flight payload bytes,4MiB per component,4 encoding parts,2 HTTP owners /
8MiB in flight,3 attempts,30s original age,10s per attempt,1s initial /8s capped exponential backoff.
Reports are bounded to the unit limit. Memory scans are O(configured units); no unbounded history.

These are **delivery-unit/encoded-byte bounds**, not a claim about arbitrary raw pixel buffers,
codec working sets, URLSession copies, caller-retained Data, record count inside an encoded batch or
whole-app RSS. Native admission must budget those external allocations too. Core performs no file
IO and owns zero temporary-file bytes; a future codec-file adapter needs its own measured bound.
ACK parsing rejects bodies over65,536bytes, but the HTTP adapter must also cap bytes while reading:
calling unbounded `URLSession.data(for:)` and checking afterward is not a memory bound.

## Executable proof

[`BestEffortTransportTests.swift`](../../macos/Tests/JazzCaptureCoreTests/BestEffortTransportTests.swift)
adds **19 tests**, including:

- outage retries at deterministic deadlines with byte-identical payloads and stale-attempt rejection;
-429 Retry-After, attempt exhaustion, overlong/invalid retry delays and original-age expiry;
- lost/partial ACK unknown outcomes without whole-batch retry, malformed/deep/oversized ACKs;
- event-delivered/media-lost and media-delivered/event-lost states, without false completeness;
- full queue freshness eviction while encoder/HTTP owners remain non-evictable;
- independent in-flight count/byte ceilings, encoding ceilings, oversized payload refusal and
  isolation from externally mutable / oversized Data backing storage;
- slow/non-cooperative IO, deadline cancellation without slot release, late results after fences;
- Pause/Stop/lock/sleep/revocation, no reconnect/wake auto-start and no restart before actual return;
- real **owned test-child SIGKILL**, then a fresh test process proving empty/disarmed/unknown state,
  no replay and no restored delivery reports (only synthetic test rendezvous markers on disk);
- capture reserve returning immediately under a deliberately blocked worker lock;
-10,000 turnover operations with bounded byte/slot/report counters and report-overflow visibility;
-512MiB real payload turnover through an8MiB queue, with a generous **64MiB process peak-RSS-growth
  regression ceiling**, not an8MiB process-RSS claim. The final full suite observed **6,258,688bytes**
  growth; the final focused run observed9,420,800bytes. Allocator/test history affects high-water
  measurements; neither establishes camera/audio/network/sustained installed-app resource limits.

Parent review caught one actual defect before publication: callbacks from retired owners validated
old timestamps before checking ownership and could poison a fresh generation's clock. The new
regression failed with two assertions; ownership/generation checks now precede clock mutation,
including the timer API. Its corrected test passes. Stale unauthorized callbacks cannot revoke a
new owner. No independent review is claimed.

## Validation

- All six prescribed contract/schema/fixture validators: **PASS**.
- `cd macos && swift build && swift test`: **872 tests,1 expected live-OTLP skip,0 failures**.
- Focused suite:19 tests pass; Swift compiler typechecks Core and executable targets.
- `swift format lint --strict` on both new Swift files passes using the tool's standard rules with
  four-space indentation. No existing source formatting or CI configuration changed.
- `git diff --check` and new document links pass.

Logs: `/tmp/jazz-continuous-eaa688eb/s2-runtime/{focused-final.log,stale-clock-red.log,full-validation.log,lint.log}`.
`validate.sh` runs the repository's six validator commands, then Swift build/test. The formatter
configuration is retained there. Full validation log SHA256:
`2d874ba8a5c6da7e9784f1120a7b30139f2180d33accfb5d70998171df727427`;
runtime source SHA256: `d9c916fd575a8271fdb7e65b40287ee70633bc45646f936c71be5128fdf8d236`.
The installed executable still matches its pre-run SHA256
`4ec1e731a217e314d53ccf2ece6d23c646f342c6a044e4ced566d0575e2e0737`.
SIGKILL targeted only fixture processes created by the test, never
`/Applications/Jazz Capture.app`. No live credentials or service requests were used.

## Remaining gates — implementation is not activation

S2 now has a real reusable queue/policy and fault-tested ownership semantics. Still OPEN: concrete
bounded streaming-response / File / native encoder adapters, scheduler wiring to current intent and
physical fences, real network lost-ACK/partial/429/slow-upload behavior, native codec/temp/URLSession
memory ceilings, sustained RSS/battery/latency and usefulness/fidelity trials.

S3 must coordinate approved capability/loss/transmission authority, source/media scope, schemas and
readers/immutable input selections before any new-mode enrollment or capture uses this policy.
This slice does not adopt crash/RAM-tail loss for production, bypass archive confirmation, change
liveCompatibility meaning or create fake READY/CaptureCommit. Deployment/cutover/rollback, installed
native qualification, September8 authenticated playback and S7 operational/discovery gates remain
separate. No app install, Start/Stop, enrollment import, remote resource mutation or deployment here.
