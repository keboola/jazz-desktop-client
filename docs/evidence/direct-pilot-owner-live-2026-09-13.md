# Owner-authorized signing and fresh live attempt — 2026-09-13

## Owner correction — authoritative, not agent inference

The owner explicitly confirmed entering the password in the last native macOS Keychain dialog.
Prior cleanup explains why no dialog/item was subsequently present. **The old receipt must not be
used to characterize that owner approval as unresolved.** The owner authorized signing-key access,
one fresh scoped capability, live launch/read/E2E and scoped cleanup after completion/abort/expiry.
Any new prompt was to remain alive without password handling, bypass or Deny.

## Observed result: signing/issuance/preflight succeeded; harness aborted before live read

Operation (`$OP`): `/tmp/jazz-continuous-eaa688eb/direct-client-pilot/owner-live-s8X0xw/`.
Reviewed source remains3dced1d; no application source changes. The accepted e92bc2c staged package
and its ZIP remain intact: a separate operation copy was signed.

1. **Stable signing succeeded.** Existing `Jazz Dev Code Signing` identity, bundle
   `dev.jazz.capture.direct-pilot`, strict verification and pinned certificate requirement passed.
   Initial signing returned normally; the fresh pilot-only public trust update was also signed.
   No signing wait/new prompt was observed. No signing-key export or ACL alteration.
2. **One real scoped token/capability issued at09:04:39Z through configured kbagent SDK.**
   Token7576085; generation3; bundle`jdb_a499501a4c56f124ac95df1c1ddf23eb`;
   expiry`2026-09-13T09:09:32Z`. Project3044, source`jazz-qual-fabe8a60bd98`, exact write-only
   bucket`in.c-otlp-jazz-qual-fabe8a60bd98`. Verified `isMasterToken`, `canManageBuckets`,
   `canManageTokens`, `canReadAllFileUploads` allfalse; componentAccess empty. Device/source binding
   retained. Fresh pilot-only Ed25519 private key remained in memory; public trust pinned separately
   in the signed app. Signed envelope transferred only through stdin into an **add-only** isolated
   Keychain item with the existing restricted trusted-application policy. No operator credential
   installed as device authority. Keychain insertion returned success; this is **not app-read proof**.
3. **Exact newly signed executable preflight succeeded at09:04:41Z.** Accessibility, Screen
   Recording and microphone reported granted; `captureStarted:false`, `legacyOwnersConstructed:false`.
   This is a fresh direct-executable observation, not a retained old TCC receipt.
4. **The agent's qualification harness then aborted before menu-bar launch/Start/Keychain read.**
   `live.py` required the already-open owned TextEdit stimulus to still pass `stimulus check`.
   That guard returned nonzero. The assertion recorded **“Synthetic window not foreground”**.
   The helper checks both foreground application and owned-window identity; its particular exit
   code/output was not retained. Therefore the evidence establishes **failure of the synthetic-window
   ownership/foreground guard**, not which subcheck failed, and not a native capture or Keychain defect.
   An earlier guard passed when the document was initially opened; the harness incorrectly assumed
   that preparation-time foreground state would persist through subsequent work.
5. **Authorized abort cleanup completed at09:04:41.819769Z.** Token deleted and absent from live
   token listing; exact isolated item deleted and subsequent metadata-only lookup returned not found.
   Source and signed package retained. No menu-bar pilot process ever launched, no actual app credential
   read result, no Start/Resume/Pause/Stop execution, no native capture or uploaded media.

This was an avoidable qualification-harness abort, **not missing owner approval or a proven external
platform limitation**. No second token was minted under the one-fresh-capability instruction.
Before another authorized attempt, the harness must foreground/revalidate the exact owned synthetic
window immediately before Start (only after any native prompt has been resolved), and retain the
specific guard result rather than assuming earlier foreground state. Do not replay these used scripts.

## Signed package retained

App: `$OP/Jazz Direct Pilot.app`.
ZIP: `$OP/Jazz-Direct-Pilot-3dced1d-signed-s8X0xw.zip`.

- Executable SHA256: `96e0f45cfb2cd4551200b787bafa8eaefd0152c2da219d7ccbfd677f23edbe55`.
- ZIP SHA256: `20b4af696a1d13ddf4f438f1372eadad1ef7350a042bdfc90adb0af04f2ef900`.
- ZIP length:8,966,426bytes.
- Strict signed identifier/certificate requirement verified again after abort.
- No current token/item/capability; no install or replacement of either `/Applications` bundle.
- The old e92bc2c preparation signing gate is superseded by this successful signed-copy evidence.

## Preservation and outcome boundaries

At09:07:04Z, two read-only spool scans match the pre-operation baseline:
`~/.jazz/spool` SHA256`1ecda58c6654247c5a6547c42294e8b712418632fb42957da19f40fefb39751a`;
legacy executable SHA256`4ec1e731a217e314d53ccf2ece6d23c646f342c6a044e4ced566d0575e2e0737` unchanged.
No pilot process. Pilot-tagged Files remain empty; source table remains the historical2 rows.
No observation IDs, media parity, sustained latency/resource/control metrics or E2E PASS are claimed.
No deferred server work or terminal-status. Owner's prior password-entry confirmation remains valid;
this failed new attempt supplies no evidence against it.

## Private receipt SHA256

| Receipt | SHA256 |
| --- | --- |
| `owner-authorization.json` | `d6696377ae13de20b8bf2c7fdb785b776d7b2e11385a8b7f30d66baabca646fc` |
| `authority-installed.json` | `a77fc509d28929a02e17f8b26660375c539d9eec07165b684299f1e7902b179e` |
| `live-preflight.json` | `17f531076a29c71e0cf410347f5aee1e442d0d0f63f1e1b725b0374eb4bd5673` |
| `live-blocker.json` | `750098bb1e1d05e1d15a3c80802d8f47eb5c8a9c1494cce7de77742d9efc58cd` |
| `cleanup-complete.json` | `cf0e69b1d41932c7f80ef767582e6e1748eafe1df0243f551114c51b1e5ce093` |
| `post-abort-verification.json` | `809bbddc87ace1a708ff1b4095ecbae9e1115ea38b5d0e9d417a7ac92eb2de75` |
| `signed-package.json` | `d5cc2a5bac04442daa5f15b5702ab50658fe95a06edce008f4e49e5ac62f1f20` |

Additional executed-script hashes are retained in `receipt-hashes.json`; original scripts/receipts
are not rewritten to conceal the harness failure. Scope is frozen; no production-code/test changes.
