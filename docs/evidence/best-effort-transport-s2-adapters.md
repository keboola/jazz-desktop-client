# S2 concrete adapters and fence wiring

Implemented on desktop PR81 after `a1905f7`. **No new capture activation.** The app still constructs
no `BestEffortTransportDriver` and never calls `attachBestEffortDelivery`. Existing archive producers,
human confirmation, journals, upload bytes, credentials, wire schemas and OTLP mappings are unchanged.

## Concrete code

- [`BestEffortTransportDriver`](../../macos/Sources/JazzCaptureCore/BestEffortTransportDriver.swift)
  owns a bounded OperationQueue, HTTP task registry, metadata/reports and one coalescing100ms timer.
  Capture offers use try-lock admission and reserve Core bytes/encoder slots before encoding.
  Rejected offers spawn nothing. Fixed-shape existing OTLP models get a conservative escaped-JSON
  expansion preflight and compact copies, then the existing `JSONEncoder`; no alternative wire model.
- [`JazzCredentialSafeHTTPSession`](../../macos/Sources/JazzCaptureCore/CredentialSafeHTTPSession.swift)
  gains a suspended `makeBoundedUpload` operation with a **physical-completion callback**. It reuses
  the existing no-redirect/no-ambient-credentials session and bounded response delegate. Both declared
  and streamed response sizes are capped at65,536bytes before retaining more data. Oversize/cancel
  retains this operation until `didCompleteWithError`, not an early async cancellation continuation.
  Existing archive/control-plane async API cancellation behavior is preserved.
- The initial upload body is an in-memory InputStream; no replacement stream is supplied for hidden
  body replay. Driver admission/register/resume is atomic with fences. No credential lookup, file IO,
  codec execution or arbitrary caller closure runs under that start lock. Explicit retryable HTTP
  responses follow Core backoff/Retry-After/deadlines; lost or partial ACKs never trigger batch replay.
- [`BestEffortFileEncoder`](../../macos/Sources/JazzCapture/BestEffortFileEncoder.swift) reuses existing
  `KeboolaAPI.FilesPrepare.GCSUploadParams` for the **already-prepared GCS PUT leg**. It pins HTTPS GCS
  host, escapes object keys, bounds/validates request metadata and preserves the supplied grant
  deadline. Sealed files are opened read-only/no-follow/nonblocking, checked by descriptor for regular
  type and exact length, read in≤64KiB chunks up to the reserved limit, and SHA256-verified before any
  upload. Symlinks, FIFOs, size/hash mismatch, growth/truncation and cancellation fail closed. Nothing
  deletes, prepares, truncates, cleans, or rewrites a File/artifact/spool.
- [`BestEffortImageEncoder`](../../macos/Sources/JazzCapture/BestEffortImageEncoder.swift) uses a native
  ImageIO `CGDataConsumer` that refuses excess output **while encoding**, rather than measuring a
  fully allocated JPEG afterward. Pixel-row/height and quality inputs are validated; cancellation
  is checked in the consumer. The GCS request builder also serves this in-memory JPEG path: there
  is **no mandatory temporary file or transport spool**. The existing archive screenshot encoder is
  not replaced, and this encoder never acquires a screen.
- `CaptureStartIntent` can stage one disarmed adapter. Every generation change, Pause, shutdown and
  rotation fences it. New start/rotation and clean run-guard clearing require actual adapter-owner
  quiescence. `CaptureController.closeSourceAdmissions()` fences the optional adapter beside existing
  physical producer gates; environment sleep/lock/revocation flow through the existing source owner.
  HTTP401/403, expiry or an invalid monotonic clock issue at most one generation-bound MainActor
  notification, routed to the same native environmental close. Stale notifications cannot stop a
  newer intent. No wake/reconnect/timer automatically starts a generation.

## Ownership and bounds

Core limits still cover unit/encoded-byte/encoder/in-flight counts, original age, attempts and retry
backoff. Defaults remain engineering limits, not adopted production SLOs. The adapter's task/operation
registries cannot exceed those reservations; response retention is≤in-flight count×65,536bytes.
Cancelled/expired encoders remain charged until `Operation.main` actually returns; HTTP remains charged
until the URLSession completion delegate delivers physical completion. A suspended delegate queue or
non-cooperative encoder therefore prevents reuse rather than hiding more live owners.

The single timer uses injected monotonic time in tests. Request resource/deadline timeouts provide a
second cancellation mechanism. Neither mechanism claims server termination or proof of nonacceptance.
Expired per-media grants are rechecked at dispatch. Invalid/overflowing Retry-After and HTTP-date
Retry-After currently become unknown/non-retryable; no guessed wall-clock conversion shortens a delay.

