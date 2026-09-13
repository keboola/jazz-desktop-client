# DirectPilot focused static review — 2026-09-13

Reviewed implementation **e670f23df36f99c8ec7d9c78ac99bb0a22ca2dae** (published with9cf8d76)
against ADR0025 Option C and the existing PR81 transport/enrollment contracts.
Fix commit: **3dced1dfa3d108bc9efc8a37d4b3649108aedebf**.

This is a parent-performed static review plus runnable offline checks, not independent review or
native E2E acceptance. **No app launch, Keychain/password operation, provisioning, capture,
legacy-spool access, or deferred server work occurred.** The owner gate remains unresolved.

## Concrete findings and fixes

| Finding in e670f23 | Narrow correction / regression |
| --- | --- |
| Start synchronously calls `Keychain.get` on MainActor. The earlier native stack already demonstrated this can block controls while SecurityAgent waits. A scheduled Start also attempts authorization even after Stop. | One off-main read, still owned by the pending Start until physical return; generation checked before scheduling authorization and after return. Stale completion cannot overwrite Pause/Stop/lock. Injected synthetic blocking-read test proves MainActor remains available and late value is discarded; actual unscoped Start→Pause test proves no late authorization/status replacement. **No ACL, credential storage, approval or password policy changed.** |
| Pilot calls the broad `Accessibility.focusedInfo`: it reads field values, selected text, document URLs and titles although this path only needs privacy metadata. It also performs foreign AX IPC on the event-tap/MainActor callback. | Reuse the existing reader with an opt-in privacy-only subset, explicit foreign PID and focused-window geometry. Read only role/subrole/label plus owner/window geometry, never value/selection/document metadata. One existing media owner now waits for foreign AX off-main; Stop retains that owner until return. Missing role/frame refuses the screenshot. Attribute-allowlist and closed-admission regression tests use no real AX input. Legacy callers retain their default full lookup. |
| No target rectangle is passed to SCK: `pickWindow` chooses the **largest** window of the allowed app, which can be a background document unrelated to focused-field privacy checks. | Pilot requires a unique AX-focused-window geometry match; missing/ambiguous matches fail closed, without largest-window/display fallback. Tests cover overlapping larger background windows, absent target and duplicate geometry. This is conservative geometry matching, not a new authoritative window-ID protocol. |
| SCK/JPEG/Files preparation runs before inspecting transport pressure. Already-full/busy queues can repeatedly cause expensive acquisition and orphaned remote preparation. | Advisory count/bytes/encoder/fence preflight before AX/SCK and again before Files preparation; `driver.offer` still provides the authoritative atomic reservation. Audio uses the same preflight. Full/busy/fenced queue tests exercise the actual transport counters. Known pre-offer failure no longer advances screenshot dedup; hash0 follows the encoder's existing “unknown hash, keep sample” convention. No new retry policy or unbounded buffer. |
| Artifact intervals use the input-event/epoch start and the time **after Files preparation**, not media acquisition. Narration can falsely span the entire session. | Screenshot interval comes from existing `ScreenCapture.assess` monotonic-duration normalization. PCM interval uses its actual byte-duration ending at chunk flush time, not epoch start. Existing partial/unknown coverage still applies, including dropped callbacks. The production batch builder is extracted unchanged except corrected timing/required sequence so tests can decode its actual canonical OTLP envelopes and assert acquisition timing, source/stream IDs, artifact↔observation refs and exact File content digest/length. |
| Token verification uses the unbounded JSON response helper, despite pilot resource ceilings. Relative GCS grant expiry is extended by time spent waiting for Files preparation. | Pilot opts into the existing64KiB bounded HTTP response seam for verification (legacy default unchanged); injected URLProtocol tests accept a small valid reply and reject an oversized otherwise-decodable reply. Files grant expiry is conservatively anchored before preparation and capped by signed authority; invalid nonpositive File IDs are refused. |
| A retired driver's sticky report-overflow flag calls `stop` every poll, including while a new explicit Start is awaiting verification. | Overflow stops an active capture only, never repeatedly cancels the next handshake. A real driver with intentionally overflowed reports reproduces the retired-owner state offline. Stop also preserves its requested lock/sleep/stop fence after intent persistence; irrevocable driver fences remain sticky. Eligibility continues to check required screen and enabled-audio permissions, not only Accessibility. |

Only six source/test files changed:

- `macos/Sources/JazzCapture/CaptureController+DirectPilot.swift`
- `macos/Sources/JazzCapture/Capture/Accessibility.swift`
- `macos/Sources/JazzCapture/Capture/ScreenCapture.swift`
- `macos/Sources/JazzCapture/KeboolaClient.swift`
- `macos/Tests/JazzCaptureTests/DirectPilotTests.swift`
- `macos/Tests/JazzCaptureTests/AXCaptureBoundaryTests.swift`

Small existing-function extractions/injection seams support offline regressions; no service, queue,
factory, new wire fields, contract/golden changes, processor modifications or enrollment architecture.

## End-to-end static trace / unchanged contracts

1. **AppDelegate:** exact bundle selection precedes all legacy owners; launch returns through
   `launchDirectPilot`. Legacy controller/connection/UI/updater/renewer are lazy, with an explicit
   non-pilot precondition on archive-controller construction. Start/Resume/Pause/Stop selectors invoke
   the native pilot owner, not notifications only. Separate quit retains physical-return semantics.
