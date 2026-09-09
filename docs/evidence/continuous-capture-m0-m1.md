# M0/M1 implementation checkpoint

Mission: `eaa688eb-49f0-4b14-a71f-c4c9cc18b8fd`.
Worktree: `/Users/maziak/Devel/acl/jazz-desktop-continuous-capture`.
Seed: `5be5a7b`. Writer: `48467916` (sole writer, terminated by the harness's
30-minute default timeout before final handoff). Changes are preserved and uncommitted.
Parent recovered this checkpoint. Review 0 requested two claim-integrity repairs;
repair round 1 passed fresh review. See final checkpoint below; full M1 remains incomplete.

## Scope and current result

Partial M1 progress, not M1 completion or unattended-capture readiness:

- Claimed/recording media is no longer discarded merely because sealing, admission,
  or persistence failed. Invalid/unsealed claims remain discoverable and block commit.
- Sealed artifact ingest records retry metadata in journal WAL; recovery can replay
  the intent and publish the associated observation exactly once.
- Journal ownership uses the existing filesystem lease abstraction, a native
  `.capture-writer.lock`, revocation and active producer/operation accounting.
- Runtime close has an explicit bounded committed/recovery-required outcome. Its
  timeout retains exclusive ownership while non-cooperative writes remain possible.
- Runtime prunes completed task handles and applies an outstanding-work ceiling.
- Draft recovery distinguishes an absent artifact document from a corrupt/missing
  artifact blob instead of silently converting every read error into missing evidence.

These descriptions are implementation claims awaiting independent adversarial review.
The parent spot-checked the runtime, journal, file-claim and controller diffs.

## Before/after evidence

Logs are local, outside Git, under `/tmp/jazz-continuous-eaa688eb/`.

| Check | Result | Evidence |
| --- | --- | --- |
| Original baseline: six AGENTS validators/checks, Swift build/test | Writer reported pass; 732 tests executed, 1 skipped, 0 failures | `baseline.log` |
| Media abandonment retains sole source | Failed before fix: expected 14 bytes, got no file | `regression-before.log`, `testAbandonedRecordingRetainsSoleSourceBytes` |
| Invalid sealed claim retained rather than accepted/deleted | Failed before fix | `regression-before.log`, `testChangedSealedClaimFailsWithoutPublishingArtifact` |
| Completed producer handles pruned | Failed before fix: 20 retained vs 0 expected | `regression-before.log`, `testCompletedProducerHandlesArePruned` |
| Worker pre-handoff full Swift run | 742 tests executed, 1 skipped, 0 failures | `pre-final.log` |
| Parent full validation of recovered current diff | Exit 0; all six checks and Swift build/test passed; 742 executed, 1 skipped, 0 failures | `parent-recovered-validation.log`, 2026-09-09 |
| Parent `git diff --check` | Exit 0 | Recovered diff check |

The parent reran, in order:

```bash
uv run --script contract/validate_schemas.py
uv run --script contract/archive/validate_archives.py
uv run --script contract/live/validate_live_transport.py
uv run --script contract/live/validate_capture_coach_live.py
uv run --script contract/live/generate_capture_coach_fixtures.py --check
uv run --script contract/archive/container/generate_fixtures.py --check
cd macos && swift build && swift test
```

New/extended checks also cover sealed-media retry, runtime close timeout with a
non-cooperative producer/filesystem write, recovery exclusion while leased, native
lease release, outstanding-work ceiling, seal-sync failure retention, projection
independence, and process-kill recovery. Tests do not replace physical Mac qualification.

## Explicit remaining gates

1. Unsealed, seal-before-intent and admission-failed claims lack durable pre-recording
   modality/interval metadata. They are retained, not automatically reintegrated.
   Add trustworthy pre-recording metadata ownership in the controller integration;
   do not invent timestamps or modality claims from filename/content guesses.
2. Controller Stop still waits on admission/Coach/producer tails before invoking the
   bounded runtime close. Full Stop is not yet bounded. M2 must integrate deadlines,
   startup/Pause intent, physical resource fences and recovery ownership.
3. Disk-capacity checks and actual emergency-close reserve enforcement are not done.
   Parent authorizes the plan's configurable 2 GiB as the initial engineering default
   for later resource integration, subject to measured real-Mac qualification. This
   does not authorize deleting retained evidence or require a new preallocation service.
