# Real Windows qualification

## Issue #42 interactive evidence

On a disposable clean standard-user profile, retain sanitized steps/screenshots for the status
window (including capture-off state), tray reopen route, explicit capture start, second-launch
foreground activation, a separate user profile, and a newer-release link. Automated evidence only
proves bytes, process identity and protocol behavior; it does not prove visible tray/foreground UI,
consent comprehension, SmartScreen, microphone, scaling, or multi-display behavior.

This procedure separates evidence a hosted runner can prove from behavior that needs a person at
an interactive Windows desktop. It applies to the unsigned x64 MSI. ARM64 is not qualified.

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
