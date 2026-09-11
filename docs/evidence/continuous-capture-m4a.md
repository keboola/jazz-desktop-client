# M4a — Review-only deployment/setup readiness

Status: **scoped code accepted after repair 1/3**, addressing review-0's three P1 findings.
Fresh repair reviewer `d5640c5e` passed; parent validation/acceptance recorded below.
Baseline: `2bca2ff`, branch `feat/company-recording-policy`. No commit, push, deployment,
installed-app run, enrollment/API call or Git/index mutation performed by the writer.

## Implemented boundary

- `CaptureSetupReadiness` is a Foundation-only, injected input/durable-store admission seam,
  not another lifecycle owner. `CaptureController.requestStart`, preparation and physical source
  admission use it; synchronous settings/enrollment transition notifications revoke the existing
  environment/intent before awaiting work. External configuration/trust changes are also checked
  through current inputs and the application timer. M2 physical, disk and bounded-close fences stay.
- Settings and first launch/upgrade share one recording/upload readiness section: company/Area,
  destination, requested mode, actual review-required archive delivery, modalities, permission
  remedies and unavailable automatic company upload. Legacy liveCompatibility is explicitly
  distinguished as live projection before archive review, not silently relabeled review-only.
- Signed status requires the existing atomic Keychain tuple, matching replay-acceptance record and
  code-signed issuer/audience. Preferences or a successful connection/health result alone do not
  establish cryptographic trust. Pending/expired/unverified and explicit MVP handoff remain distinct.
  New successful sealed redemption plus signed import records local device-bound provenance;
  historical signed installs do not invent that missing activation evidence.
- Independent `capture-setup.json` retains notice receipts, invalidation and managed/enrolled
  history. A failed durable write retains its pending marker and blocks reopening. Changing then
  reverting material configuration cannot revive the old receipt. UI acknowledgment is bound to
  the displayed snapshot, not a newer unseen setup. No per-chunk consent/confirmation is minted.
- Native forced restrictions can only narrow modes/modalities and require enrollment/review.
  Unknown/malformed/permissive values block. Removed profiles retain a durable restriction history;
  forced controls are locked. An explicitly chosen never-managed/enrolled local-only setup works
  offline without acquiring network authority. Workshops cannot expand acknowledged modalities.
- Ordinary same-authority credential renewal does not revoke capture or renew the notice. Existing
  credential storage/renewal protocol and immutable delivery/confirmation queues remain unchanged.

Deployment keys, storage-repair constraints and boundaries are documented in `macos/README.md`.
This is **not** the proposed company-policy-JWS API, format-2 delivery or all M4 integration.
ADR 0005 remains PROPOSED; governing confirmation-only rules and interactive-only OS gate remain.

## Repair round 1 — three reviewed P1 defects

- Local-only may always be switched OFF when already selected, so newly enrolled/managed setup
  can complete. The real Toggle enablement/published binding still refuses turning it ON once
  requirements have been observed.
- `SettingsStore` now refreshes every notice-bound mirror (mode, modalities, identity, exclusions,
  delivery and local-only) from the exact acknowledgment snapshot, with preference writeback
  suppressed. Forced-key removal exposes the underlying local preference without stale controls
  or destructive refresh writes. User edits continue to persist normally.
- Evidence read failure is explicitly unavailable/unknown and blocks capture, including local-only,
  without manufacturing enrollment history. Positive observations made before a later read failure
  and genuine persisted managed/enrolled history remain conservative. Company/destination are
  shown as unknown while evidence is unavailable, not falsely unassigned.

Six additional tests exercise actual `SettingsStore` refresh/Toggle binding and
`CaptureSetupEnrollment.current` read/error resolution with injected boundaries. Before the fixes,
with only dependency injection and the existing toggle predicate extracted, four regression cases
failed (40 assertions); the two history/positive-observation controls already passed. After repair,
all six pass. This is not an installed SwiftUI/MDM/TCC test: managed overlays are a temporary
`UserDefaults` subclass, permission/credential/evidence reads are fakes, and no native sources run.

