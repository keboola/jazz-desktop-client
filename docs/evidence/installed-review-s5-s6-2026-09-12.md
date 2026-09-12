# Installed-native / September-8 review checkpoint — S5 and S6 remain open

[Exact sanitized receipt](installed-review-s5-s6-2026-09-12.json). No installed-app action,
credential submission, TCC/browser security change, capture-policy change or production-data mutation.

## S5: read-only installed-app preflight

At 2026-09-12T14:37:57Z the installed app was **not running**. Version0.25.0/build166.a2a019f,
executable SHA256 `4ec1e731a217e314d53ccf2ece6d23c646f342c6a044e4ced566d0575e2e0737`, and the
pinned designated signing requirement match the approved pilot. The bounded archive-queue scan
observed one ready, one cancelled and one reconnectRequired record. Other delivery spools and
safe launch behavior are not attested. Zero automatic candidates in this one scan is **not** proof
that launching/re-enrolling cannot release backlog.

`macos/qualification/installed_app.py` is a read-only harness: fixed codesign verification and process
inspection, bounded metadata-only queue scan, exclusive0600 receipt. It never launches/signals the
app, presses controls, reads credentials/TCC databases, changes settings or writes capture data.
Six deterministic tests check command restrictions, exact process matching, unknown/unsafe queue
handling, byte-preserving inspection and refusal to infer qualification from absence/empty queues.
Those tests are **not installed-native behavior qualification**. Start/Stop/Pause, masking/TCC,
sampled media, idle/relaunch/interruption and sustained resource bounds remain unqualified.

External prerequisite: an owner-controlled visible installed-app session after all pending-delivery
and local-spool safety is established without changing policy or releasing backlog. No automatic
launch, enrollment renewal, capture action or installed-app replacement is authorized by the receipt.

## S6: real server-media attempt reached authentication, not media

Used the existing Chrome profile and exact scoped screenshot endpoint for September8 archive
`ar-01a0801f-21f6-7688-a476-fd3302a2c242` / capture
`cap-01a0801f-21f6-7072-974c-4066a1e50a98`, Companydefault / Areaprocess-mining / Process__unassigned__.
Native browser navigation/Save produced **10027-byte HTML containing a password form**, not the
expected175342-byte JPEG. No image element was present. HTTP status was not observed, so no401/403
claim is made. No password was submitted, and the exact temporary login HTML was removed after
sanitized classification/hashing. No audio request followed the authentication barrier.
Chrome's JavaScript-from-Apple-Events control is disabled and was left unchanged; Safari had no
existing target tab. No cookie/Keychain extraction or credential fallback was attempted.

The immutable local20261404-byte package still hashes to
`68563109b7e5caad816928bbd16b7c66c02209e08bc78807aee9dcdd96179010`, and its delivery record remains ready.
The376 observations /235 screenshots /one audio /five gaps are **historical authenticated metadata**,
not newly retrieved server bytes or current playback evidence. No gaps or package bytes were changed.

External prerequisite: restore the normal authenticated session at the existing app origin, without
sharing credentials with the harness. Then retrieve/hash the actual JPEG and MP4 and use the exact
archive in scoped review to render screenshots and play/scrub audio. Server-byte parity, rendered
screenshots and audio playback/scrubbing remain **false**, not replaced by local ZIPs or synthetic media.

Local receipts/logs: `/tmp/jazz-continuous-eaa688eb/s5-s6/`. The first harness invocation used the wrong
codesign inline-requirement syntax; it was corrected and regression-tested before the final receipt.
That diagnostic was a harness error, not an installed-signature change or re-signing operation.