4. M0 Pause-during-start and late physical screenshot reproductions remain pending M2.
5. No fresh review, real-Mac qualification, automatic-upload authorization migration,
   commit/push/merge/deploy or acceptance of the full milestone has occurred for this diff.

The worker asked to extend scope versus checkpoint. Parent selected safe partial
handoff and deferred pre-recording metadata to the controller slice without marking
those M1 requirements complete. Next: independent review of the partial diff, repair
concrete defects (maximum three rounds), then integrate the remaining M1/M2 work.

## Budget recovery

The detached timeout left the mission's native usage display at zero. Parent summed
assistant usage records from the writer's retained session: **126,920 input + 31,414
output = 158,334 budgeted tokens**. The harness's usage-budget implementation counts
input plus output, excluding cache reads. Cache reads were separately 3,729,024 tokens;
provider total including cache was 3,887,358. Do not double-count reasoning tokens.
Charge the recovered 158,334 against the 400,000 goal: **241,666 remain** before review.
This recovered debit must be retained in mission state even if native accounting has
not reconciled the detached run.

## M1 repair round 1

2026-09-09; round **1 of maximum 3**. Review input:
`/tmp/jazz-continuous-eaa688eb/recovered-review-0.json`. Scope: the two high-severity
claim-integrity defects only. No controller/UI/OS policy, contract, confirmation,
delivery or upload changes. All test bytes are synthetic; no real recordings,
secrets, live API, Git mutations, installation or deployment.

### Repairs and adversarial checks

- Decoded claimed-file descriptors now pass one shared root/archive/capture/artifact
  ownership, sealed-name, no-symlink claim-directory and snapshot/hash validator at
  both draft-store ingest boundaries and the journal boundary. Decoding is explicitly
  documented as insufficient authority. Existing before/after hashing and copy checks
  are preserved.
- WAL pending-to-resolved updates must preserve the exact optional ingest intent,
  including retaining nil for legacy byte-only writes. In-memory retries cannot replace
  a sealed intent with different bytes or add an intent to an already resolved entry.
- Persisted pending and resolved intents bind artifact/capture identity and claim
  hash/length; resolved hash/length/metadata must match the intent. Recovery verifies
  every retained resolved claim against the exact published artifact and verified blob
  before checkpoint/commit/deletion. A mismatched claim or unpublished artifact fails
  closed, leaving sole-source bytes and the working state intact.
- Four new tests in `CaptureJournalTests.swift` cover decoded foreign regular files,
  foreign roots/captures/artifacts, unsealed names, symlink ancestors/traversal (plus
  valid public ingest); replacement/dropping of WAL intent; checkpoint claim, identity,
  hash, length, metadata and internally consistent substitution; absent artifact,
  missing/corrupt blobs; successful exact-match cleanup; and cross-payload retry after
  publication failure. Existing sealed retry, legacy pending metadata, lease, runtime
  and process-kill tests remain passing.

Pre-edit snapshot: `/tmp/jazz-continuous-eaa688eb/repair-round-1-before/`
(`Sources/`, `Tests/`, and the two evidence/ledger documents).
Repair-only diff, including new tests, against that snapshot (not against the M1 seed):
`/tmp/jazz-continuous-eaa688eb/repair-round-1.diff`.
Handoff: `/tmp/jazz-continuous-eaa688eb/repair-round-1.md`.

### Commands and results

All log paths below are relative to `/tmp/jazz-continuous-eaa688eb/`.

Before source changes, exit 1 as expected: **3 tests, 55 assertion failures, zero
unexpected failures**. Foreign descriptors were accepted, tampered resolutions were
accepted and substituted sole-source bytes were deleted. Log:
`repair-round-1-before-tests.log`.

```bash
cd macos && swift test --filter 'CaptureJournalTests.testPublicDraftIngestRejectsDecodedUnownedClaims|CaptureJournalTests.testRecoveryRejectsTamperedArtifactResolutionWAL|CaptureJournalTests.testRecoveryBindsCheckpointIntentToPublishedArtifactBeforeDeletingClaim'
```

Final adversarial run, exit 0: **4 tests, zero failures**;
`repair-round-1-after-tests.log`.

```bash
cd macos && swift test --filter 'CaptureJournalTests.testPublicDraftIngestRejectsDecodedUnownedClaims|CaptureJournalTests.testRecoveryRejectsTamperedArtifactResolutionWAL|CaptureJournalTests.testRecoveryBindsCheckpointIntentToPublishedArtifactBeforeDeletingClaim|CaptureJournalTests.testArtifactRetryCannotReplaceClaimIntentWithDifferentBytes'
```

