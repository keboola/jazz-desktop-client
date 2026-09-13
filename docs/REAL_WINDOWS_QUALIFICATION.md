# Real Windows qualification

## Issue #42 interactive evidence

On a disposable clean standard-user profile, retain sanitized steps/screenshots proving that first
evidence is *no window at launch* -- the tray icon alone -- followed by the tray-opened status
window (including its capture-off state), tray reopen route, explicit capture start, second-launch
foreground activation, a separate user profile, and a newer-release link. Automated evidence only
proves bytes, process identity and protocol behavior; it does not prove visible tray/foreground UI,
consent comprehension, SmartScreen, microphone, scaling, or multi-display behavior.

This procedure separates evidence a hosted runner can prove from behavior that needs a person at
an interactive Windows desktop. It applies to the unsigned x64 MSI. ARM64 is not qualified.

### Issue #76 additions: capture at launch without the tray UI

**#76 adds two more interactive rows to the same evidence set**, both on a profile with no prior
`settings.json`: (1) write the canonical preset document from `windows/README.md`'s
"Configure capture at launch without the tray UI" section, then launch -- recording begins
immediately, with no window and no tray interaction; and (2) delete `settings.json` and launch
`JazzCapture.exe --capture-at-launch` -- recording begins immediately. Both are evidence that a
deployment can enable capture without anyone touching the tray UI, which #42's rows above do not
otherwise exercise.

### Issue #60 additions: managed capture-at-launch policy

**Slice 1 of #60 adds six interactive rows**, all on a clean standard-user profile, none
automatable: they require writing a real value under `HKLM` or `HKCU` and observing what an
installed client does across a relaunch, which the local (mutation-free) test suite cannot do.
**Acceptance boxes 1's installer half, 5's installer half, and 7 are not claimed by these six
rows** -- they require writing a value directly, not installing the MSI with a property, and an
Intune Win32 app in user context. Slice 2's own rows, below, close boxes 1 and 5's installer
halves; box 7 (the Intune package itself) still needs a real tenant.

0. **Seed the user's own preference first, while nothing is enforced.** With no value under either
   registry key, launch and tick **Start local capture automatically when Jazz opens** in
   **Settings**, then quit. This step exists because of the ordering trap below: once a policy is
   deployed the checkbox is disabled, so the user preference that steps 2 and 4 rely on can only be
   set *before* one exists.
1. **Managed policy, on.** From an elevated shell, write
   `HKLM\Software\Policies\Keboola\Jazz\CaptureAtLaunch = 1` (`REG_DWORD`). Launch as a standard
   user: recording begins immediately, with no window and no tray interaction. Open **Settings**:
   the checkbox is ticked, disabled, with *"This is set by your organisation's policy and cannot be
   changed here."* Open **Status and onboarding...**: it says capture starts at launch.
2. **Managed policy, "no opinion", falling through.** Quit, set the policy value to `0`, relaunch:
   the user's own tray setting from step 0 is honoured (recording continues), and the checkbox is
   ticked and **enabled** again, proving `0` is not an enforced-off decision and that nothing
   overwrote the user's preference while it was enforced.
3. **Malformed policy, beating a user setting and a launch switch that are both on.** With the tray
   checkbox ticked, write `HKLM\...\CaptureAtLaunch = "yes"` (`REG_SZ`), then launch
   `JazzCapture.exe --capture-at-launch`: idle, not recording, despite both lower layers being on;
   the Settings checkbox reads disabled with *"A setting deployed to this machine could not be
   read, so this cannot be changed here."*; **Status and onboarding...** shows *"Jazz Capture is not
   starting capture on its own"* with the exact detail from `windows/README.md`, and capture is
   still startable by hand from the notification-area menu.
4. **Policy removal.** Delete the `HKLM` value from step 3, relaunch: the user's own ticked
   preference from step 1/2 is honoured again, unchanged and unwritten by any of the enforced or
   misconfigured states above.
5. **Pause still beats an enforced-on policy.** With the managed policy back to `1` and recording,
   choose **Stop capture**; relaunch: idle. Choose **Start capture**; relaunch: recording resumes.

### Issue #60 slice 2 additions: the installer preference and Intune packaging

