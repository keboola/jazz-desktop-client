# Team brief: Windows feature parity, managed installation, and desktop releases

## Objective

Deliver a production-ready Windows Jazz client with **full functional parity with the
macOS application**, an MSI suitable for interactive and remote enterprise deployment,
and a pipeline producing both platform packages from the same source revision.
**Microsoft Intune installation is mandatory: the customer uses Intune to deploy software
to its Windows PCs.**

This is an implementation brief, not a declaration that these capabilities already ship.
Parity means equivalent user outcomes, privacy, security, contracts, and recovery guarantees;
it does not require copying macOS visuals or OS-specific APIs.

## Starting point

Baseline inspected: commit `0bbe400` (`fix(macos): make archive resubmission reliable`).
Before implementation, agree the target macOS commit and track subsequent feature changes.
Uncommitted local work is not part of this baseline.

- Reuse `windows/`: an existing .NET 8 tray application, portable core, enrollment
  security module, tests, and diagnostic probes. Do not restart the port.
- `windows/installer/Package.wxs` and `build-msi.ps1` already produce a self-contained
  Windows x64 MSI. It is unsigned, per-user, installs under `%LOCALAPPDATA%`, and starts
  the client at login. It does not yet satisfy this brief's managed deployment requirements.
- `.github/workflows/ci.yml` already tests both clients, runs contract validators, and
  publishes an unsigned MSI artifact on PRs/main pushes. It does not package the macOS app
  or publish a paired production release.
- `macos/build-release.sh` packages macOS; notarization is currently documented as manual.
- Read the actual implementation as well as the READMEs: the Windows README describes
  known enrollment/delivery gaps and absent media features, while screenshot and narration
  implementations now exist in the tree. Verify wiring and behavior rather than treating
  source-file presence or old documentation as proof of parity.

## 1. Full functional parity

First deliver a checked-in parity matrix mapping each macOS feature to its Windows
implementation, automated tests, physical-machine evidence, and remaining gaps. Inventory
`macos/Sources/`, settings, menus, and user flows; the list below is a minimum, not an
exhaustive substitute for that inventory. Classify each row as verified, partial, missing,
or blocked. No silent scope reduction: exceptions require the product owner's approval.

| Area | Required Windows outcome |
| --- | --- |
| Application lifecycle | Tray UI, settings, startup/login behavior, permissions/preflight, visible recording state, shortcuts, single-instance behavior, safe quit and recovery. |
| Capture | Pointer gestures, scroll, keyboard/clipboard actions, app/window context, semantic targets through Windows UI Automation, screenshots, narration, and capability/gap reporting equivalent to macOS. |
| Privacy | Sensitive-app exclusion, secure-field suppression, text redaction before persistence, appropriate screenshot/audio gating, recording/microphone indicators, and accessible Stop/Pause controls. |
| Session workflows | Process mapping; labeled segments and label-bound narration; guided/explore labels using Area registries; identity and Company/Area attribution; guided BDM workshops and their scripted prompts. |
| Live features | Capture Coach, BDM live interactions, and explicit `liveCompatibility` behavior wherever supported in the agreed macOS baseline, including consent, capability negotiation, audit records, and failure handling. |
| Local archives | Canonical journal, artifacts, CaptureCommit, bounded recovery, revisions/corrections, review, confirm/reject, deterministic export, validated import, and native offline evidence playback. |
| Sessions and server UI | Local session inventory and status, delivery controls, server analysis/review navigation, and server archive retrieval where supported by the baseline. |
| Enrollment and credentials | Supported production and explicit MVP enrollment profiles, scope validation, replay protection, device-bound identity, credential renewal/reconnect/disconnect, and trusted routing. Production requires a qualified Windows CNG/TPM equivalent; never ship a development cleartext key backend as a fallback. |
| Delivery | Real authenticated intent → opaque package upload → finalize → status flow, durable retries/relaunch, cancellation, quarantine, and explicit resubmission behavior. Test against the server, not only transport fakes. |
| Governed execution | Reviewed immutable runbook/decision admission, device/operator binding, capabilities and preconditions, claim/start/completion/cancellation, native guidance, and durable reconciliation. Playback must never become input replay. |
| Distribution | Version display, update discovery/release navigation, stable signed identity, installation, upgrade, repair, and uninstall. Managed deployments must remain under administrator update control. |

