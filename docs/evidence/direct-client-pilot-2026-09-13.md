# Direct client wiring and bounded pilot smoke — 2026-09-13

**Real native call-site wiring implemented in `e670f23df36f99c8ec7d9c78ac99bb0a22ca2dae`.
Build/tests pass. Live event/media E2E does NOT pass: Start blocked at macOS Keychain approval.**
No terminal-status or claim that all remaining client work is externally blocked.

## Actual call sites, not notification-only wiring

| File / line at implementation commit | Invocation |
| --- | --- |
| `macos/Sources/JazzCapture/AppDelegate.swift:46` | Select isolated pilot before constructing any legacy owner. Legacy properties are lazy; controller construction additionally preconditions non-pilot mode. |
| `AppDelegate.swift:228,248–262` | Construct `CaptureController.DirectPilot`; real Start/Resume, Pause and Stop menu actions invoke its lifecycle. Separate pilot quit waits boundedly for physical return. |
| `CaptureController+DirectPilot.swift:199–218` | Construct existing `BestEffortTransportDriver`, attach via `CaptureStartIntent.attachBestEffortDelivery`, then explicitly activate driver and real `EventTap` under verified authority/intent. |
| `CaptureController+DirectPilot.swift:264` | Real SCK focused-window sampling, capped dimensions/JPEG encoder; no display fallback in pilot. |
| `CaptureController+DirectPilot.swift:307,315,324` | Offer bounded existing-contract OTLP batches to `/v1/logs`; prepare isolated Files with signed narrow credential, construct GCS request through existing File adapter, upload media separately. |

Other changed source files: `DirectPilotProfile.swift`, `Keychain.swift`, `Capture/ScreenCapture.swift`,
`Capture/Narration.swift`, `KeboolaClient.swift`, `main.swift`, and Core `BestEffortContract.swift` /
`CaptureStartIntent.swift`. New checks: `macos/Tests/JazzCaptureTests/DirectPilotTests.swift`.
No new contract fields/OTLP keys. Convenience construction added before scope freeze uses existing
validated epoch/envelope models; no new protocol or processor/storage architecture.

The pilot is a separate native owner nested under CaptureController, not the ordinary archive
controller with a renamed bundle. It never constructs EventSpool/archive recovery/delivery owners,
CaptureSetup, legacy connection/renewal, or archive UI. Ordinary capture remains local-first.

## Controls and declared bounds

- Only code-signed bundle ID `dev.jazz.capture.direct-pilot` selects this path. Separate
  `~/.jazz-direct-pilot` metadata and Keychain service; hardware digest, logical device/source,
  explicit app allowlist and out-of-band public signing trust are pinned in its signed Info.plist.
- Signed v2 `bestEffortCapability`, accepted generation, project3044/device/source/expiry and live
  narrow-token verification precede Start. No project-admin token is accepted for capture.
- Explicit Start/Resume only; Pause/Stop/lock/sleep/revocation fence producers and delivery. No
  reconnect/wake auto-start. Physical SCK/encoder/HTTP/preparation owners survive logical cancellation.
-32 units/8MiB transport reservation/1MiB part,2 encoders,2 upload owners/2MiB in-flight bodies.
  One separate media-preparation owner, response capped64KiB. JPEG≤512KiB, dimension≤960, one physical
  SCK request, ≥3s/change-triggered samples. Media bytes never enter OTLP.
- Existing observation/artifact envelopes stay provisional/coverage unknown; media descriptor is
  pending, not fabricated READY. Dropped/unknown/media/PCM counters are visible. No raw keys,
  clipboard, AX text or document-title collection in this minimal pilot.
- Audio code is opt-in through signed-app policy plus granted microphone permission, with bounded
  PCM callback/latest-chunk ownership. **Audio was disabled in the packaged pilot.** No audio design
  or feature scope was expanded after the owner freeze.
- No temporary media files. Intent/acceptance metadata is not a delivery spool.512MiB peak-RSS check
  is a sampled fail-closed tripwire, **not a hard guarantee over private OS/codec allocations**.

## Runnable validation

All six repository contract validators passed. `swift build` passed; full `swift test`:
**906 tests,1 expected skip,0 failures**,35.864s. Focused driver/file/pilot run:26 passed.
Three new tests cover actual pilot refusal without scoped bootstrap, construction of the driver/File
adapter with pilot limits, explicit intent/activation and Pause refusing new Start until physical
encoder return, plus bounded PCM replacement/WAV construction. URLProtocol tests are not real-network
or native permission/capture qualification.

```sh
cd macos
swift build && swift test
swift test --filter 'DirectPilotTests|BestEffortFileAndFenceTests|BestEffortTransportDriverTests'
```