2. **Scope and IDs:** accepted signed enrollment is required, never pending verification alone.
   Bundle/project3044/device/source, dedicated Stream source, sink-write/non-admin token and finite
   expiry are checked before activation. Epoch authorization compares the signed binding/capability;
   deadline is the minimum credential/bundle/capability expiry. Canonical `src-` provenance and
   `stream-` UUIDv7 IDs are distinct from the authorized Keboola Stream source ID. They are minted per
   explicit epoch and retained across that epoch's offers/retries; they are not client scope authority.
3. **Correlation and OTLP:** one existing activity observation plus optional artifact descriptor;
   matching capture/origin, stream/sequence, observation/artifact references, File ID in the activity
   payload, content SHA256 and exact length in the artifact. Four existing best-effort attributes,
   provisional body, no raw media bytes or fake trace/span IDs. The production-builder regression
   decodes both actual envelopes and validates the epoch pins and correlation. Media remains pending,
   never READY based on a hop ACK. No epoch-registration/analysis-admission mechanism was invented.
4. **Driver/File/native path:** existing bounded driver reserves before its encoders, freezes request
   bytes and separately classifies event/media outcomes. Lost/malformed/partial ACK never permits
   whole-batch replay. GCS destination/request builder, bounded JPEG consumer, single physical SCK
   owner and bounded PCM callback/mailbox remain the existing implementations.
5. **Fences:** Stop invalidates generation; intent and transport close pending work; EventTap, AX and
   SCK admissions close. Media/AX/prepare tasks and audio drains retain physical ownership across
   logical cancellation. New Start requires quiescence. Lock/sleep/revocation, permission loss,
   expiry and report overflow close active capture; reconnect/wake alone cannot re-arm it.
6. **No archive machinery:** canonical archive *types/codecs* and filesystem synchronization are
   reused, not archive owners. Only isolated intent/acceptance metadata is durable; no EventSpool,
   archive journal/package/finalization, upload queue, CaptureSetup or legacy renewal path is created.
   The metadata root/Keychain service remain separate. Ordinary archive-first behavior is unchanged.

## Bounds and honest limits

Driver bounds remain32 units/8MiB reserved/1MiB part,2 encoder owners,2 upload owners/2MiB in-flight
bodies, finite age/retries and bounded ACK/report storage. Pilot has one extra acquisition/Files-prepare
owner, ≤960-pixel dimension and ≤512KiB JPEG,64KiB prepare/verify responses, and one latest64KiB PCM
chunk/≤64,044-byte WAV. No temporary media spill. The advisory media snapshot is **not** an atomic
reservation; pressure may change during native acquisition, so offer may still refuse and report loss.

The512MiB process high-water check is a **sampled fail-closed tripwire**, not a hard bound over
ScreenCaptureKit/ImageIO/Keychain/OS allocations or a qualified battery/CPU/latency guarantee.
A media-associated event may wait behind its single acquisition/preparation owner and be dropped
if stale; other observations continue. Hop counters describe batches/acquisition outcomes, not an
exact global event-loss ledger. Geometry races, real TCC withdrawal behavior, owner approval, actual
Stream visibility and Files byte parity still need the owner-present native E2E.

## Measured offline validation

All six prescribed contract/fixture validators passed; unchanged archive golden remains25,045bytes,
SHA256`de755fe7fde94dde3cb2c953757458fcc4c53fb4bc71ef59f039b7c85084118a`.

- `swift build`: pass.
- Focused110 tests: **0 failures,0 skips**,1.612s.
- Full Swift suite: **914 tests,1 expected skip,0 failures**,33.625s at08:23:14Z.
- Eight new tests plus the extended PCM interval check; production builder, not an empty-logs stand-in.
- `git diff --check`: pass. Two initial compile diagnostics (optional interval unwrap/test import)
  were corrected before the passing runs; no native execution was used to fix them.

```sh
cd macos
swift build
swift test --filter 'DirectPilotTests|AXCaptureBoundaryTests|BestEffortFileAndFenceTests|BestEffortTransportDriverTests|ScreenCaptureEvidenceTests|CaptureStartIntentTests|BestEffortTransportTests|SignedEnrollmentSecurityTests'
swift test
```

Evidence root: `/tmp/jazz-continuous-eaa688eb/direct-client-pilot/static-review-UaLw0N/`.

| Receipt | SHA256 |
| --- | --- |
| `contracts.log` | `a383c3a6d62ab200d99e36fe4eb59fa180c517b8fd0f1cb594796649ca6a25c6` |
| `build-final.log` | `969c792e80478083b5f91282e8c291a1703d9a4d487b11b2ee15a13f71f91d76` |
| `focused-final-verified.log` | `81340c16043d86bb37025110d73d14d9f74bf98d67c1cb384919163890bca4da` |
| `full-final.log` | `cbdc293ad6ab568be9e41adae48e22e5191f5ce317fd13b3e55a6597a062dd1b` |

Installed pilot SHA remains`90bab20182a4808c1696a16651c7d2bcb1dd17def5e7a53cce0a3e15af67d020`;
legacy executable remains`4ec1e731a217e314d53ccf2ece6d23c646f342c6a044e4ced566d0575e2e0737`.
**The installed pilot was not replaced and does not yet contain this fix.** Integrating the reviewed
build into a future signed pilot is part of the next owner-gated run, not an autonomous launch now.
Legacy spools were neither read nor written; no new spool byte inventory is asserted.

No client E2E/broader DoD PASS, no exact-head CI/independent-review claim, and no terminal-status.
Only explicit owner confirmation of presence/readiness to approve can authorize another scoped
capability/prompt attempt. Provisioning, signing, TCC and Stream scope are not being relabeled blockers.
