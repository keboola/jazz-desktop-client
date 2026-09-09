# ADR 0005 — Company recording policy and archive transmission authority

**Status: PROPOSED — NOT APPROVED OR IMPLEMENTED**

Relates to [ADR 0001](0001-local-first-jazz-archive.md),
[ADR 0002](0002-source-neutral-media-and-live-transport.md),
[ADR 0003](0003-confirmed-archive-delivery.md),
[ADR 0004](0004-device-bound-enrollment-identity.md) and
[M3/M4](../continuous-capture-plan.md#m3--specify-and-approve-company-policy-authorization).

## Governing gate

This is a proposed replacement for **only** ADR 0003's confirmation-only delivery
condition, not an exception currently available to callers. AGENTS.md and accepted
ADRs still require explicit archive-level human confirmation before delivery
finalization/enqueue or archive control-plane access. No synthetic `confirm`, use of
`liveCompatibility`, installer flag, or this document's publication can approve the
second path. Explicit governing/product approval, coordinated contract implementation,
server rollout and fresh client/server review are unresolved activation gates.
ADR 0004 continues to own device-bound enrollment and Secure Enclave identity; this
proposal neither replaces its keys nor supplies authoritative OS-unlocked eligibility.

## 1. Independent controls and precedence

| Recording | Upload authorization | Start and close behavior, once separately enabled |
| --- | --- | --- |
| `manual` | `humanReview` | Start opens; Stop closes locally; each archive needs genuine confirmation. |
| `manual` | `companyPolicy` | Same Start/Stop; only newly started eligible archives may upload automatically. |
| `continuous` | `humanReview` | Eligible startup/Resume arms capture; Pause closes and persists; each chunk needs confirmation. |
| `continuous` | `companyPolicy` | Same Pause/Resume; only newly started eligible chunks may upload automatically. |

Stop, Pause, chunk close and company permission are never human evidence review.
Manual intent does not survive restart or privacy suspension. Continuous startup
requires independent setup, intent, resource, recovery, TCC and qualified OS gates;
none is supplied by upload permission. Upload does not enable a modality. Existing
privacy masking and local-first durability apply in all four combinations.

Precedence, from strongest constraint: governing/release and known-protocol gates;
authenticated enrollment scope and server policy; managed restrictions; local
readiness/notice/modalities and Stop/Pause; permitted local preferences. These are
intersected, not last-writer-wins. Only a server-authenticated principal with company-
scoped permission `company.recordingPolicy.write` may change that company's policy.
The existing deployment admin allowlist is not that role. Devices can read their own
projection, never write policy. Server audit records actor, company, old/new generation,
change time and reason; credentials are excluded.

A managed recording field is read-only. A restriction may disable capture, require
review, or prohibit modalities; it cannot broaden the signed policy. MDM, installer
and first-run settings may request modes/provision enrollment, but cannot mint trust,
company authority, consent, or OS permission. Persist that an installation is managed:
profile removal, invalid policy or missing enrollment must not revert it to permissive
unmanaged defaults. Block managed starts, close active capture safely and hold automatic
delivery until explicitly resolved. With no managed enrollment/history, the default is
manual + human review; local continuous preference is only review-required and remains
subject to the independent startup gate. An automatic option without authority is
visibly unavailable, not a local toggle. MVP operator-handoff enrollment is ineligible.

## 2. One signed policy representation

Choose a **separate, non-secret flattened JWS policy document**, not an extension of the
secret-bearing enrollment bundle. Reuse `EnrollmentTrustPolicy`, strict JCS/base64url
verification and application-configured Ed25519 trust anchors. No new trust root,
key-discovery URL, MDM key, device archive signature, or key-management framework.
Protected JSON has exactly `alg: EdDSA`, `kid` and
`typ: application/vnd.jazz.company-recording-policy+jws`; envelope fields are exactly
`protected`, `payload`, `signature`. Sign ASCII `base64url(JCS(protected)) + "." +
base64url(JCS(payload))` using the existing enrollment signer. Reject duplicate/unknown
keys, noncanonical JSON, unknown `kid`/type/version, padding and signature failures.
`policyEnvelopeSHA256` is SHA-256 of JCS of the entire flattened envelope, not of a
pretty-printed transport response. The policy contains no token or key reference.

Proposed payload (illustrative values, **not** a signed fixture or deployed API):

```json
{
  "schemaVersion": 1,
  "kind": "companyRecordingPolicy",
  "policyId": "crp_00000000000000000000000000000001",
  "generation": 7,
  "state": "active",
  "issuer": "https://jazz.example.invalid",
  "audience": "jazz-desktop",
  "issuedAt": "2026-09-09T10:00:00Z",
  "expiresAt": "2026-09-10T10:00:00Z",
  "authorityBindingSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "projectId": "999999",
  "stackURL": "https://connection.example.invalid",
  "archiveIngestURL": "https://jazz.example.invalid/api/archive-ingests",
  "companyId": "company-example",
  "areaId": "area-example",
  "deviceId": "device-example",
  "recordingMode": "manual",
  "uploadAuthorization": "companyPolicy"
}
```

All listed fields are required; no additional fields. `state` is `active|revoked`;
mode enums are exactly the four table values. IDs/routes/scope use enrollment's existing
bounds and normalization (`projectId` is a nonempty decimal string matching `^[0-9]+$`); `policyId` is `crp_` + 32 lowercase hex; generation is an integer
in `1...9007199254740991`. Digests are 64 lowercase hex. Times are UTC RFC 3339 with `Z`,
whole seconds; `issuedAt < expiresAt <= issuedAt + 86400s`; intervals are half-open.
`authorityBindingSHA256` is the existing ADR 0004 authenticated authority-tuple digest,
recomputed, never accepted as a bare client claim. Additionally compare the exact full
archive endpoint and enrolled device/Company/Area, project, stack, issuer and audience.
No Area wildcard, hostname identity, cross-company reassignment or token-derived scope.
Enrollment bundle generation, token expiry and reveal expiry are not policy validity.
Credential rotation under identical signed authority does not change policy eligibility.

One durable company policy row has a stable `policyId` and increasing generation.
The server signs a projection for each enrolled device/Area/route from authenticated
registry data, caching one exact envelope per generation and binding. Admin changes,
revocation, expiry renewal and signer changes increment the company generation; no
same-generation re-signing, changed expiry or reset after deletion. Revocation retains
a tombstone. A generation change invalidates **all** older automatic eligibility for
that company, even if values later return to automatic. This deliberately favors a
simple fence over grandfathering queued generations.

Extend the existing acceptance-ledger pattern, separately keyed by issuer, audience,
project, company, Area, device, endpoint and policyId. Persist the highest verified
generation and envelope digest before use, under the existing durable locking pattern.
Lower generation = rollback; equal + different envelope = conflict; exact equal replay
is idempotent. Retain watermarks/tombstones across expiry, logout, profile removal and
credential rotation. A lost/corrupt ledger requires online reconciliation, not generation
zero or cached automatic authority. Server current state remains authoritative even if
a local disk backup predates revocation. Authority migration is ADR 0004's separately
authenticated transition, not policy refresh.

### Proposed administration, refresh and negotiation API

These routes and fields are a specification to implement together, **not current APIs**.
Device routes are derived only from the exact signed archive route: replace its final
`archive-ingests` segment with `company-recording-policy` for refresh. No response may
redirect authority to another origin/path. Existing scoped credential/header rules apply.

| Operation | Exact proposed request/response semantics |
| --- | --- |
| `PUT /api/companies/{companyId}/recording-policy` | Company-admin authentication; body `{expectedGeneration, recordingMode, uploadAuthorization, validForSeconds, reason}`. `expectedGeneration` is current integer (0 only for first creation); duration is integer 1...86400; reason nonempty, at most 512 characters. Server derives IDs, time, signer and scope. CAS mismatch: 409 `POLICY_GENERATION_CONFLICT`, no mutation; success commits generation + 1 before signing projections. |
| `POST /api/companies/{companyId}/recording-policy/revoke` | Same role; body `{expectedGeneration, reason}`. Commit generation + 1, `state=revoked`, retaining modes, with new issued/expiry times (86400s). Tombstone remains authoritative beyond expiry. No delete/reset endpoint. |
| `GET <signed-route sibling>/company-recording-policy` | Device-authenticated, no archive identity or evidence; returns exactly `{serverTime, policy}` where policy is the flattened JWS for that device and current generation. No active row: 409 `POLICY_NOT_CONFIGURED`; revoked row still returns its signed tombstone. No 304 or stale-cache success. |
| `GET <archiveIngestURL>/authorization-capabilities` | Device-authenticated; returns exactly `{serverTime, archiveFormatVersions, archiveTransferVersions, archiveAuthorizationProfiles, automaticPublicationFence}`. Proposed automatic support requires archive format `2`, transfer version `2`, profile `company-policy/v1` and fence `company-generation/v1`; human profile is `human-confirmation/v1`. Arrays enumerate installed versions, not desired configuration. Format-2 human revisions require advertised format `2` and human profile too. |

Discovery/refresh is device setup metadata, not an archive intent and sends no evidence.
Its new use before confirmation itself belongs to the future governing approval; it is
not an authorization exception available in this phase. Bodies are bounded to 64 KiB,
HTTPS only, redirects forbidden, unknown semantics fail closed. Advertisement is true
only after **every** serving store/HTTP/worker/READY/outbox path supports the profile.
Missing field, unknown fence, 404, a generic healthy/200 response, or MVP enrollment is
not automatic capability; never retry by omitting authorization fields.

Refresh at launch/reconnect, every five minutes while active, before enqueue and every
state-changing network attempt. Offline capture may use the verified policy until its
expiry, but cannot obtain new delivery authority offline. For cached validity, anchor the
HTTPS `serverTime` to a monotonic request/response interval in the current boot/process;
RTT must be <=5s. At elapsed `d` after response, conservatively bound server time as
`[serverTime+d, serverTime+RTT+d]`, with an additional 1s uncertainty on each end for
whole-second timestamps. The whole interval must be inside policy validity. Future
issuance, clock rollback/jump inconsistent with this bound, process restart, sleep or
loss of monotonic continuity invalidates the anchor and requires refresh. Never persist
wall time as proof of fresh authority. The server uses database time for all decisions.
A policy-refresh transport outage alone leaves a still-valid anchored capture local;
expiry/invalidity fences new admission and invokes retained bounded close, not deletion.
Renewal is a new generation; a queued old package is held, not silently reauthorized.

## 3. Three distinct decisions and hash boundaries

### Capture-start snapshot (before any physical admission)

For new managed-policy captures, after claiming fresh archive/capture IDs and preparing
notice, scope, mode, modalities and readiness, persist `policies/captures/<captureId>.json`
with the initial journal transaction.
Proposed `CapturePolicySnapshot v1` has exactly `{schemaVersion:1, archiveId, captureId,
startedAt, recordingMode, uploadAuthorization, automaticEligible, policyId, generation,
policyEnvelopeSHA256}`. Every listed field is required, with archive/capture identity
grammars from the shared contract. Unmanaged format-1 human captures need no policy
snapshot. `automaticEligible=true` requires active, valid, scope-matched
signed policy selecting `companyPolicy`, no managed review restriction, and positively
negotiated automatic capability in the same anchored validity interval (cache at most
five minutes). Otherwise use `automaticEligible=false` and effective `humanReview`, or
block capture if managed authority/readiness itself is invalid. Persist the referenced
non-secret envelope at `policies/company-policy.json` before admission. One archive uses
one policy projection; this first profile supports one capture per automatic archive.

Recheck intent, policy generation, expiry and physical eligibility after awaits and
immediately before enabling sources. Failed persistence admits nothing. Freeze the
snapshot; later permission loss/revocation closes truthfully without rewriting it. A
change of either policy field applies only to newly started captures. A noticed generation
change closes the old capture locally and latches it for review; it never resumes on the
strength of the old snapshot. Notice receipts remain separate durable setup state, not
invented per-chunk consent assertions. Material destination/modality changes require renewed
applicable notice/consent readiness before new capture, independently of signed upload policy. Local timestamps/snapshots are enrolled-client
provenance, **not cryptographic attestation of sensor time or honest client software**.

### Local close, seal and per-archive authorization

Actual baseline seams: `CaptureController.prepareCapture` freezes settings before journal
admission; `JazzArchiveFinalizer.finalize` seals review, compacts records/artifacts and
materializes labels/assertions before inventory; `enqueueConfirmed` explicitly passes
`requireArchiveConfirmation: true`. The lower-level finalizer's optional guard is **not**
authority for delivery. `makeInventory` excludes root manifest/inventory and `sync/`;
the deterministic ZIP contains the finalized logical package. Proposed ordering:

1. Local stop/drain writes the existing `CaptureCommit` without network. Human-review
   archives retain the present confirmation branch. Automatic sealing requires the
   immutable eligible start snapshot, complete local commit, no review/rejection/terminal
   hold, fresh matching current policy/capability and valid scope. If refresh is offline,
   leave a committed local `awaitingAuthority` candidate, unsealed; no enqueue/intent.
2. For automatic packages use **archive formatVersion 2**, with required manifest field
   `deliveryAuthorization={kind:"companyPolicy", policySnapshotPath, policySnapshotSHA256}`.
   Path must be exactly the one capture's snapshot path; SHA-256 covers its JCS bytes.
   Inventory includes that snapshot and policy envelope, all record/artifact/session/commit,
   label and assertion files. Any effective archive-level rejection or review hold denies
   this branch. No company authorization is encoded as a human assertion.
3. Let `I = JCS(inventory)` over sorted path/byteLength/SHA-256 entries, excluding root
   `manifest.json`, `inventory.json` and delivery state. Set `manifest.inventory.digest =
   SHA256(I)`. Let `M` be the finalized manifest (including snapshotAt, commits, policy
   reference), with **only contentDigest omitted**. `contentDigest = SHA256(JCS(M))`, as
   today. Then write the final manifest containing that digest and export the existing
   deterministic ZIP algorithm. `rawSha256 = SHA256(exact ZIP bytes)`; `byteLength` is
   that file's exact length. Do not omit policy evidence or assertions from `I` to break
   a cycle, and do not change CaptureCommit/observation/artifact hashes.
4. Persist the exact ZIP, caller-owned `uploadOperationId` and a non-secret external
   `CompanyArchiveAuthorization v1` atomically/durably with queue ownership before any
   intent. Its exact fields are `{schemaVersion:1, profile:"company-policy/v1",
   uploadOperationId, archiveId, originId, formatVersion:2, revision, contentDigest,
   rawSha256, byteLength, authority, policyId, generation, policyEnvelopeSHA256,
   policySnapshotSHA256}`. `authority` has exactly `{issuer, audience, projectId, stackURL,
   archiveIngestURL, companyId, areaId, deviceId, authorityBindingSHA256}` copied from the
   verified policy. Apply existing archive/operation-ID, SHA and integer grammars.
   `authorizationSHA256 = SHA256(JCS(CompanyArchiveAuthorization))` is stored separately.
   Recheck current authority before releasing the item for network; a concurrent change
   leaves an immutable sealed held item, not a partly rewritten package.

New human-review captures containing policy snapshots also use format 2 with
`deliveryAuthorization={kind:"humanReview"}`; their inventoried snapshots remain provenance,
not delivery permission. Unmanaged captures without policy evidence retain today's format 1.
Format-2 readers validate the known policy file/snapshot paths and one snapshot per capture;
only the automatic branch requires its snapshot to bind the current archiveId and generation.
Human revisions validate ancestor snapshot bindings against explicit revision lineage.

The **only new signature** is the policy JWS issued before capture. Neither the snapshot
nor the external archive authorization is a second signed document: the latter is a
binding request authenticated by the existing device credential and validated against
the signed policy and server row. It is not standalone authority on import. No signature
or digest of the finished ZIP is inserted into that ZIP; no policy signature purports
to cover future content. Import verifies policy/snapshot bytes through inventory, manifest
and raw digest, then binds them to the authenticated external authorization. Queue state,
receipts, grants and authorizationSHA256 are outside the package and contentDigest.

### Fresh delivery attempts

Add `archiveAuthorization` to the existing v2 intent: exactly `{profile:"company-policy/v1",
authorization:<CompanyArchiveAuthorization>, policy:<flattened JWS>}` for the new branch.
The existing immutable intent tuple must equal authorization fields byte-for-byte; reject
same archive or operation identity with changed package/authorization as 409
`ARCHIVE_AUTHORIZATION_CONFLICT`. Persist the validated authorization and digest on the
ingest row in the intent transaction. Automatic intent/status/finalize responses extend
the existing immutable tuple/operation echoes with exactly `authorizationProfile`,
`authorizationSHA256` and `policyGeneration`; every value must match the durable request.
Missing/mismatched echoes fail closed, not as an older-server success. Existing human v1 requests remain unchanged; absence
of this field means **human confirmation required**, never automatic fallback.

Before create-intent, grant renewal, payload dispatch and finalize, verify current
credential route/scope, local hold state, exact queue bytes, snapshot, fresh policy and
capability. Server repeats authentication and locks current company policy: identical
policyId/generation/binding, active state, unexpired database time. After byte verification,
require the automatic snapshot's startedAt to equal its session.startedAt inside the
signed policy interval, its recordingMode to equal signed policy, and both snapshot and
policy to select companyPolicy with automaticEligible=true. Check snapshot/envelope hashes
against manifest/inventory and persisted external authorization, not just submitted metadata. Failure retains local
bytes. 401 uses existing reconnect-required behavior; 409 `POLICY_CHANGED` or
`POLICY_REVOKED`, 412 `POLICY_EXPIRED` or `AUTHORIZATION_UNSUPPORTED` latch review hold;
unknown responses fail closed. A persisted server ingest failing these policy checks enters
new terminal-for-that-operation state `authorization_held` with the reason code; it grants
no worker claim, new upload grant or READY, and status exposes its immutable tuple. There
is no automatic transition back, even if policy values are restored. Pure transport
failures/backoff and rotated credentials under unchanged authority remain retryable,
never remint operation/archive IDs.

Proposed `POST <archiveIngestURL>/{ingestId}/upload-grants` body is exactly
`{uploadOperationId, authorizationSHA256}`. It issues/renews the existing opaque
`http-put/v1` instructions only after a **fresh transactional current-policy check**;
intent alone is not a payload grant for this profile. Response extends the existing grant
with non-secret `{policyGeneration, authorizationSHA256, issuedAt, expiresAt}` and echoes
operation ID. Expiry is at most `min(issuedAt+60s, policy.expiresAt)`; no grant if the
client cannot conservatively establish remaining validity. Dispatch immediately after
this response and recheck local fences/time immediately before PUT; never persist URLs,
headers or grants. Finalize adds `authorizationSHA256` to the existing operation/receipt
body and repeats current-policy checks even on recovered/lost-response finalization.
Read-only status polling may learn an already committed READY after revocation, but
cannot renew authority, transfer payload or cause publication. Status alone cannot settle
a held operation that never reached finalize; use the reconciliation transition below.

### Held-operation reconciliation (no transmission grant)

Permit **`POST <archiveIngestURL>/operations/{uploadOperationId}/reconcile` while held**.
Body is exactly `{authorization:<CompanyArchiveAuthorization>}` from durable queue state.
The path operation ID must equal the body; recompute authorizationSHA256 and validate
all immutable tuple/authority fields. Authenticate with a current device credential for
the same issuer/project/company/Area/device/route. Current automatic policy validity,
a payload receipt and an ingest ID are **not** required: this operation cannot authorize
capture, issue/renew a grant, finalize payload or create READY/outbox. Revoked credentials
still fail authentication; retain the hold until authorized access is restored, never
loosen identity checks to unblock a replacement.

Under the same company-first fence as intent and READY (section 4), serialize the durable
operation identity and any ingest row. An existing tuple/digest/binding mismatch returns
409 `ARCHIVE_AUTHORIZATION_CONFLICT` without mutation. Otherwise:

- If READY already committed, return its immutable historical acceptance, unchanged.
- If an ingest exists but is not READY, durably establish terminal nonpublication and
  `authorization_held` (or preserve an existing terminal nonpublication result). Fence
  all worker publication/grants before replying, even if verification is in flight.
- If no ingest exists, atomically create a nonpublication tombstone bound to the exact
  authority, archiveId, operation ID and authorization digest. This is **not** an ingest
  intent and creates no upload instructions or worker work. Subsequent intent retries
  for that operation are rejected; automatic attempts for that held archive identity
  cannot escape the tombstone by choosing another operation ID. A new human revision
  has its own archiveId and is unaffected.

Response echoes the existing immutable package tuple and the three authorization fields
specified above, plus `resolution: "ready" | "nonpublication"` and nullable `ingestId`
(null only for a no-ingest tombstone). A ready response includes the existing READY receipt;
a nonpublication response includes its durable terminal `state` and reason. Both alternatives
must be closed-world schema definitions and idempotent under exact request replay. Neither
alternative includes grant instructions. Persist/validate the response before permitting
replacement delivery. A lost reconciliation response retries this exact operation-bound
request, **not** create-intent. If intent/READY races reconciliation, the common fence
makes it either historical READY or durable nonpublication, never an ambiguous success.
Provider PUTs already accepted may still finish into staging; they cannot bypass this fence.

## 4. Revocation cutoff, holds and immutable revisions

**Cutoff = the database commit that advances/revokes company policy.** Serialize policy
updates with intent/grant/finalize and `publish_ready` by locking the same company row,
then ingest row in that order. Server device revocation/scope changes must acquire that
same company fence before changing enrollment authority; otherwise a device check could
race READY independently of policy. At READY, compare the persisted authorization, current
policy generation/state, database expiry, device enrollment revocation/scope and verified
package again inside the transaction that writes READY, accepted-object binding and
`ArchiveAccepted` outbox. Reference/SQLite stores need equivalent serialization. A
worker check before object retention is insufficient; recovered verification/import,
alternate paths and outbox repair may not bypass this transaction.

If READY commits first, acceptance remains immutable and its outbox can be replayed after
revocation, bound to that exact historical acceptance. If revocation commits first,
READY/outbox creation fails and unpublished retained objects remain inaccessible through
canonical readers. Expiry has the same fence using database time. Do not write an
ArchiveAccepted event early or let recovery fabricate one for an unaccepted row.

Previously issued direct PUT URLs may still transfer bytes after cutoff. The 60-second
limit bounds new request authorization, **not** completion of a PUT already accepted by
a provider. Cancel at the client deadline/revocation when observed, but do not promise
recall of transmitted bytes or immediate provider cancellation. Such bytes may remain
in server staging/retained storage; they confer no READY/publication authority. Providers
must enforce grant expiry at request admission; otherwise advertise no automatic profile.
Human Stop/Pause does not revoke an already authorized completed archive's transmission.
An explicit local delivery hold fences further client attempts, not an already executing
server worker; only the server policy cutoff guarantees nonpublication. Local data survives
all outcomes.

Use these durable, non-wire decision distinctions:

- `pendingAutomatic` / `awaitingAuthority`: originally eligible, same generation, only
  transport unavailable; may resume after successful same-generation checks. They are
  not an old review backlog. Expiry, observed policy change, profile removal, scope
  uncertainty, unknown capability or explicit hold converts them to `reviewHold`.
- `reviewHold`: a one-way automatic-ineligibility latch for that archive identity;
  policy restoration/renewal/reinstall cannot clear it. Human-required-at-start, legacy,
  imported, rejected, quarantined, terminally failed and corrected archives never gain
  automatic eligibility. Rejected/quarantined evidence also needs its explicit existing
  resolution, not merely a new confirmation or changed company policy.
- READY before cutoff stays accepted. Lost success responses are reconciled by status
  when the ingest ID is known, or the operation-bound reconciliation above while held;
  neither path uploads a replacement. Transport retries under unchanged authority use the
  exact original ZIP/digests/length, route, operation and authorization digest.

For an **already sealed automatic archive** held after a change, choose a **human-reviewed
revision**, not external human approval attached to the old ZIP. Deliberate “Review as new
revision” freezes further old-operation attempts, queries/reconciles any uncertain remote
operation through the operation-ID reconciliation endpoint when online (including a lost
intent response with no ingest ID), and forks verified retained evidence through the existing revision
mechanism: new archiveId, revision + 1, supersedesArchiveId, new commits with prior commit
links, unchanged observation/artifact/capture/source IDs and evidence digests. Unknown or
still-processing remote outcome blocks replacement enqueue until status proves historical
READY or the reconciliation transaction establishes terminal nonpublication (including a
no-ingest tombstone or `authorization_held`); an already accepted old
revision remains visible as accepted. The proposed fork adds an explicit local `authorizationReview`
reason instead of fabricating an evidence correction to satisfy today's correction-only
fork guard. Actual content corrections still use the existing correction assertion path.

The new format-2 revision retains original policy/snapshot provenance (whose archiveId
refers to its ancestor), sets `deliveryAuthorization={kind:"humanReview"}`, and requires
a real identified-human archive confirmation of the **new** revision. It can never reuse
its ancestor's automatic snapshot as eligibility. This format-2 human branch is part of
the same negotiated rollout; older peers hold it, not strip fields or repackage as v1.
The old finalized directory, queue ZIP, authorization and audit remain unchanged and
held/cancelled locally; the replacement gets its own operation. An unsealed held draft
can instead receive ordinary genuine confirmation before its first seal. No bulk
release API or re-signing old automatic packages under a new policy is proposed.

## 5. Coordinated implementation and migration (not changes made here)

| Surface | Exact coordinated work required after governing approval |
| --- | --- |
| Governing docs | Explicit approval to amend AGENTS.md and ADR 0003's confirmation-only condition/control-plane gate; retain human branch, rejection, durability, credential and immutable retry rules. Record approver and activation scope; this ADR cannot approve itself. |
| Policy contract | Add `contract/enrollment/schema/company-recording-policy-v1-{jws,payload}.schema.json` and positive/negative JWS fixtures using existing test-only enrollment keys; add policy acceptance/rollback/time vectors. Enrollment bundle/redemption v1/v2 and ADR 0004 key format stay unchanged. Extend `contract/validate_schemas.py`. |
| Archive contract | Add `contract/archive/schema/capture-policy-snapshot.schema.json` and `company-archive-authorization.schema.json`; update archive-manifest schema for a closed-world format-2 branch and the two exact deliveryAuthorization alternatives. Keep format-1 human validation unchanged. Update inventory path validation and `contract/archive/validate_archives.py`; add a v2 branch to `delivery-state.schema.json` carrying authorization profile/digest and hold reason only (no route, token or grant). The full external authorization lives in the dedicated new schema/queue record, not this endpoint-free delivery projection. No fabricated assertion decision. |
| Goldens and transfer contract | Add automatic, held/revision, tampered policy and hash-boundary archives under `contract/archive/fixtures/`; update `regenerate_fixtures.py` and deterministic container fixtures/generator. Add `contract/archive/schema/archive-authorization-http-v1.schema.json` with definitions for the exact administration/refresh/capability/intent/grant/finalize/status/reconciliation alternatives above, and `contract/archive/authorization-fixtures/` for transfer, mixed-version and race vectors (validate through the existing archive validator). Existing event/OTLP `contract/conformance/` cases stay unchanged. Add every vector below as executable fixtures; no real tokens or signatures in examples here. |
| Swift | Extend `JazzEnrollmentSecurity` verifier/acceptance pattern and device setup adapter; Foundation-only snapshot/authorization models, journal persistence/recovery, manifest/inventory validation, finalizer, review/revision/importer, durable upload queue and coordinator. Wire network adapters in `JazzCapture/ArchiveUploadClient.swift`, capture-start snapshot in `CaptureController`, setup/Settings and honest held/automatic UI. Extend `JazzArchiveTests`, `JazzArchiveUploadTests`, `JazzArchiveRevisionForkerTests`, archive finalizer/importer fixture checks and `SignedEnrollmentSecurityTests` in the existing `macos/Tests/JazzCaptureCoreTests/` and `macos/Tests/JazzEnrollmentSecurityTests/` runners. Keep no-confirmation/no-intent tests for human mode. |
| Processor mirror and stores | Mirror exact schemas/goldens in `apps/processor/src/jasnost_processor/contracts/desktop/`; update corresponding verifier/fixture runners. Implement `device_control_plane.py`, `enrollment_signing.py`, `api.py`, `archive_http.py`, `archive_scope.py`, `archive_verify.py`, `archive_worker.py`, `archive_ingest.py` and `postgres_archive_ingest.py` plus SQLite/reference parity, migrations, authorization row/tombstone persistence and transactional policy/operation/READY/outbox fencing. Include recovery and accepted-object/download read paths; embedded imported policy never authorizes a new ingest. |
| Portable consumers | Update supported Windows contract readers/fixtures before claiming format-2 support; no hardware enrollment or automatic Windows activation is inferred. If any emitted event/OTLP mapping changes, schema, golden, Swift runner and processor mirror must change together. This proposal requires no event/OTLP or liveCompatibility change. |

Deploy server schema/stores/readers and **all worker replicas first**, with automatic
capability disabled until parity/fencing tests pass. Then advertise support, deploy gated
clients, obtain explicit per-company policy and rollout approval, and only then enable the
new branch. Unknown/mixed peers hold automatic candidates and all format-2 deliveries;
existing supported format-1 human review continues unchanged. Rollback disables new
automatic grants/publication and advances policy generation, preserving bytes and known
READY receipts. It never selects liveCompatibility or synthetic human review as fallback.

## 6. Deterministic illustrative decision vectors

These are decision specifications using a trusted test clock and assumed-valid synthetic
signature unless stated otherwise, **not executable conformance fixtures or real API
results**. Base: valid policy P7/manual/companyPolicy, exact enrolled binding, known
capability, eligible snapshot S7, complete clean local commit, current generation 7,
no terminal state; server time well inside validity. Each row changes only its input.

| Input/change | Expected decision |
| --- | --- |
| Base; humanReview instead of companyPolicy at start | Start manually; close `Needs review`; no seal-for-delivery/intent before real confirm. |
| Base | Start manually; fresh checks permit automatic seal/enqueue and grant; no human confirm assertion. |
| Base; continuous + humanReview / continuous + companyPolicy | Eligible Resume opens; Pause persists and closes; respectively Needs review / automatic attempt. Failed OS/setup gate always blocks start. |
| Signed P7 copied to another device, Area, endpoint or company; or MVP profile | Reject authority; no managed start or automatic network; retain evidence. |
| Same P7 exact replay / lower P6 / changed envelope at P7 | Idempotent ledger replay / rollback hold / conflict hold. |
| Unknown kid, invalid signature, unrecognized field or version | Reject policy; no authority; never discover keys from document. |
| Installer automatic checked but no signed policy; first-run employee tries override | Automatic unavailable; unmanaged manual review only, managed installation blocked. |
| Valid cached P7 and time anchor; network offline at close | Commit locally `awaitingAuthority`; no intent. Same P7 and known capability on reconnect permits attempt. |
| Expiry boundary reached, reboot without refresh, or clock bound crosses expiry | No new managed capture; retained close; automatic candidate latches reviewHold, no network transfer. |
| P8 review (or P8 automatic), then P9 automatic; S7 queued | S7 stays reviewHold. Neither policy restores old automatic eligibility. |
| Human-held, rejected, imported, quarantined or corrected backlog when P7 arrives | No automatic release; explicit review/resolution and revision rules apply. |
| Unknown/missing capability at start / enqueue | Local human-review snapshot if otherwise capture-eligible / reviewHold; no speculative intent or downgraded request. |
| Token rotated, same authority/P7; transient lost intent response | Reuse identical operation, ZIP, authorization and generation; fresh checks then idempotent retry. |
| Modify snapshot, assertion, ZIP byte, length, or external authorization | Inventory/content/raw/auth binding failure respectively; hold/conflict, no READY. Recomputing hashes cannot change an existing operation's tuple. |
| Grant at t=100, expiry t=160; payload dispatch at t=160 | Deny expired dispatch. A request admitted at t=159 may still transmit after t=160, but needs fresh finalize/publication authority. |
| Grant P7; P8 revocation commits before READY | Cancel when observed; no READY/outbox even if PUT/retention already finished; keep local/staged bytes. |
| READY P7 transaction commits before P8 revocation | Exactly one accepted binding/outbox; later status or held-operation reconciliation reports historical READY, never recalls bytes or creates new publication. |
| P7 intent committed, no payload finalized, then P8 observed | Latch reviewHold; operation-bound reconciliation returns durable nonpublication and fences the existing ingest before human-revision enqueue. No grant/finalize/automatic retry. |
| P7 intent response lost, then P8 observed; no ingest ID locally | Reconcile using persisted operation ID and exact authorization. Existing row becomes terminal nonpublication, or historical READY is returned. Never require an ingest ID or repeat create-intent while held. |
| Reconciliation wins before a delayed P7 intent commits | Persist exact operation/archive tombstone; delayed intent and fresh-operation automatic attempts for that archive are denied. Lost reconciliation response replays idempotently; a separately confirmed human revision uses a new archiveId. |
| Sealed S7 held; user confirms old ZIP without fork | Deny replacement authorization. Explicit new human revision + real confirm permits its distinct negotiated delivery; old bytes never change. |

## Consequences and next gate

Company policy grants **transmission permission**, not employee review, business approval,
consent renewal, task correctness or permission to execute evidence. UI says “Automatic
upload — company policy”; READY means ingest acceptance, not human approval. This bounded
profile deliberately sacrifices old-generation automatic retries (including daily expiry
renewal) rather than adding grandfathering or detached human-approval machinery.

M3 draft review may assess whether these semantics are coherent; it cannot accept the
new governing authority by implication. Useful M4 work now is review-only enrollment/
setup readiness, company/destination/notice display, independent persisted Pause and
truthful permission-denial/relaunch behavior. Automatic controls stay unavailable and
current interactive OS acknowledgment remains mandatory until separately qualified.