Use native Windows mechanisms and the existing .NET structure. Do not introduce a local
bridge or network service. Capture runs in the interactive user's desktop session, not
Windows Session 0. Document platform limitations (including elevated applications, secure
desktops, missing hardware/permissions, remote sessions, and multi-monitor/DPI behavior)
and qualify the supported cases. A missing capability is not automatically a parity waiver.

## 2. Independent capture and upload policies

Expose two independent installation/deployment settings. Proposed MSI property names:

| Property | Values | Unmanaged default |
| --- | --- | --- |
| `JAZZ_CONTINUOUS_CAPTURE` | `0` = manual Start/Stop; `1` = continuous with Pause/Resume | `0` |
| `JAZZ_UPLOAD_MODE` | `REVIEW_REQUIRED` or `AUTOMATIC` | `REVIEW_REQUIRED` |

Implement and test all four combinations:

| Capture mode | Upload mode | Expected behavior |
| --- | --- | --- |
| Manual | Review required | User starts/stops; each completed session waits for explicit approval. |
| Manual | Automatic | User starts/stops; eligible completed sessions upload under valid company authority, without per-session approval. |
| Continuous | Review required | Eligible startup/resume captures into bounded sessions; each waits for explicit approval. |
| Continuous | Automatic | Eligible startup/resume captures into bounded sessions; eligible completed sessions upload under valid company authority. |

Continuous must not mean one indefinitely growing recording. Agree and document chunk
length, inactivity threshold, label/audio behavior across boundaries, and crash recovery.
Fence capture on lock, sleep, logout, and user switch. Resume only in an eligible unlocked
user session. Explicit Pause survives wake, reconnect, and relaunch until Resume.
Bound local resource use; disk pressure must stop/pause safely rather than discard evidence.
Define how continuous capture interacts with workshops and guided execution; never run
conflicting capture sessions concurrently.

Installation is not permission or consent. Explain the effective mode, captured data,
destination, and user controls at first run; complete applicable notice/consent and OS
permission requirements before capture. Never enable hidden recording.

### Automatic-upload gate: coordinated contract work

**Current `AGENTS.md` and archive contracts require explicit archive-level confirmation
before finalization/enqueue. An MSI property alone cannot authorize a bypass.** Automatic
upload is a requested new authorization path, not permission to fabricate a human Confirm
or misuse `liveCompatibility`.

Before enabling it, obtain an approved ADR and coordinate governing instructions,
shared schemas/fixtures, Swift conformance runner, both clients, and processor/server
mirror and enforcement. Record company-authorized delivery separately from human evidence
review. Reuse existing enrollment trust to validate company/device/scope-bound authority
with a policy version and defined expiry/revocation behavior.

Missing, invalid, expired, revoked, or unverifiable authority holds archives locally.
Validate authority at enqueue and delivery; define server enforcement and the precise
in-flight revocation cutoff. Changing modes must not silently release existing review
backlogs, imports, rejected archives, or quarantined data. A switch back to review-required
must hold pending work according to the agreed race-safe policy.

Both modes remain local-first: commit canonical data without a network, then deliver one
immutable package. Preserve archive ID, content digest, exact ZIP SHA-256, length, and bytes
across retries/relaunches. Rejection never queues delivery. Network/credential failures,
cancellation, quarantine, upgrades, and uninstall must not destroy local evidence.

## 3. Interactive MSI and enterprise deployment

Extend the existing WiX installer; do not add another packaging technology unless a named
deployment target requires it.

- Interactive installation exposes the two settings with clear explanations and defaults.
  Silent installation accepts the same validated public properties without dialogs.
  Reject invalid values; never silently turn an unknown value into automatic upload.
- Support enterprise installation from a deployment agent running as SYSTEM, including
  machines with no user logged in. The current per-user MSI cannot simply be run as SYSTEM
  and treated as installation for the intended users. Define a supported per-machine
  installation and per-user first-run/startup strategy; retain an interactive per-user
  option if required. Do not start capture in the installer's account/session.