Final targeted run, exit 0: **175 tests, zero failures**;
`repair-round-1-targeted.log`.

```bash
cd macos && swift test --filter 'CaptureJournal|JazzArchive'
```

Intermediate targeted runs exposed a test-helper compile error (missing `.value()`)
and an over-strict pending-metadata check incompatible with legacy reservations; both
were corrected before final validation. Logs:
`repair-round-1-targeted-compile-failure.log` and
`repair-round-1-targeted-compatibility-failure.log`. Additional traversal check passed
before the final canonical-path tightening:
`cd macos && swift test --filter CaptureJournalTests.testPublicDraftIngestRejectsDecodedUnownedClaims`
(exit 0, one test; `repair-round-1-traversal-before.log`). No remaining test regression.

Final full verification, all commands exit 0; `repair-round-1-full-validation.log`:

```bash
uv run --script contract/validate_schemas.py
uv run --script contract/archive/validate_archives.py
uv run --script contract/live/validate_live_transport.py
uv run --script contract/live/validate_capture_coach_live.py
uv run --script contract/live/generate_capture_coach_fixtures.py --check
uv run --script contract/archive/container/generate_fixtures.py --check
cd macos && swift build && swift test
```

**746 Swift tests executed, 1 skipped, 0 failures**. The expected skip is
`LiveOtlpTests.testPostsSessionSpanAndCorrelatedLogs` because
`JAZZ_LIVE_OTLP_ENDPOINT` is unset; no live endpoint was configured.
`git diff --check` passed; `git diff --cached --name-only` returned no entries
(exit 0), confirming no staged files; see `repair-round-1-git-check.log`.

### Remaining acceptance gates and budget

Fresh review `121cf3e0` passed the partial changes after repair round 1 with no blocking
findings. This does not complete M1 or authorize deployment.
Unsealed/pre-intent/admission-failed claims remain retained, not auto-reintegrated;
trustworthy modality/interval metadata remains deferred to M2. Controller close/start/
Pause serialization and physical privacy/resource fences, disk capacity/emergency
reserve enforcement, startup race reproductions and real-Mac/sustained capture
qualification remain incomplete. Automatic-upload authority/client-server migration
remains blocked; explicit archive-level confirmation is unchanged.

Recovered cumulative budget debit **before this run: 251,130 / 400,000 input/output
tokens; 148,870 remaining**. This supersedes the earlier 158,334 writer-only subtotal,
not an additional debit on top of 251,130. Native zero is misleading. This run's measured
usage is reconciled in the parent checkpoint below.

## Parent acceptance and budget checkpoint

- Repair writer `076b7bc9`: 75,360 input + 21,681 output = **97,041**.
- Fresh reviewer `121cf3e0`: 39,465 input + 2,125 output = **41,590**.
- Prior detached debits: **251,130**. Total: **389,761 / 400,000**; remaining **10,239**.
- Reviewer verdict: **pass for safe partial M1**, no blocking findings. Original
  review found two high-severity defects; both passed four adversarial tests after
  one repair round. Optional checkpoint-intent-drop coverage is a nonblocking test
  improvement; full controller/resource/real-Mac gates remain open.
- Parent inspected the repaired ownership, WAL/checkpoint binding and publication-bound
  deletion paths, and reran the full six checks plus Swift build/tests on 2026-09-09:
  **exit 0, 746 executed, one live-OTLP skip, zero failures**. Log:
  `/tmp/jazz-continuous-eaa688eb/parent-final-partial-m1-validation.log`.
- The reviewer had read/search tools only. Its acceptance is independent static review
  and test-code inspection; runtime validation was executed by writer and parent.
- No new recording behavior or automatic-upload authority is deployed. Remaining M1
  metadata/resource and M2–M8 criteria are not waived.

This is the last safe review boundary within the allocated budget: do not launch a
substantial M2 implementation plus fresh review on the remaining 10,239 tokens.
Mission is paused, not closed. Next ready action after sufficient additional budget:
implement controller-owned pre-recording metadata, serialized Stop/Pause/start/recovery,
physical privacy fencing and disk-reserve integration, then fresh review (maximum three
repair rounds). Automatic delivery still has the explicit governing-rule/ADR gate.

Review output: `/tmp/jazz-continuous-eaa688eb/repair-review-1.json`.
Implementation and review workflow: `c5f9bd9b-2356-4d37-b35e-0aa71008582f`.

