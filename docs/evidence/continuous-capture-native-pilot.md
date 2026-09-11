# Native pilot — installed, qualification blocked

The user confirmed no recording and authorized installation. Main agent only; no subagents.
Desktop source `a2a019f` was release-built, dev-signed and installed at
`/Applications/Jazz Capture.app`: **0.25.0 / 166.a2a019f**. The old app quit gracefully.
Old/new designated signing requirements match exactly; both passed strict/deep verification.
The old bundle is retained at `/tmp/jazz-native-pilot.h2UCjK/` (backup and original).
Existing enrollment trust configuration was preserved; no public trust fields were present,
so signed enrollment import continues to fail closed rather than inventing trust.

No recordings, archives, spools, preferences or Keychain entries were manually modified. No capture
Start or archive confirmation was issued. This is a controlled local pilot, **not a qualified release**.

Observed the installed executable running and one `Jazz Capture — Settings` window. Automated UI
inspection timed out; Accessibility preflight for the automation process is **false**. Screen
preflight is true but its diagnostic full-screen image is black. Public console/login flags and
awake-display status do not prove unlocked state. These observations do not establish the installed
app's own TCC status, setup contents, responsiveness or recording correctness.

Next: user enables Accessibility for the terminal/automation host and provides an interactive
desktop, then exercise setup, Start/Stop, labels/audio, local playback, idle/time splitting and
controlled privacy boundaries. Do not reset Jazz permissions, force-kill capture, inspect passwords,
or treat blocked automation as a successful native test. Sustained and authenticated integration
remain open; new archive delivery still needs explicit confirmation.

Detailed receipt and logs: `/tmp/jazz-continuous-eaa688eb/native-pilot/install-receipt.md` and siblings.

## Follow-up — September 8 recording acceptance gate (2026-09-11)

The user explicitly requires the September 8 recording to reach the server with accessible media
before this work can be called complete. This gate remains open for actual media retrieval/playback.

Accessibility became available after the user enabled VS Code. Direct AX inspection of the pilot
showed its three capture permissions granted, but setup was blocked by the expired MVP credential.
AppleScript Automation remained denied; no extra permission, password or TCC reset was requested.
The authenticated Devices page showed the same `ankhmac` / `process-mining` device. Its standard
rotation UI produced an explicitly marked MVP handoff with the same project/company/Area/device
and expiry `2026-09-11T23:09:30+0200`. Issuance is **not** successful desktop import: the clipboard
changed before the guarded secure-field transfer, and the reveal window later became unavailable.
The transfer refused rather than pasting different clipboard contents. Installed enrollment metadata
still has its original expired date. No secret was printed, written to these evidence files, or put
in command arguments; no trust guard or archive confirmation was bypassed.

Fresh authenticated browser navigation to the exact evidence-review API returned the September 8
archive. A local runnable comparison checked the full response against its unchanged delivery ZIP:

- Archive `ar-01a0801f-21f6-7688-a476-fd3302a2c242`, revision 1; capture
  `cap-01a0801f-21f6-7072-974c-4066a1e50a98`.
- Server acceptance `2026-09-08T10:30:53.777679Z`; scope
  `default / process-mining / __unassigned__`; duration 1,781,993 ms (29m 42s rounded).
- All 376 observation IDs match. All 236 artifact IDs, kinds, lengths, media types and SHA-256
  metadata match: 235 screenshots and one narration audio artifact.
- Every local artifact blob hash and length passes, as do ZIP integrity, exact package length
  20,261,404 bytes, and exact ZIP SHA-256
  `68563109b7e5caad816928bbd16b7c66c02209e08bc78807aee9dcdd96179010`.
- Server content digest equals the local immutable package's
  `d0de309b79d018ef5483bf5352007533740f9ab277d3705d2a01e457aab1e8a3`.
- The response retains five gaps: four intentional omissions and one capture-loss gap. Matching
  evidence does not erase those source limitations.

This establishes current server acceptance and metadata parity, **not downloaded server media
bytes or playback**. No redundant resubmission was attempted and no local queue/package was edited.
A screenshot media navigation was attempted, but subsequent Chrome AX window handles resolved to
an application/cyclic tree; the inspector refused that tree. It is not a media-response success.
An authenticated fetch-tool alternative was unavailable because no authFetch profile is configured.
Do not infer unlocked state, HTTP status, media rendering, or completed qualification from these
failed attempts. An interactive desktop/browser is needed to finish credential import and media/UI
checks without guessing focus or bypassing permissions.

Private scratch evidence: `september8-server-review.json`, `check-september8.py`, and
`september8-verification.json` in `/tmp/jazz-continuous-eaa688eb/native-pilot/`. Only the bounded
non-secret results above are published. Main agent only; no independent-review claim.
Budget snapshot through parent entry `91932f67`: 3,877,098 of 4,700,000 reported input/output tokens
used, excluding cache reads; 822,902 remained at that snapshot. Later work is additional.