These bounds are not a whole-app RSS guarantee: compact model/input/output copies, Foundation/network
internals, native ImageIO working sets and original CGImage provider/crop backing need separate working
set budgets/qualification. Visible pixel geometry alone cannot prove provider backing size. The sealed
file encoder owns no output/temp files and never loads more than its reserved size plus a read chunk.
The generic media callback must uphold its stated working-set/actual-return contract; concrete file
and JPEG implementations are supplied and tested here, not a claim that arbitrary closures are safe.

## Tests and actual results (implementation commit7e85239)

**24 additional tests** across the driver, native adapters/fences and existing HTTP test fixture:

- Real URLSession with deterministic URLProtocol fake servers: disconnect, slow/nonreturning reply,
  ACK loss after a response fragment, malformed/partial/201/499 responses,429 with exact Retry-After
  scheduling and identical body retry, invalid/date/overflow Retry-After, automatic timer retry,
  grant expiry during encoding, authority expiry, HTTP revocation and request-boundary rejection.
- Declared/chunked oversize responses and2000 saturated offers assert response-byte, encoder, in-flight,
  queue-byte and report bounds, with actual held HTTP owners established before saturation. A byte
  ceiling also blocks dispatch despite unused task slots. Paused delegate delivery proves cancel/deadline does not release HTTP
  reservations; a deliberately non-cooperative encoder proves the same for physical encoding.
- Real TCP loopback server receives the complete streamed request and disconnects before ACK: one
  complete body received, no body replay. A307 cannot reach its redirect target. This is local HTTP
  evidence, not live Keboola/TLS/HTTP2/load qualification.
- Actual native JPEG encoding/decoding, output/pixel-budget rejection, cancellation, and in-memory
  JPEG→bounded URLSession→fake GCS. Sealed-file→driver composition covers event-only/media-only loss
  while preserving source bytes. File tests cover descriptor/type/length/hash and mid-read cancellation.
- Existing intent/environment classes exercise Pause, rotation, sleep/lock, no wake Resume, revocation,
  invalid clock and stale MainActor notifications without TCC or a physical recording.
-128MiB file-encoder turnover through a1MiB sealed file: final full-suite peak-RSS growth **4,915,200bytes**
  under a64MiB regression guard; no output files. Existing Core512MiB/8MiB-queue test also passed with
  **0 additional high-water bytes** (not zero allocation: the process had already reached a higher
  peak). Allocator high-water measurements depend on test order; not sustained app RSS.

All six prescribed contract validators, `swift build && swift test`: **896 tests,1 expected live-OTLP
skip,0 failures**. Strict full-file Swift-format lint passes for new Swift files and the extended HTTP
session. Existing files retain baseline style findings; baseline-relative checking found no new
findings. No CI/lint configuration was weakened and no blanket legacy reformat was made. Diff checks
and evidence links pass. No independent review is claimed.

One initial fault test assumed the event encoder had already returned when the separately gated media
encoder entered. It failed under valid OperationQueue scheduling; the test now observes the event's
actual return before asserting that only the held media reservation remains. CoreGraphics API spelling
and new-line style corrections were also resolved before the final full run.

Receipts/logs: `/tmp/jazz-continuous-eaa688eb/s2-runtime/adapter-*`, with the validation script and
formatter configuration retained beside them. All remote-looking URLs/tokens in tests are synthetic;
fake transports refuse network fallback. Only the TCP fixture uses local loopback sockets.

### Fixture-isolation follow-up

The TCP fixture is now explicitly bound to127.0.0.1, and its request-byte cap is checked before
waiting for a header terminator. This hardens test infrastructure only; runtime adapters are unchanged
from7e85239. All six validators and Swift build/test were rerun:896 tests/one expected skip/zero
failures. This rerun measured3,080,192bytes file-encoder RSS growth and2,342,912bytes additional Core
high-water growth. Log: `adapter-hardened-validation.log`; the earlier measurements above are retained
as their own run, not silently replaced.

## Remaining gates

The requested ready adapter/scheduler/fence seam is implemented, not another plan-only checkpoint.
Still no production mode: File grant preparation/issuance and verified Company/Area/device binding,
versioned loss/unknown-coverage capability and reader allowlists, real native acquisition/AAC working
sets, sustained utility/fidelity/resource trials and live service failure semantics remain separate.
File PUT success is hop acceptance, not grant validation, immutability or archive/analysis completeness.
S3 must coordinate authority/contracts/readers before construction is wired into capture. No settings
switch, enrollment import, installed-app change, archive mutation, deployment or private playback here.