## Provisioning, isolated signed package, and actual smoke

Only direct-ingestion SDK operations were used; no Discovery/managed-app/UI-playback work resumed.
Configured `jazz` project3044 verified. Existing isolated Stream `jazz-qual-fabe8a60bd98` read200 through
configured session authority; endpoint never printed/persisted outside the pilot Keychain.

- Finite own-Files probe token7575632 minted/verified non-master and revoked.
- Real pilot token **7575650** minted with exactly write access to
  `in.c-otlp-jazz-qual-fabe8a60bd98`, no component/admin/read-all-Files grants,15-minute expiry.
- Existing server `DeviceBundleIssuer` signed bundle **`jdb_c538af0d4b4228a606daa4bd628803e9`**,
  generation1, device `jazz-qual-direct-2e5ec2e88f7e`, matching source and five-minute transmission
  capability expiring07:05:08Z. A **fresh pilot-only signing key**, not a fixture/production key,
  was pinned out-of-band into this isolated code-signed app. Private key stayed in memory; no
  production registry/trust/enrollment was changed. This is not production enrollment qualification.
- Signed authority handed to the separate Keychain item through stdin and Security APIs, not argv,
  logs, plaintext credential files or the installed archive app's account. Stored-item status0
  **did not prove that the actual app could read it**.

Installed **`/Applications/Jazz Direct Pilot.app`**, stable `Jazz Dev Code Signing` identity, strict
codesign verification passed. Sourcee670f23; final executable SHA256:
`7005e570d31227bc1d465d2096e32bd7131adea80ad09e7935090277031537c7`.
The archive app was not replaced. This is a signed debug pilot, not a notarized release.

Exact executable `--pilot-preflight` reported Accessibility, Screen Recording and microphone granted
in its **direct-execution launch context**, with no capture/legacy owners. This is not a claim about
persisted TCC rows or every LaunchServices launch context. Idle UI smoke survived3s. A fresh synthetic
TextEdit stimulus was opened; no user archive or historical private media was substituted.

Then AX invoked the actual Start/Resume action on pilot PID75886. The process stalled **before capture**
in `CaptureController.DirectPilot.start → Keychain.get → SecItemCopyMatching`. A one-second process
sample and SecurityAgent's own UI established:

> Jazz Direct Pilot wants to access key “Isolated Jazz pilot device authority” in your keychain.
> To allow this, enter the “login” keychain password.

A secure password field was present. **No password was read, supplied or bypassed.** Deny was invoked;
Start returned to blocked status with ACK0/drop0/media0 (not a zero-loss capture claim). A Stop action
request was accepted by AX, then the non-capturing pilot process was terminated. This is a concrete
blocker on this credential-handoff path, **not proof every valid installation path is impossible**.
The initial TextEdit AppleScript setup also timed out; `open` supplied the bounded stimulus instead.

**Known emitted observation IDs: none. Known uploaded media IDs: none.** No real capture, latency,
control-under-capture or exact media-parity PASS is claimed. SDK provisioning and TCC were available;
the observed failure was Keychain retrieval requiring owner interaction, not a generic Admin/login
or Stream provisioning excuse.

## Cleanup and receipts

At07:09:13Z token7575650 was deleted and absent from token listing; the pilot Keychain item was deleted;
pilot PID exited. Existing Stream retained; no capture Files were uploaded. Signed pilot bundle/public
trust and isolated non-secret metadata retained. No archive app/spools/queues were inspected, changed
or deleted. Fresh authority and a successful legitimate Keychain handoff are needed before another Start.

Receipts/scripts: `/tmp/jazz-continuous-eaa688eb/direct-client-pilot/` (sanitized JSON0600/private root).

| Receipt | SHA256 |
| --- | --- |
| `full-test.log` | `d060414f600f44acebfaacf4cc64329ca93d788df9b07b712668e9f69592f6be` |
| `contracts.log` | `a383c3a6d62ab200d99e36fe4eb59fa180c517b8fd0f1cb594796649ca6a25c6` |
| `authority-installed.json` | `3b538afb7e5d66db0cde90f674fb7c6f7a2cb3dd1c90cbef535b1dec539db361` |
| `smoke-blocker.json` | `44098b6a351aa0807e9b63eac3f3ea88f8608e3be31153e5674d7f71f502b9ed` |
| `final-cleanup.json` | `5f35eb402e50fbc582fdfd85ba1f410c9b6a4aa149a8839f3317cc0d1a2c3cc6` |

Checkpoint current; no terminal-status. Source-only scouting is not independent acceptance; local
checks/signed packaging do not establish live E2E or CI at a later publication commit.