**Slice 2 adds two more rows.** The first is automatable and already covered in CI (see
`docs/WINDOWS_UPGRADE_QUALIFICATION.md`'s automated clean-runner matrix); it is repeated here only
as the real-machine confirmation the acceptance table asks for. The second genuinely needs a real
tenant and cannot be automated at all.

6. **Silent unelevated install with the property, on a clean standard-user profile.** As the
   standard user (no elevated shell), run
   `msiexec.exe /i "JazzCapture-<version>-win-x64-unsigned.msi" /qn /norestart
   JAZZ_CAPTURE_AT_LAUNCH=1`. The command returns `0` with no UI. Launch `JazzCapture.exe`:
   recording begins immediately, with no window and no tray interaction -- acceptance box 1's
   installer half. Inspect the registry: `HKCU\Software\Keboola\Jazz\Policy\CaptureAtLaunch` is
   `REG_SZ` `1`.
7. **The Intune package installs, is detected, and uninstalls on a clean standard-user profile.**
   Package the release triplet with `IntuneWinAppUtil.exe` per
   [`docs/INTUNE_DEPLOYMENT.md`](INTUNE_DEPLOYMENT.md), assign it to a **user** (not a device), and
   confirm: the app installs without an elevation prompt, Intune's detection rule (file-based, per
   that document) reports installed, and an uninstall from Intune removes it cleanly. This row
   needs a real Intune tenant and an MDM-enrolled device; it is not automatable and is not claimed
   by any CI job in this repository.

### Issue #48 additions: durable event spool and OTLP delivery

**#48 adds three interactive rows**, none of which the automated suite can substitute for, since a
crash/relaunch across a live spool and a real endpoint is exactly the seam automated tests fake:

1. **Offline accumulation.** Provision a bundle, start capture, break the network. The tray's
   `Streaming:` line shows `retrying N` with N climbing as events are produced; the spool
   accumulates files under `%LOCALAPPDATA%\Jazz\spool\events`. Restore the network: N falls to zero
   and the line returns to `up to date`.
2. **Restart survival.** Repeat step 1, and while offline **quit Jazz and relaunch it**. The spool
   still holds the same file count after relaunch, and the tray shows the same N; restoring the
   network drains them. This is the acceptance criterion ("exact bytes survive retry/restart") the
   automated tests cannot prove end to end on a real process boundary.
