# Continuous capture M2c — local disk admission reserve

Baseline `5699bef`, branch `feat/company-recording-policy`. **Scoped code accepted after
fresh review and repair round 1/3. Not full M1/M2 or native qualification.**
No deployment, installed-app changes, native capture, credentials, schema changes or delivery-authority changes.

## Scoped implementation

- Settings → Capture exposes `localDiskReserveBytes.v1` as positive decimal byte text.
  An absent setting uses **2,147,483,648 bytes (2 GiB), an initial engineering default only**,
  not a demonstrated sufficient production threshold. Malformed types/text, zero, negative,
  fractional and overflowing values block capture instead of disabling the reserve or falling back.
- Foundation-only `CaptureDiskReserve` validates reserve + known immediate write size with checked
  Int64 arithmetic. Exact equality admits. Missing/negative capacity and stale/future/nonfinite
  samples fail closed. Maximum sample age is three seconds; this is not a cache refresh allowance.
- Executable `CaptureVolumeCapacity` queries fresh `volumeAvailableCapacity`, not the larger
  important-usage/purgeable estimate. It resolves the actual archive/spool destination volume,
  including symlinked roots. A not-yet-created destination uses its nearest existing directory;
  dangling links, non-directory ancestors and native I/O/permission failures do not authorize capture.
  No directory inventory, hashing, usage rebuilding, quota cleanup or eviction is added.
  Existing archives, receipts, staging, journals and queue duplication already consume OS capacity.
- The controller uses `CaptureResourceAdmission` before requesting Start intent, after recovery,
  immediately before archive begin, and through its existing source eligibility predicate (including
  screenshot/native-result gates, label admission/reopening and both narration admission checks).
  The existing three-second capability timer also checks during quiet active capture and label drain.
  It checks archive/spool roots plus enabled compatibility/Coach spool destinations separately;
  capacity on another volume cannot compensate for a full archive volume.
- A failure latches and revokes the existing **environment** gate: synchronous physical source fences
  then the M2b2 five-second bounded retained local close. It is not user Pause, confirmation or
  automatic Resume. A successful explicit disk retry still needs current OS/user acknowledgment;
  persisted Pause, recovery-required and the unqualified unattended-startup gate remain independent.
  Low/native-error/configuration/stale reasons are visible in capture status and `lastError`.
- The controller's actual `runtime.submit` wrapper checks already-produced artifact byte length
  immediately after the producer returns. Screenshot bytes and sealed-file copy sizes are known
  without rehashing. On pressure it passes the **unchanged outcome** into existing journal durability
  rather than discarding the artifact. Already-admitted drain/close may consume reserve. Previously
  fenced native results still use M2b2's existing unavailable-quality/gap behavior, not fabricated
  successful pixels. ENOSPC/persistence errors retain existing recovery-required semantics and claims.
- No reserve is an OS reservation: concurrent writers, uploads and external fill can still exhaust
  capacity after a check. Canonical journals/archives, narration claims and immutable delivery bytes
  are never evicted by this feature. No finalizer/enqueue call was added; explicit archive-level
  confirmation remains mandatory. M1 producer ceilings/pruning are untouched.

## Checks and evidence

Raw artifacts: `/tmp/jazz-continuous-eaa688eb/m2c/` (outside Git).

| Check | Result / artifact |
| --- | --- |
| First focused implementation run | `resource-tests-first.log`: native dangling-link probe incorrectly succeeded; also three test-setup assertions lacked recovery readiness. Not a pre-`5699bef` regression run. |
| Fixed native probe and corrected test setup | `resource-tests-after.log`: 11 selected tests, zero failures, including existing sealed-media recovery with new ENOSPC fault. |
| All six unchanged AGENTS validators/generators | Exit 0 each; exact commands/exits in `command-exits.txt` and runnable `run-validation.sh`. |
| `cd macos && swift build && swift test` | Both exit 0; `swift-build.log`, `swift-test.log`: **804 tests, one expected live-OTLP skip, zero failures**. |
| Whitespace/index and reviewer bundle | `git-check.log`, `phase.diff` against `5699bef` **including new files**, `changed-files.txt`, `diff-stat.txt`. No staged files or Git/index mutations. |

Ten new tests cover thresholds/configuration/overflow/unknown/negative/stale samples, fresh final
checks across multiple destinations, initial and post-recovery denial without archive/claim/native
admission, active/label/draining-label revocation and bounded local close, original byte preservation,
explicit retry versus Pause/OS acknowledgment, known screenshot/sealed-copy sizes and native path probing.
Tests drive the production resource/environment/intent/source/label/local-close seams with fake capacity,
synthetic media and temporary roots, **not a full controller/TCC session**. Native probe tests only read
volume metadata under temporary paths; no disk is filled or volume mounted. Active-close sentinels are
synthetic originals, not purported AAC/ZIP fixtures. The existing journal recovery test additionally
injects POSIX ENOSPC at blob durability, retains the sealed sole source, reports recovery-required and
replays it exactly once after recovery. Existing full-suite confirmation/rejection/retry tests continue
to prove no package/network intent before explicit confirmation and exact immutable bytes across retries.

## Review, repair and parent acceptance

Fresh reviewer `3b451340` found one policy-switching defect: initial/post-recovery admission used
previous capture destinations before reading the new delivery policy. Parent was the sole repair
writer: freeze the prospective policy after ownership guards, before the first disk check or await;
remove the later Settings re-read. Running captures keep their existing snapshot. Extract unchanged
path selection into the production resource seam and test compatibility → confirmed archive →
compatibility with both low and unavailable compatibility-only destinations. Local-only retry succeeds;
compatibility retries fail. This is not native controller initialization or a before-fix reproduction.

Fresh repair reviewer `66663b05` returned **PASS**, no further finding. Parent reran all six required
checks plus build/test: **805 executed, one expected live-OTLP skip, zero failures**; targeted
policy-transition test and `git diff --check` pass. Artifacts: `review-0.md`, `repair-1.md`,
`repair-delta.diff`, `repair-regression.log`, `repair-review-1.md`, `parent-repair-validation.log`.

Budget: writer `ff37615e` 106,855 input + 28,701 output = 135,556; review `3b451340`
57,635 + 3,525 = 61,160; parent repair adds no child-run debit; fresh review `66663b05`
34,809 + 1,452 = 36,261. Including prior 1,361,518: **1,594,495 / 1,600,000 child input/output
tokens used; 5,505 remain**, insufficient for another substantial writer/review cycle.
Native zero accounting is not authoritative. Parent accepts this code for commit/push only;
mission checkpointed, not complete. Next work needs additional budget and remains gated below.

## Remaining gates

Real-Mac available-space
semantics (APFS/container quotas, mounts), synchronous native query cost/latency, timer/physical-stop
latency, external fill/ENOSPC behavior and reserve tuning remain unqualified. Probes are point-in-time
and the MainActor timer is best effort, not a hard OS interruption guarantee. The two-GiB default must
be measured under sustained/overnight/multi-day workloads; it does not complete M1/M2 acceptance.
No automatic/company policy, unattended OS eligibility, M3/M4, splitting or installed-app rollout is enabled.