Pre-repair source snapshots, complete phase diff and original test logs are retained under
`repair-1-before/`. `repair-delta.diff` contains only this repair, tests and affected documentation;
`phase.diff` is refreshed against `2bca2ff`, including new files. No lifecycle, archive queue,
credential-renewal/storage protocol, policy authority or interactive-only OS gate was changed.

## Verification

Artifacts: `/tmp/jazz-continuous-eaa688eb/m4a/`.

| Check | Result / artifact |
| --- | --- |
| Six unchanged AGENTS validators/generators | Exit 0 each; `repair-1-run-validation.sh`, `repair-1-command-exits.txt`, `repair-1-*.log` |
| `cd macos && swift build && swift test` | Exit 0; **832 tests, one expected live-OTLP skip, zero failures**; `repair-1-swift-build.log`, `repair-1-swift-test.log` |
| Focused readiness/intent/resource/physical/label/close/workshop regression filter | **69 tests, zero failures**; `repair-1-focused-tests.log` |
| New setup tests | **27 tests** in `CaptureSetupReadinessTests.swift`, `CaptureSetupTests.swift` and `SettingsStoreTests.swift` |
| Repair regressions before/after | `repair-1-regression-before.log`: 6 tests, 40 failing assertions; `repair-1-regression-after.log`: 6 tests, zero failures |
| Whitespace/index check | `git diff --check` passes; no staged files |
| Reviewer inventory | `phase.diff` against baseline includes new files; `changed-files.txt`, `phase-stat.txt` |

Tests exercise clean install/continuous upgrade without receipts; acknowledged relaunch and Pause;
missing permissions; signed versus pending/expired/unverified/MVP evidence; identity/destination/
mode/modality/notice changes; stale displayed notice; corrupt/failed stores and pending-write reopen;
managed malformed/removal/history; offline local-only; workshops; same-authority renewal; and the
actual requestStart/runStart/post-await admission seams with settings-change and trust-change races.
Temporary preferences/files and fake permission/enrollment/source boundaries only: no real user
settings, recordings, Keychain, native capture or session-lock experiments. Initial implementation
build caught two adapter typing/name mistakes; initial new tests caught invalid synthetic test URLs;
those were corrected before the passing checks above (early logs retained).

## Parent acceptance and accounting

Fresh repair reviewer `d5640c5e-d7df-40cb-a9d9-7dd41788da67` returned **PASS**, no further
findings. Parent inspected Settings snapshot synchronization/acknowledgment and reran all six
required contract checks plus build/test: **832 tests, one expected live skip, zero failures**.
`git diff --check` passed. Log: `parent-repair-validation.log`; review: `repair-review-1.md`.
Acceptance covers reviewed code, not full M4 or native/deployment qualification.

Initial writer/review workflow `c84bf9e8-0748-4e5a-8b84-a041918b0fe1` reported
225,564 input + 48,186 output = **273,750** tokens. Repair/fresh-review workflow
`e4e8834a-1966-4816-8750-ae12420219fa` reported 243,846 + 20,633 = **264,479**.
Including prior 1,825,456: **2,363,685 / 3,200,000 used; 836,315 remain** before M5.
Next: parent commit/push, then review-required time/size segmentation; no automatic activation.

## Remaining gates

- Release/deployment approval remains gated on the qualification below.
- Installed first-run/upgrade and native MDM forced-preference delivery/removal qualification.
- Signed-app Secure Enclave/TCC behavior, OS-unlocked authority, physical stop/start races and
  sustained capture. Fresh synchronous Keychain/acceptance-ledger admission latency is unqualified;
  unit tests do not prove native stop latency or safe unattended startup.
- Existing acceptance/provenance is not fresh JWS verification, hardware attestation, or a new
  server revocation/policy channel. No absent future signed-policy API is inferred.
- Full approved company-policy integration and automatic delivery still depend on M3/M6/M7;
  login registration, rotations and native unattended authority remain separate work.