- The package **must support deployment through Microsoft Intune**, the customer's
  software distribution system. Deliver the MSI and, if required for the selected Intune
  deployment method, a Win32 `.intunewin` wrapper containing that same MSI. Provide
  install/uninstall commands, detection rules, requirements, execution context, expected
  exit codes, reboot behavior, and step-by-step Intune deployment instructions.
  Other distribution tools are optional unless separately requested.
- Persist non-secret managed policy in an administrator-protected Windows location.
  Document precedence: enforced company restrictions cannot be relaxed by installer
  preferences or user settings. Distinguish managed enforcement from unmanaged defaults;
  define policy updates/removal and ensure repair/upgrade does not reset configuration.
- Keep login auto-launch separate from recording mode. Manual mode may launch the tray
  at login but must not start recording.
- Enrollment is separate from upload authorization. Provide a documented secure enrollment
  handoff for both interactive and managed rollout. Never pass tokens, bootstrap bundles,
  or secret stream endpoints in MSI properties/command lines, transforms, logs, or Git.
  Use protected Windows credential storage and appropriately ACL-protected provisioning;
  specify ownership, one-time consumption, and cleanup of any temporary secret material.
- Isolate archives, settings, identities, and delivery queues per intended user/device.
  Test multiple users and migration from the existing per-user package; prevent duplicate
  startup entries and competing client instances during migration.
- Support upgrade, repair, rollback on failed installation, downgrade prevention, and
  silent uninstall. Stop/drain the running client safely when replacement is needed.
  Uninstall removes application/startup integration, not archives or delivery spools.
  Any future data-purge operation must be separate and explicit.

Illustrative commands for the **future** package, not supported commands for today's MSI:

```powershell
msiexec.exe /i Jazz.msi /qn /norestart JAZZ_CONTINUOUS_CAPTURE=1 JAZZ_UPLOAD_MODE=REVIEW_REQUIRED /L*v install.log
msiexec.exe /i Jazz.msi /qn /norestart JAZZ_CONTINUOUS_CAPTURE=1 JAZZ_UPLOAD_MODE=AUTOMATIC /L*v install.log
msiexec.exe /x {PRODUCT-CODE} /qn /norestart /L*v uninstall.log
```

The second command requests automatic mode; it does not supply or establish company
upload authority. The app must visibly report when that request cannot be activated.

## 4. Build and release pipeline

Proposed trigger policy, pending owner confirmation: **every merge to `main` builds both
installable artifacts; every versioned release publishes both production artifacts**.
PRs run validation/build checks without production signing secrets. Keep manual dispatch
for release-candidate qualification. Reuse existing scripts and CI jobs.

- Run every validator listed in `AGENTS.md`, macOS `swift build && swift test`, Windows
  Release tests/build, and MSI verification. Keep the validator lists in `AGENTS.md`,
  the CI contract job, and `contract/README.md` identical.
- Main builds produce a packaged macOS `.app` ZIP and Windows MSI from the same commit,
  with version/commit metadata and checksums. Clearly label development/unsigned artifacts
  as non-production. Define artifact retention and collision-free CI version numbering.
- A release tag `vX.Y.Z` produces both packages with one consistent product version;
  document its mapping to MSI version/upgrade identity rules and macOS bundle versions.
- Production macOS releases require Developer ID signing, notarization, stapling, and
  packaging the stapled app. Production Windows releases require Authenticode signing
  and timestamping of application binaries and the finished MSI, with signature checks.
- Provision certificates, notarization credentials, enrollment trust, and signing access
  through protected CI secrets/environments or a managed signing service. No credentials
  in Git or command-line arguments; signing jobs require appropriate release permissions.
- Gate publication on both platform builds and checks. Attach both packages and checksums
  to the same GitHub Release; do not mark a partial or unsigned release production-ready.
  Use a draft/staging release until the pair is qualified, and record the exact commit.
- Signing identities, credentials, hardware access, and server test access are explicit
  delivery dependencies, not reasons to quietly ship a reduced artifact.

## 5. Multi-workstation pilot, continuous screenshots, and network impact

**Completion requires a successful Microsoft Intune deployment and sustained capture pilot
across multiple representative customer-managed Windows workstations.** One developer PC,
a local MSI installation, synthetic tests, or a successful CI build is not sufficient.
Agree the workstation count, hardware/user/network mix, test duration, and measurable
pass/fail thresholds with the customer before the pilot; record these in the test plan.

