# Continuous capture — authority/native qualification checkpoint

Historical checkpoint. Work resumed with another 1,500,000 tokens (4,700,000 total) and the
user's main-agent-only instruction. See [M5b1](continuous-capture-m5b1.md) for subsequent idle-close
work and main-agent accounting. The authority/native gates below remain open.

Mission `eaa688eb-49f0-4b14-a71f-c4c9cc18b8fd` is **not complete**. Accepted desktop code is
`8dfcb76` on `feat/company-recording-policy`, draft PR #35 stacked on #33. Nothing from this
mission has been installed into `/Applications/Jazz Capture.app` or enabled for unattended use.

## Delivered and verified

M1/M2 scoped durability, narration recovery, intent, physical fences and disk reserve; M3 proposed
ADR only; M4a review-only setup; M5a time/size splitting. See their individual evidence notes.
M5a's workshop repair passed fresh review `055eb816`; parent six contract checks/build/test passed
**848 tests, one expected live-OTLP skip, zero failures**. Labels/narration/workshops stop at limits,
not automatically continue. Byte thresholds remain sampled engineering targets, not exact caps.

Server PR #352's six PostgreSQL CI failures were reproduced and repaired in test-only commit
`2e071cb0e0f3cd8ab318aa3bb3e36dbdbd39c355`. Default fake authority validity follows its injected
decision clock; explicit expiry and production validation remain unchanged. Fresh reviewer
`f15c8472` passed. Writer full backend: **5382 passed, seven skipped**. Parent independent private
PostgreSQL 16 run: **56 passed, no skips**, plus static checks and 30/30 schemas.

Parent initially named a nonexistent sync test file, so that invocation ran no tests; a conditional
shell group masked the failure while later static checks passed. The corrected command was rerun
successfully on the pushed, unchanged file with explicit exit-code checking. Both logs are retained;
the initial invocation is not counted as successful validation. All disposable clusters were stopped.

Exact-head server CI is **green** (schema, backend, frontend):
https://github.com/keboola/jazz/actions/runs/34386491966
PR #352 still requires repository review; no merge or deployment occurred.

Desktop CI permits manual branch dispatch despite the stacked PR's non-main base. Parent requests
that matrix after this checkpoint commit and records the exact revision/result on PR #35; local
tests are not a substitute for that remote receipt.

## Four-mode readiness and blockers

| Requested combination | Current state |
| --- | --- |
| Manual + human approval | Scoped code implemented/reviewed; signed-app native qualification not passed. |
| Continuous + human approval | Explicit initial Resume and time/size rotation implemented/reviewed; automatic idle/activity/launch/wake eligibility and sustained qualification remain open. |
| Manual + automatic upload | Not implemented/activated: governing confirmation-only authorization still binds. |
| Continuous + automatic upload | Same authorization blocker, plus continuous native eligibility/qualification above. |

1. **Authorization:** ADR 0005 is PROPOSED, not an approved replacement for AGENTS/ADR 0003.
   M6/M7 need the coordinated governing decision, schemas/fixtures/client/processor changes,
   server-first migration, capability/authority verification and per-company activation. No synthetic
   confirmation, legacy bypass or retroactive backlog release is permitted.
2. **Native qualification:** public console/login and workspace hints do not prove unlocked state.
   Current interactive acknowledgment remains mandatory at launch/after suspension. Qualify the
   signed installed app, TCC/MDM/Keychain, real lock/sleep/user switching/displays/audio, stop latency,
   disk pressure and overnight/multi-day behavior in a controlled pilot that preserves recordings.
   M5b idle/activity automatic resumption stays gated; simulated tests do not clear this gate.
3. **Release:** PR #33 and server #352 require repository approval; PR #35 remains draft.
   Final authenticated archive list/detail/media and scope checks must cover the eventual deployed
   revision. Previous production checks do not qualify these new desktop changes.

The next unblock is the governing authorization decision and a controlled native pilot—not more
tokens alone. Keep the mission checkpointed rather than inventing authority or claiming four-mode
completion. No real recording, package, journal, credentials or installed settings were modified by
qualification attempts in this slice.

## Accounting and retained evidence

Server repair/review workflow `cc8b5d40-f0af-4f87-abbc-e0ef576d87e6` reported **151775 input +
12942 output = 164717** tokens. Added to prior 2831426: **2996143 / 3200000 used; 203857 remain**.
This is child input/output excluding cache reads, retaining all previously recovered detached usage.
Parent-only verification/documentation adds no child debit. Budget exhaustion is NOT the blocker.

Scratch: `/tmp/jazz-continuous-eaa688eb/server-352-ci/` (`writer.md`, `review-0.md`, `phase.diff`,
full/focused logs, private-cluster receipts, `parent-acceptance.md`, `remote-ci-watch.log`).
Desktop evidence: `/tmp/jazz-continuous-eaa688eb/m5a/` and the tracked milestone evidence notes.
