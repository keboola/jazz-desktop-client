# Continuous capture M3 — proposed company recording policy

Baseline `afa0104baea5c56d63c3c84b5a89ad93e46a783f`, branch
`feat/company-recording-policy`. **Proposed document accepted after fresh repair review;
governing activation approval remains pending.** This retry started clean; the preceding M3 writer did not launch or
change files. No automatic activation, source behavior, wire contract, finalizer, queue,
accepted ADR or AGENTS rule is changed.

## Proposal versus implementation versus approval

- [ADR 0005](../adr/0005-company-recording-policy.md), **PROPOSED**, selects independent
  recording/upload modes and a separate policy JWS reusing enrollment trust. It specifies
  company-admin authority, exact scope/generation/expiry rules, start snapshots, external
  immutable archive authorization, fresh attempt checks, format-2 negotiation, grant and
  transactional publication fences, and genuine human revision of held sealed archives.
- Proposed API names, payload fields, durations and illustrative decision vectors are
  **not shipped APIs, valid signatures or executable conformance fixtures**. Only syntax/
  reference checks were added as temporary review tooling; existing production tests ran
  unchanged. The document explicitly lists future coordinated schema/golden/Swift/processor
  work; neither automatic delivery nor server policy administration is implemented here.
- The governing activation decision remains unresolved. AGENTS and accepted ADR 0003 still
  require archive-level human confirmation. ADR 0004 owns device-bound enrollment, not
  OS-unlocked authority. Document publication/review does not grant company activation,
  unattended recording, full M1/M2 acceptance or native/sustained qualification.

The [plan](../continuous-capture-plan.md) now reconciles stale lower M2 checklist text
with already accepted evidence: M2b2 repair review `0e2ff636`, M2c repair review `66663b05`,
and **805 tests, one expected live-OTLP skip, zero failures**. These are scoped acceptances,
not new M3 safety implementation. M3 draft items are checked as specification only;
proposal review passed after repair round 1; governing approval stays open. The next useful M4 slice is review-only enrollment/setup
readiness, notice/destination/trust display and persisted readiness independent of Pause.
Automatic upload, login registration and unattended OS authority are separate gates.

## Grounding and checks

Bounded reads covered AGENTS; ADRs 0001–0004; plan M3/M4 and accepted M2 evidence;
`CaptureController.prepareCapture`; signed enrollment trust/verifier/acceptance;
`JazzArchiveFinalizer` inventory/manifest/ZIP ordering; `enqueueConfirmed` and immutable
upload route/operation semantics; revision forking and shared archive schemas. Optional
server checkout `/Users/maziak/Devel/acl/jazz-remove-mvp-badge` was **read-only**: HTTP
intent/finalize payloads, worker confirmation checks in both verification/import, and
Postgres `publish_ready`/outbox transaction seams. No server files, live requests or
credentials were used. In particular, the finalizer's low-level optional confirmation
guard is not a delivery permission, and an embedded signed policy cannot hash its own ZIP.

Artifacts, all outside Git: `/tmp/jazz-continuous-eaa688eb/m3/`.

| Validation | Result / artifact |
| --- | --- |
| `uv run --script contract/validate_schemas.py` | Exit 0, `schemas.log`. |
| `uv run --script contract/archive/validate_archives.py` | Exit 0, `archives.log`. |
| `uv run --script contract/live/validate_live_transport.py` | Exit 0, `live-transport.log`. |
| `uv run --script contract/live/validate_capture_coach_live.py` | Exit 0, `capture-coach-live.log`. |
| `uv run --script contract/live/generate_capture_coach_fixtures.py --check` | Exit 0, `coach-fixtures.log`. |
| `uv run --script contract/archive/container/generate_fixtures.py --check` | Exit 0, `container-fixtures.log`. |
| `cd macos && swift build && swift test` | Both exit 0, `swift-build.log`, `swift-test.log`: **805 tests, one expected live-OTLP skip, zero failures**. |
| Python stdlib document check | `check-docs.py`, `docs-check.log`: local Markdown links/anchors, JSON payload syntax/field/time/digest constraints and documentation-only scope; no signature/API validation claim. |
| Whitespace/index and reviewer bundle | `git-check.log`; `phase.diff` against `afa0104` includes both new documents; `changed-files.txt`, `diff-stat.txt`. No staged files. |

Exact validator/build/test exits and rerunnable driver: `command-exits.txt`,
`run-validation.sh`. Reviewer must evaluate proposal semantics independently; green
unchanged production tests cannot validate an unimplemented authorization protocol.
No native user-session tests, real recordings, installed-app changes, deployment,
Git/index mutation, commit, push, nested agent or new dependency was used.

## Residual gates and accounting

Fresh M3 proposal review passed; explicit governing approval remains outstanding. Daily policy renewal
advances generation and deliberately holds old automatic work; 60-second grants cannot
recall transmitted bytes or bound completion of an already admitted provider PUT.
Generation/READY serialization must be implemented in every server store/recovery path
before capability advertisement. No native OS eligibility or sustained/resource threshold
qualification is claimed. Human transmission authorization is not evidence/business review.

**Before M3:** 3,200,000 authorized tokens; 1,594,495 used; 1,605,505 remaining.
These preserve accepted prior accounting. M3 writer/initial review workflow
`55fa6e54-c04d-4c8f-a41a-3e21a04a06d7` used 179,735 input + 31,137 output = 210,872.
Fresh repair review `e18431ab-fa6c-45e4-8ee1-19835e0c98e5` used 19,088 + 1,001 = 20,089.
Post-phase: **1,825,456 / 3,200,000 used; 1,374,544 remain**. Parent repair adds no child debit.

## Repair 1 and scoped publication acceptance

Initial reviewer `33a16b20-094a-4ce2-ba1d-b13cc8ed2925` found a stranded held-operation
case and an illustrative project ID outside enrollment grammar. Parent repaired only the
proposal: operation-ID-bound reconciliation can durably fence publication while held,
without requiring an ingest ID, current automatic policy or a payload grant. It returns
historical READY or terminal nonpublication, and uses tombstones to reject delayed intents
and same-archive automatic operation replacement. Added policy-change/lost-response/race
vectors and mirrored the transition in revision/migration requirements. Project ID is now
synthetic numeric `999999`; the temporary checker uses the actual enrollment schema regex.

Fresh repair review **PASS**, no remaining proposal-publication findings. This is not
protocol implementation/approval. Parent reran the document checks, all six validators
and `swift build && swift test`: **805 tests, one skip, zero failures**, all commands exit 0;
`git diff --check` passes. Artifacts: `repair-delta.diff`, `repair-docs-check.log`,
`repair-review-1.md`, `parent-repair-validation.log`. Next: publish the PROPOSED document,
then implement M4 review-only setup/readiness while automatic activation stays blocked.