### Pilot and enablement strategy

Deliver a short rollout/test strategy before enabling continuous capture broadly:

1. **Prepare:** identify test devices and users, obtain Intune/test-server access, agree
   privacy/notice requirements and support contacts, and establish a no-capture resource
   and network baseline. Record the exact package, app version, and effective policies.
2. **Deploy through Intune:** install on a small multi-workstation test group using the
   intended production assignment and execution context, including logged-out devices.
   Verify detection, first login, enrollment, effective policy, startup, upgrade, and
   uninstall. Keep Intune deployment status and client-side evidence, including failures.
3. **Qualify sustained capture:** run concurrent capture sessions across the workstations
   and repeated bounded sessions on each workstation over an agreed representative work
   period. Include continuous screenshot capture, real application switching, multiple
   monitors/DPI settings, labels/audio where enabled, and session rotation. Verify archive
   attribution, evidence completeness, privacy filtering, playback, and delivery with no
   cross-user/device mixing, duplication, or unexplained loss.
4. **Exercise disruption and contention:** combine capture with queued uploads, review,
   and other normal desktop/network activity. Cover lock/unlock, sleep/wake, reboot,
   user switching, offline periods, constrained links, and simultaneous reconnect/backlog
   draining across devices. Measure CPU, memory, disk growth, and UI responsiveness too.
5. **Expand in stages:** enable policy for a limited Intune group, review measurements,
   then expand only after agreed thresholds pass. Document how administrators disable
   continuous capture or automatic delivery and roll back deployment/configuration
   without deleting canonical archives or durable queued packages.

Continuous screenshotting needs an explicit capture policy, not an assumption that the
current sparse click-triggered screenshots suffice. Specify cadence/triggers, resolution,
encoding/quality, unchanged-frame handling, resource limits, and permission/privacy gates.
Start from existing capture capabilities; qualify any new behavior on both platforms and
update shared contracts if its emitted semantics change. Do not silently introduce screen
video or capture excluded/secure content. Apply capture-size optimizations before archive
finalization; never re-encode or mutate an already queued immutable package.

For this pilot, concurrent sessions means sessions across multiple workstations plus
successive sessions per workstation. Confirm whether simultaneous Windows user/RDP sessions
on one workstation are also required; do not interpret this as permission to run competing
capture engines in one user's desktop session.

### Required network-impact report

The customer has explicitly raised network-capacity concerns. Deliver measured results,
not an assurance that traffic will be small. Continuous local screenshot acquisition does
not itself imply continuous upload: measure capture generation and delivery separately,
including any separately opted-in live Coach/compatibility traffic.

- Compare idle/no capture, manual capture, continuous screenshots with review-required
  delivery, and continuous screenshots with authorized automatic delivery. Include typical
  and high-change desktop activity, the agreed screenshot settings, and optional audio/live
  features. Use representative corporate LAN, Wi-Fi, VPN/proxy, and constrained connections
  from the supported customer environment.
- Report screenshots/minute, average and high-percentile screenshot size, archive bytes
  per session and captured hour, upload/download bytes per device-hour/day, request counts,
  average and peak bandwidth over stated sampling windows, and upload completion latency.
  Record sample sizes, duration, settings, and workload so results are reproducible.
- Account for control-plane/enrollment/polling/live traffic, retries, failed transfers,
  and protocol overhead—not just final ZIP sizes. Separate Intune installation/update
  traffic from steady-state capture/delivery traffic.
- Measure synchronized session completion and fleet reconnect after an outage: peak load,
  retry amplification, backlog size/age, time to drain, and impact on normal business traffic.
  Distinguish device-generated bytes from WAN traffic affected by deployment caching.
- Extrapolate to the customer's expected active workstation count and working hours using
  measured per-device rates. Show assumptions, typical and worst-tested fleet bandwidth,
  daily volume, and outage recovery scenarios; do not present estimates as measured fleet
  results. Sustained upload capacity must exceed generation rate to avoid growing backlogs.
- Propose and validate necessary controls using measurements: screenshot cadence/size,
  bounded upload concurrency, bandwidth limits, staggered delivery, retry backoff/jitter,
  or upload scheduling. Document defaults, policy ownership, latency/evidence-quality
  tradeoffs, and offline disk requirements. Controls must preserve authorization, privacy,
  immutable retry bytes, and local data; never solve congestion by silently dropping evidence.

