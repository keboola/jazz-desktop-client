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
