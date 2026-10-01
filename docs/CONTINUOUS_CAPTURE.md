# Continuous desktop capture

`keboola/jazz-desktop-client` is the sole product source of truth for this feature on Windows and
macOS. The Windows pilot at `keboola/jazz-windows-continuous`, commit
`45c4a9c9fb5c43f96a9bb49f6ac1e5305a023aae`, is the port's reference, not a release or update channel.

## Enable

Enable **Capture continuously** in Settings, then start a capture or relaunch Jazz. The setting is
`continuousCapture` in Windows `settings.json` and macOS UserDefaults. It defaults to false on both
platforms; upgrading an existing profile does not turn recording on. Operating-system permissions
still apply. Login registration is separate from capture consent.

| Action | Windows and macOS behavior |
| --- | --- |
| Launch with continuous mode enabled | Start capture through the existing startup/preflight path. |
| Pause capture | Close the label/microphone, drain admitted work, and commit locally. No automatic review dialog. |
| Resume capture | Start a fresh capture; a successful start clears the in-process pause. |
| Relaunch after a continuous-mode pause | Start again. The continuous-mode pause is not persisted. |
| Remain paused | A reminder every 30 minutes; a reminder never starts capture. |
| Mark session end | Commit the current capture, then start a new session with fresh IDs. A failed commit never restarts capture. |
| Label current task | If voice was enabled for this capture, ask whether to record this label. Declining still opens the label without audio. |
| Quit | Commit locally without rollover. Never confirm, export or enqueue an archive implicitly. |

On macOS, Pause also cancels a rollover still draining local work; reconnect cannot undo a pause.
BDM workshops keep their existing separate lifecycle. On Windows, a failed safe stop retains the
existing retry/fault presentation instead of claiming that capture is recording.

## Preserved desktop-client rules

This is a behavioral port, not a replacement of the newer desktop-client tree with the older pilot:

- The existing Windows **Start local capture automatically** option, switch and managed policy keep
  their persistent-pause behavior outside continuous mode. A previously saved pause is respected
  even if continuous mode is enabled; explicitly Resume to clear it. Malformed policy still blocks
  automatic start. Continuous mode does not override policy precedence.
- Screenshots and excluded apps retain their existing settings. Capture policy is frozen per
  session; changes apply to the next capture. The port does not force screenshots back on against
  a saved preference.
- Voice is allowed only by the session's modality setting, per-label confirmation in continuous
  mode, and OS permission. The pilot's remembered voice answer and remote consent-epoch reset are
  not imported; this port asks for each label. The microphone indicator reflects actual recording.
- Windows keeps its durable narration spool and existing live delivery. macOS keeps local-first
  confirmed archives and its explicit `liveCompatibility` migration policy (including that policy's
  credential prerequisite for automatic startup). No delivery or event-schema changes are made.
- Rollover leaves the completed local journal intact. It does not confirm, export, delete, or queue
  it. macOS sessions remain in the local Sessions list. Windows review remains available for the
  most recently stopped capture; earlier rollover journals remain on disk.
- Pilot-specific MSI bundles, embedded credentials, updater/release repositories and remote fleet
  policy are not copied. Existing desktop-client installers and update channels remain authoritative.

## Verification

The existing CI matrix builds and tests both clients, validates the shared contract, and exercises
the Windows MSI gates. New tests cover startup opt-in/backward compatibility, malformed settings,
pause/reconnect, continuation failure/shutdown conditions, reminders, and per-label voice refusal.
Existing journal/completion tests continue to cover durable commits without confirmation.

Interactive qualification still requires a Windows desktop and a Mac with granted permissions:

1. Opt in, relaunch, and check visible recording; start without delivery credentials in the default
   local-first mode.
2. Open a label, decline voice, and verify the label is active with the microphone off. End it;
   open another, allow voice, and verify the microphone stops at label end or Pause.
3. Mark session end with a label open. Verify the old journal is committed, the new session ID
   differs, and no confirmation/export occurred.
4. Pause, reconnect/provision credentials, and wait for the reminder. Verify capture stays paused.
   Resume; verify reminders stop. Relaunch after another pause; verify continuous capture resumes.
5. On macOS, Pause or Quit during a rollover drain; verify it does not restart. Test without required
   capture permissions; failure must remain visible rather than reporting recording.

A green build is not evidence that these interactive scenarios were performed.
