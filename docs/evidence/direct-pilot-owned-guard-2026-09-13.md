# Owned synthetic guard and second authorized attempt — 2026-09-13

**Owner's prior password entry remains explicitly confirmed. Neither failure below is an
unresolved Keychain-approval finding.** No production capture/contract changes.

## Implemented and checked

`9a1d7fa4688c44b545299eb0526e21be7c8c6a43` adds
`macos/qualification/owned_synthetic.swift`:

- Dedicated, operation-owned TextEdit file, matched by exact canonical document URL—not title alone.
- Explicit open/raise/activation immediately before launch and again before Start/Resume.
- Last-moment checks of pinned PID, bundle, focused owner, exact document, finite/stable geometry,
  unchanged focused window/frontmost PID and one matching on-screen window. No background fallback.
- Every stimulus event is guarded again; field values/password controls are never read. Activation
  refuses to steal focus while a SecurityAgent process is present.
- Sanitized JSON includes each subcheck, AX error codes and geometry only for the owned document.
- **13 offline assertions pass**, including wrong PID/bundle/document, missing/invalid/moving frame,
  foreground/focus changes and ambiguous screen geometry. No native AX/capture calls in self-test.

Live checks using the dedicated `Jazz-pilot-synthetic-pbS3fm.txt` passed. At the actual attempt,
**all four activation/revalidation checks immediately before launch/Start passed**, with TextEdit
PID75255, matching focused owner, exact owned URL and unique673×439 window at(108,289).
The original f1a809f foreground defect was fixed, not merely republished.

Full existing Swift suite: **914 tests,1 expected skip,0 failures**,34.721s; six validators and build
passed. The helper is standalone qualification code, not added to the capture executable.

## Second fresh authority and actual launch

Operation (`$OP`): `/tmp/jazz-continuous-eaa688eb/direct-client-pilot/owner-second-pbS3fm/`.

- One **second explicitly authorized** fresh SDK token7576100, generation4, bundle
  `jdb_b71440126177de7172066f81d33e00a7`, created09:24:39Z; finite expiry09:29:32Z.
- Exact source`jazz-qual-fabe8a60bd98` and bucket`in.c-otlp-jazz-qual-fabe8a60bd98` write permission;
  four master/manage/read-all flagsfalse, componentAccess empty. Old7576085 was not replayed.
- New pilot-only public trust signed with existing `Jazz Dev Code Signing`; private key RAM-only;
  add-only restricted isolated Keychain insertion succeeded. No operator credential on device.
- Reviewed executable source3dced1d unchanged; signed executable SHA256
  `790b6cb13df5c313d02b91934b7235594f232707fa62b4f94b4b8ac7a8ca0788`.
- New exact-executable preflight09:24:41Z: all three TCC statuses granted, no capture/legacy owners.
- Menu-bar pilot launched **once**, PID25423 at09:24:42.559796Z, in the operation-local signed bundle.
  Neither `/Applications` bundle was replaced.

## Separate menu-path harness defect found and fixed

At09:24:45Z the reused menu helper returned failure before confirmed Start. The runner recorded
“Pilot menu action unavailable” and aborted. Its original return code/output was not retained.

The helper's identity guard compared Foundation's resolved app path against a literal produced
by Python `Path.resolve()`. For the **actual existing staged bundle**, the offline reproduction proves:

- Python literal: `/private/tmp/.../Jazz Direct Pilot.app`.
- Foundation `Bundle(...).bundleURL.resolvingSymlinksInPath().path`: `/tmp/.../Jazz Direct Pilot.app`.
- Old literal comparison rejects this same owned bundle before AX menu actions.
- Normalizing **both operands in Foundation** accepts it without loosening the PID/bundle/path guard.

`9d928c67a53796cac8fb5dbc7541f8c1a8dc9948` adds the corrected reusable
`macos/qualification/pilot_menu.swift`, with sanitized identity/menu/action subchecks on every exit.
**Six offline assertions pass**, using an existing owned test directory for filesystem alias resolution;
legacy app, wrong directory and missing process URL remain refused. The first test fixture incorrectly
used a nonexistent path, which Foundation does not resolve equivalently; that fixture was corrected.
A separate check against the actual signed bundle reproduces old failure/new success **without launch**.

The corrected menu helper was added **after abort** and was not used in this consumed live attempt.
No third capability or second launch was silently introduced. This remains local qualification code,
not an observed native Keychain, TCC, transport or production-source failure.

```sh
swiftc macos/qualification/owned_synthetic.swift -o /private/tmp/owned-synthetic
/private/tmp/owned-synthetic --self-test
swiftc macos/qualification/pilot_menu.swift -o /private/tmp/pilot-menu
/private/tmp/pilot-menu --self-test
# Native invocation contract for a future authorized operation:
# owned-synthetic activate OWNED_FILE EXPECTED_TEXTEDIT_PID
# owned-synthetic check OWNED_FILE EXPECTED_TEXTEDIT_PID
# pilot-menu PILOT_PID 'Start / Resume' EXACT_PILOT_APP_PATH
```

## Cleanup, preservation and unproven E2E

Authorized abort cleanup completed09:24:51.423091Z: token7576100 absent from live listing, exact
pilot item deleted and metadata lookup not found, pilot exited. No password was read/entered,
no native prompt was observed/denied, no old authority reused. Source and signed copy retained.

Two post-abort spool scans match baseline SHA256
`1ecda58c6654247c5a6547c42294e8b712418632fb42957da19f40fefb39751a`; legacy executable remains
`4ec1e731a217e314d53ccf2ece6d23c646f342c6a044e4ced566d0575e2e0737`. No spool writes/replay/cleanup.
The nonsecret acceptance ledger still records generation2, not this attempt's4.

The bounded read-only receiver ran against the owned Stream table: **zero new observations,
artifacts or verified Files**. Start/Keychain read were not confirmed; several-minute capture,
Pause/Resume/Stop, exact media parity, latency/drops/resources remain unqualified.
No E2E PASS, deferred server work or terminal-status. Future execution must use the corrected menu
helper and retain its output; the two issued attempt tokens are consumed/deleted, not waiting for approval.

## Receipt SHA256

Private receipts under `$OP`; complete inventory in `receipt-hashes.json`:

| Receipt | SHA256 |
| --- | --- |
| `guard-offline.json` | `cfc9db06df2cc93a45e33b4fbf337886a6f5f00ffa15adec1bde5cbe84626959` |
| `guard-results.jsonl` | `372d1d1fc373f2ef318736b2cfaeb2f855435d21530cd9c55ac398e407c784ec` |
| `menu-offline-final.json` | `c20f5361a5f5179a52174f7508f2a5bb25aac17a4638fd0e644ab41c33c40cfd` |
| `path-alias-regression.json` | `4a68415ba93978c5939088a98270cb98eede237846d9aa2274342f9f07e33a4d` |
| `authority-installed.json` | `4925052c09ee63010d94cca3934ae7a7d9caeec21068baeec39fbeb3d0409caf` |
| `cleanup-complete.json` | `a7c9e4b47800551499cbb2758bb875e8cdd626f5e33e0c42169dffa516b35328` |
| `delivery-verification.json` | `5d24ad2fe9f47b87b1497b728f10bbb20becabe75095dea1943e40d2a937e19c` |