Agree acceptable per-device and fleet bandwidth, capture overhead, backlog recovery time,
and evidence-quality thresholds with the customer. Deliver the report and pilot evidence
for sign-off; unresolved threshold failures block completion and broad rollout.

## 6. Acceptance evidence and delivery order

1. **Inventory and decisions:** agree baseline commit, complete the parity matrix, settle
   the open questions below, and approve the automatic-upload ADR with the server owner.
2. **Parity implementation:** close every required matrix row with tests and real-Windows
   evidence; finish production enrollment and real delivery rather than relying on stubs.
3. **Policies and deployment:** implement the four policy combinations and qualify MSI
   installation under both interactive and enterprise execution contexts.
4. **Release automation:** demonstrate a main build and a paired, signed release candidate.
5. **Customer pilot and sign-off:** qualify that exact candidate through Intune across
   multiple workstations, complete sustained/concurrent capture and screenshot tests,
   and obtain sign-off on the measured network-impact report before declaring completion.

Definition of done:

- No unapproved parity gaps; shared golden fixtures pass for both clients and server mirror.
- Physical Windows qualification covers capture, media, privacy, workshop/Coach behavior,
  offline review/playback, enrollment, actual server delivery, and governed execution.
- Policy tests cover all four combinations, absent/invalid company authority, policy
  changes/revocation, pauses, session boundaries, and no retrospective backlog release.
- Recovery tests cover crash/reboot, offline operation, expired credentials, disk pressure,
  retries, rejection/cancellation/quarantine, and byte-identical immutable queued packages.
- Clean-VM installation tests cover interactive, silent SYSTEM/no-login, first user login,
  multiple users, upgrade from the existing installer, repair, downgrade refusal, failed
  install rollback, and uninstall with local data retained. Demonstrate installation,
  upgrade, detection, and uninstall through Microsoft Intune on representative managed
  Windows PCs, not just `msiexec` locally. MSI table verification alone is insufficient.
- The multi-workstation Intune pilot in section 5 passes the agreed duration, coverage,
  and resource/network thresholds. Deliver the enablement/rollback strategy, deployment
  evidence, sustained-session results, and network-impact report with customer sign-off.
- Release evidence includes signature verification, macOS notarization/stapling checks,
  both downloadable artifacts, matching versions/commit, and a deployment runbook.
- Update Windows/macOS documentation and the parity matrix to describe verified behavior.

## Decisions needed from the product/deployment owner

1. Which Windows versions/architectures must ship (proposal: Windows 11 x64 first)? Are
   Windows 10, ARM64, RDP/VDI, shared PCs, or devices without TPM required?
2. Intune is confirmed and mandatory. Who provides access to the customer's Intune test
   environment and managed PCs? Confirm the Intune deployment context and whether the
   current per-user installation must remain supported.
3. Confirm that `AUTOMATIC` means **no per-session human approval**, backed by authorized
   company policy. Who owns/provides that policy on the server, and may users change modes?
4. What continuous session duration/inactivity defaults and Stop/Pause behavior are desired?
5. Approve the proposed main-build plus tagged-release pipeline, or choose release-only
   packaging. Who provides Windows signing and Apple distribution/notarization access?
6. Which macOS commit defines parity at acceptance, and who signs off the matrix and
   physical Windows qualification?
7. How many pilot and eventual production workstations, which network environments, and
   what test duration are representative? Who approves bandwidth/resource limits and the
   network-impact report? Are simultaneous user/RDP sessions on one PC in scope?
8. What continuous screenshot cadence and evidence quality are required, and who approves
   the staged Intune enablement and rollback strategy?

## Reference material

- [Repository rules](../AGENTS.md) and [shared contract](../contract/README.md)
- [macOS feature and release guide](../macos/README.md)
- [Current Windows implementation/installer overview](../README.md#windows-development)
- [Archive delivery ADR](adr/0003-confirmed-archive-delivery.md)
- [Device-bound identity ADR](adr/0004-device-bound-enrollment-identity.md)
- [Existing CI](../.github/workflows/ci.yml)
- [Real-Mac qualification model](REAL_MAC_QUALIFICATION.md)