3. **No credential.** On a profile with no bundle, start capture. The tray shows `Streaming: not
   provisioned` with no `!` prefix, the capture status line independently shows recording, and the
   spool accumulates. Provision the bundle without restarting: delivery resumes and the spool
   drains, with no capture restart (#53 acceptance box 6).

A fourth row — correlated rows in the Keboola `logs` table with `jazz-win-dev` provisioned — is
issue #65's outstanding evidence, referenced here rather than claimed: it depends on a deployed
receiving endpoint this issue's automated and interactive evidence does not exercise.

### Issue #84 additions: narration audio delivery to Keboola Files

**Narration must be enabled first** — it is off by default (Settings, or the tray's "Narration"
checkbox) — before any of these rows can produce a clip at all.

1. **Offline accumulation.** With narration enabled, provision a bundle, start capture, break the
   network, declare and end a label so a clip seals. The tray's `Narration:` line shows `retrying 1`
   (or higher, for more labels); a blob-plus-sidecar pair accumulates under
   `%LOCALAPPDATA%\Jazz\spool\narration`. Restore the network: the count falls to zero, the pair is
   gone, and a `narration` row appears with a real `audio_file_id`.
2. **Restart survival mid-upload.** Repeat step 1, and while offline **quit Jazz and relaunch it**.
   The pair is still there after relaunch, and the tray shows the same count. Restore the network:
   the clip drains and a `narration` row appears with the Files id the earlier attempt already
   uploaded — the durable `filesId` stamp is what prevents a **second upload or a second Files id**
   across the restart. As with an ordinary event (issue #48), a crash landing between that row being
   admitted to the event spool and the narration pair being removed can still produce one duplicate
   row with the identical `audio_file_id` — accepted, at-least-once, exactly like the event spool's
   own equivalent window; it is a second upload or a second id this guarantee rules out, not a
   duplicate row under every possible crash instant.
3. **No credential.** On a profile with no bundle, enable narration and start capture. The tray
   shows `Narration: not provisioned` with no `!` prefix; the capture status line independently
   shows recording; a declared-and-ended label still seals a clip and it accumulates in the spool;
   **no narration row is emitted** while unprovisioned. Provision the bundle without restarting: the
   clip uploads and the row appears, with no capture restart.
4. **Correlated rows.** With `jazz-win-dev` provisioned, a `narration` row whose `audio_file_id`
   **resolves to a real object in Keboola Files** — the assertion that proves issue #84 fixed the
   defect, and the narration counterpart of issue #65's outstanding evidence. Referenced here, not
   claimed: it depends on the same deployed receiving endpoint issue #65 does.

## Safety boundary

Use a disposable Windows 11 VM or a dedicated standard-user account that has never run Jazz. Before
any mutation, both qualification runners refuse all of these footprints:

- `%LOCALAPPDATA%\Jazz`, even when empty;
- `%LOCALAPPDATA%\Jazz\App`;
- a `JazzCapture` process;
- a Jazz Capture MSI registration;
- the Jazz HKCU Run value;
- the Jazz Start Menu shortcut.

`-AllowInstalledProductMutation` is an acknowledgement, not a force switch. It cannot bypass that
preflight. Do not manually remove an existing profile to make the check pass: move the test to a
new account or disposable VM. The automated runner cleans only its exact candidate ProductCode,
the exact PIDs it launched, and sentinels whose current SHA-256 still matches the bytes it created.
It never recursively deletes the Jazz data root.

Keep evidence outside `%LOCALAPPDATA%\Jazz`. Use only synthetic, non-sensitive windows and narration
for interactive capture. Qualification reports intentionally exclude capture contents, usernames,
machine names, SIDs, absolute profile paths, environment dumps and credentials.

## Automated lifecycle

CI runs this after MSI structural verification and before artifact upload:

```powershell
$version = dotnet msbuild windows/installer/Jazz.Version.props `
    -getProperty:JazzProductVersion -nologo
pwsh windows/installer/tests/Invoke-MsiLifecycleQualification.ps1 `
    -MsiPath windows/installer/artifacts/Jazz.msi `
    -ExpectedVersion $version.Trim() `
    -EvidenceDirectory windows/installer/artifacts/qualification `
    -AllowInstalledProductMutation
```

The runner installs the exact MSI, verifies registration/files/Run entry/shortcut, launches only
the installed executable, records its exact PID/path and survival, stops only that PID, repairs from
the same MSI, launches once more, uninstalls the candidate ProductCode, and verifies three inert
data sentinels remain byte-identical. It then removes only its hash-matching sentinels.

Each quiet `msiexec` operation is bounded to ten minutes; interactive installer UI is bounded to
thirty minutes. On timeout the wrapper terminates only the process object it started and reports a
`TimeoutException`. The Windows Installer service may still be busy, so candidate-only cleanup is
also bounded and its failure is evidence. A timeout never permits broad process termination or
recursive removal of the Jazz data root. Workflow job timeouts are defense in depth, not the
per-operation bound.

Hosted CI does **not** prove that a tray icon or foreground UI was visible. Its report says only
that the expected executable started in the recorded session and survived the observation interval.

## Interactive matrix

The interactive runner is staged so no process waits across logoff and no arbitrary dirty profile
can be called resumable. Start from a clean non-elevated standard-user profile and a copy of the
exact release asset. Obtain its expected SHA-256 independently from the release checksum.

First install and create the primary run state:

```powershell
pwsh windows/qualification/Invoke-RealWindowsQualification.ps1 `
    -Phase Prepare `
    -MsiPath C:\qualification\JazzCapture-0.26.2-win-x64-unsigned.msi `
    -ExpectedVersion 0.26.2 `
    -ExpectedSha256 <64-hex-digest> `
    -EvidenceDirectory C:\qualification\primary-evidence `
    -ProfileRole primary `
    -AllowInstalledProductMutation
```

`Prepare` ends after installation and prints a random run ID. Its privacy-safe
`qualification-state.json` is DPAPI-authenticated to this Windows profile and binds the exact MSI
SHA-256, ProductCode, version, role and run ID. End the shell, log out and back in, then run:

```powershell
pwsh windows/qualification/Invoke-RealWindowsQualification.ps1 `
    -Phase Resume `
    -MsiPath C:\qualification\JazzCapture-0.26.2-win-x64-unsigned.msi `
    -ExpectedVersion 0.26.2 `
    -ExpectedSha256 <64-hex-digest> `
    -EvidenceDirectory C:\qualification\primary-evidence
```

`Resume` authenticates the state for the current Windows profile, compares every package binding,
and verifies the exact ProductCode is installed. A copied, edited, wrong-user, wrong-MSI or unsealed
state is rejected. Each answer is persisted immediately, so an interrupted Resume can safely be
rerun. The runner accepts only `passed`, `failed`, `blocked`, or `not-run` and records no free-form
test content. Exercise:

1. Actual unsigned SmartScreen or organizational-policy behavior.
2. Visible tray icon/menu, quit, and Start Menu relaunch.
3. Capture start/stop, labels, screenshots, local review, quit and relaunch using synthetic content.
4. Login startup.
5. Microphone allow, deny, and revoke.
6. Normal and elevated UI Automation targets.
7. Secure desktop, which must never be reported as successfully observed.
8. 100%, 150%, and 200% scaling.
9. Multiple displays, preferably with mixed scaling.

### Second profile without losing continuity

Keep the primary run installed and fast-switch to a genuinely clean second standard-user profile.
Use the same MSI and digest, a separate evidence directory writable by that profile, and the run ID
printed by primary `Prepare`:

```powershell
pwsh windows/qualification/Invoke-RealWindowsQualification.ps1 `
    -Phase Prepare `
    -MsiPath C:\qualification\JazzCapture-0.26.2-win-x64-unsigned.msi `
    -ExpectedVersion 0.26.2 `
    -ExpectedSha256 <64-hex-digest> `
    -EvidenceDirectory C:\qualification\secondary-evidence `
    -ProfileRole secondary `
    -RelatedPrimaryRunId <primary-run-id> `
    -AllowInstalledProductMutation
```

End that command, log out and back into the secondary profile, then run its `Resume` with the
secondary evidence directory. It records this profile's startup and tray behavior and asks the
operator to attest that HKCU/Jazz state is independent and the primary test capture is not visible.
The runner does not inspect another user's profile and does not claim automatic cross-profile
proof; the two runs are linked only by the privacy-safe primary run ID.

### Candidate-specific completion

After observations, quit Jazz through its tray. Read the visible run ID from the corresponding state
file or the `Prepare` output, then complete each profile separately:

```powershell
pwsh windows/qualification/Invoke-RealWindowsQualification.ps1 `
    -Phase Complete `
    -MsiPath C:\qualification\JazzCapture-0.26.2-win-x64-unsigned.msi `
    -ExpectedVersion 0.26.2 `
    -ExpectedSha256 <64-hex-digest> `
    -EvidenceDirectory C:\qualification\primary-evidence `
    -ConfirmUninstallRunId <primary-run-id> `
    -AllowInstalledProductMutation
```

`Complete` authenticates the state again, verifies the exact installed candidate, requires the
operator to repeat its run ID, refuses to terminate Jazz, and uninstalls only the bound ProductCode.
User-created test data remains after uninstall. Complete the secondary run with its own run ID and
evidence directory, then return to and complete the primary run.

The machine-readable ownership/status list is
[`windows/qualification/capability-matrix.json`](../windows/qualification/capability-matrix.json).
Upgrade/downgrade/rollback rows belong to issue #40. First-run, single-instance, discoverability and
update UX belong to issue #42 and must not be reported as #41 successes.

## Exact draft and published assets

The `Qualify Windows release MSI` workflow is manually dispatched with:

- `release_tag`: exact `vMAJOR.MINOR.PATCH` tag;
- `release_state`: `draft` before publication, then `published` after publication;
- `expected_commit`: the reviewed 40-character merge commit targeted by the release;
- `expected_sha256`: the digest of the one expected MSI asset.

After the PR is merged and final-main CI succeeds, first verify that neither the version tag nor
release exists. Create the tag at the exact reviewed merge commit and push that new tag without
force; only then create the draft release with `targetCommitish` set to the same full commit SHA and
upload the final-main CI assets. Never move or replace that tag.

The clean hosted runner checks the release state, exact `targetCommitish`, and the independently
fetched tag-to-commit binding for both draft and published releases. It downloads
`JazzCapture-MAJOR.MINOR.PATCH-win-x64-unsigned.msi` without rebuilding, verifies the digest, and
runs the full lifecycle. Publish only after the draft run passes. Dispatch it again for the public
asset and require the same SHA-256. Never overwrite a release asset; a failed package needs a newer
version after a fix.

## Evidence and release decision

Automated runs produce `qualification.json`, `qualification.md`, and sanitized install/repair/
uninstall logs. Interactive runs add a DPAPI-authenticated `qualification-state.json` and sanitized
installer logs. JSON and Markdown are sanitized with the same privacy boundary as logs. Attach only
those files; never attach raw MSI logs.

Sanitization redacts drive-letter `Users` profile paths generically, including other accounts,
mixed-case paths, profile names with spaces, and Windows 8.3 aliases; it does not rely only on the
runner's current profile variables. A final privacy gate scans every JSON, Markdown, and log file
for residual profile paths or SIDs. On failure it removes only the affected evidence files, leaves
a content-free failure marker, fails the job, and disables evidence artifact upload.

A release note must identify the merge commit, CI run, release/tag, asset URL, ProductCode,
PackageCode, MSI size and SHA-256, plus links to the draft and public exact-byte workflow runs.
Keep issue #41 open while any required interactive row is blocked or not run. A green hosted runner
alone is not completion of the real-Windows matrix.

GitHub exposes draft release metadata and assets only to callers with push-level repository access.
The workflow isolates that access in a resolver job with no checkout and no repository scripts. Its
inline code lists releases through the REST API, resolves the immutable tag through the GitHub API,
checks release state, target commit, asset name, length and SHA-256, downloads one MSI, and passes
those exact bytes through a one-day internal artifact. A second job has only `contents: read`, checks
out the expected commit with persisted credentials disabled, revalidates the transferred bytes, and
alone runs repository qualification code. Release creation, upload, publication, replacement, and
deletion are absent from both jobs.
