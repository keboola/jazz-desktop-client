# Real-Mac qualification evidence

The automated suite proves the portable contracts. It does not prove TCC behavior, signed app
identity, focus behavior, two-device enrollment, deployed provider wiring, or Mac A → server →
Mac B transfer. Those release gates are tracked by GitHub issue #4 and must be exercised on the
exact candidate builds.

`JazzDogfoodQualificationBundle` is the deterministic, privacy-safe index for that evidence. It is
not a Jazz Archive, capture truth, or an input to delivery. Exporting it cannot mutate an archive,
queue item, ProcessExecution, or server state.

## What the bundle records

The current `jazz-desktop-client.issue-4.v2` profile contains all 34 issue scenarios. It adds
`B05.hung_evaluator_stop_isolation`, which requires retained evidence that a deliberately suspended
evaluator GET did not delay local Stop, that its late response did not publish, and that an old
label generation did not block or steal the next label's admission.

Historical `jazz-desktop-client.issue-4.v1` bundles remain readable and validate against their
original closed 33-scenario set. They are not upgraded or treated as evidence for B05. New runs
must use v2. The exporter returns the exact `profile` and sets `currentProfileEligible=false` for
v1 even when its historical `overallOutcome` is `passed`; release automation must require both a
current profile and a passing outcome. Checked-in base64 golden artifacts preserve the exact
canonical bytes emitted by the original v1 exporter for one PASS and one blocked run. A terminal
full v2 profile records:

- the exact desktop and server Git revisions;
- app bundle/version/build plus SHA-256 of the signed code-identity evidence;
- SHA-256 of the deployed server build identity;
- macOS and bounded provider versions;
- at least two organization-pseudonymous device identities and two operator identities;
- Jazz Archive ID, content digest, exact ZIP SHA-256, and byte length;
- one result for every scenario and content-addressed references to sanitized evidence.

The identity values are hashes, not names, e-mail addresses, serial numbers, certificate subjects,
or MDM records. Derive them from stable organization-scoped identifiers with separate domains for
devices and people; never hash a short or guessable human label without an organization-held salt.
Keep the identity derivation recipe in the company evidence system, not in this shareable bundle.

The bundle deliberately cannot contain free text, screenshot/audio/clipboard bytes, URLs, paths,
logs, response bodies, tokens, or object locators. Evidence values are limited to booleans, safe
integers, and SHA-256 digests. The source receipt itself is retained separately; the bundle records
its exact digest and length.

## Qualification procedure

1. Pin the candidate desktop and server commits before testing. Record signed app identity, server
   build identity, macOS version, provider versions, and pseudonymous device/operator identities.
2. Generate one UUIDv7 `qrun-…` with
   `JazzDogfoodQualificationBundle.newRunId()`. Persist it before the first scenario and never
   replace it after a crash or ambiguous export.
3. Run the issue #4 scenarios against the intended signed build and deployed environment. Keep raw
   evidence in the approved company evidence store.
4. For each source, produce a bounded sanitized technical summary, compute its SHA-256 and byte
   length, and create `JazzDogfoodEvidenceReceipt`. Its content-addressed `dqe-sha256-…` identity
   covers scenario, evidence kind, source digest/length, capture time, and all measurements.
5. Mark a scenario `passed` or `failed` only when its receipts cover every
   `scenario.requiredEvidenceKinds`. `blocked` may retain partial evidence. `not_run` must not claim
   any evidence.
6. Ensure every receipt time lies within the qualification run interval. Evidence for another
   scenario, evidence outside the interval, missing evidence, and unreferenced evidence all fail
   validation.
7. Build the complete 34-result v2 bundle and call `validate()`. A full terminal profile—whether it
   passes or fails—requires at least two devices, two operators, and a provider version. Any
   blocked/not-run scenario makes the overall outcome `blocked`; any failed scenario makes it
   `failed`.
8. Export with `JazzDogfoodQualificationExporter` and the executable's native
   `JazzArchiveFilesystemDurability`. The exporter writes canonical JSON atomically with mode
   `0600`, explicit durability barriers, a 1 MiB cap, idempotent exact-byte retry, and fail-closed
   conflict handling. Require the returned `profile` to equal
   `JazzDogfoodQualificationBundle.currentProfile` and `currentProfileEligible` to be true before
   interpreting `overallOutcome` as a current release verdict.
9. Attach the exported JSON, its returned SHA-256/length, and the separately retained sanitized
   receipts to issue #4. Never attach raw sensitive capture material to a public issue.

## Evidence semantics

The evidence-kind policy is code and profile-versioned. Examples:

- local input/privacy scenarios require the archive plus capture-observation summaries;
- TCC transitions require capability-transition evidence;
- ordinary Coach scenarios require archive and Coach interaction summaries;
- B05 additionally requires a Coach transport summary and operator attestation: together these
  index bounded evidence for the suspended request, local Stop completion, late-response rejection,
  and generation-safe label turnover;
- delivery/enrollment scenarios require exact archive, delivery, enrollment, build, or server-state
  receipts as appropriate;
- deployed transfer/replay requires archive, delivery/import, server-state, playback, or execution
  receipts;
- live-compatibility scenarios require live-parity evidence and, where applicable, the canonical
  archive and server-state/playback evidence.

Changing a coordinate or required kind changes the meaning of PASS and therefore requires a new
profile version. A prior profile continues to validate only against its original coordinate set; it
is never silently promoted to the new profile. Do not edit an exported result to make a release
pass. Repeat the physical scenario under a new qualification run and retain both outcomes.

## Release interpretation

The bundle makes the release decision auditable; it does not make it true by itself. A valid
`passed` bundle means every profile coordinate has structurally complete evidence for the pinned
builds and environment. Reviewers must still verify the separately retained source receipts and
their digests. A valid `failed` or `blocked` bundle is useful evidence and must not be deleted or
rewritten.

No issue #4 checkbox should be closed from automated Swift tests alone.
