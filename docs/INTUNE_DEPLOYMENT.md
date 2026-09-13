# Intune deployment (Windows)

This is the deployment reference for the per-user Jazz Capture MSI, packaged as an Intune Win32
app. It complements [`windows/README.md`](../windows/README.md), which documents every way to
configure capture-at-launch and the full precedence between them; this document is about
*deploying the MSI itself* and the one public property it consumes (#60 slice 2).

## 1. What this deploys

The per-user Jazz Capture MSI, plus, optionally, one public property:
`JAZZ_CAPTURE_AT_LAUNCH`. Setting it to `1` enforces capture-at-launch on that install; omitting it
leaves the client's own precedence ladder to decide. See
[Managed capture-at-launch policy](../windows/README.md#managed-capture-at-launch-policy) in
`windows/README.md` for the full precedence table (`managed policy > installer preference >
launch switch > user setting`) — it is not repeated here.

## 2. Packaging

Build the `.intunewin` wrapper with Microsoft's `IntuneWinAppUtil.exe`:

```text
IntuneWinAppUtil.exe -c <folder containing the MSI> -s JazzCapture-<version>-win-x64-unsigned.msi -o <output folder>
```

**This repository does not build the `.intunewin` file.** `IntuneWinAppUtil.exe` is closed-source
and is not obtainable on a GitHub-hosted runner, and this repository's own rule — stated at
`.github/workflows/ci.yml`'s promotion job — is that an unverified build script is worse than none.
Run the packaging tool yourself, against the exact signed/verified MSI triplet a release produces
(`JazzCapture-<version>-win-x64-unsigned.msi`, `.sha256`, `.manifest.json`); never rebuild the MSI
to "match" a packaging step.

## 3. Install behavior: User

The package is per-user (`Package.wxs`'s `Scope="perUser"`, asserted by `Verify-Msi.ps1`). In
Intune, assign it as a **User** install, never **Device**.

**A device-targeted assignment of a per-user MSI is the single most likely deployment mistake.**
Windows Installer runs a per-user package in the context of whichever account processes the
assignment; a device-targeted assignment in Intune is processed by the SYSTEM account, so the
package installs into SYSTEM's own profile and writes the installer preference under SYSTEM's own
HKCU — not the signed-in user's — which is never what anyone deploying this package wants. Assign
this app to **users** (or user groups), not to devices, or the install will not behave as
documented here.

## 4. Install command

```text
msiexec.exe /i "JazzCapture-<version>-win-x64-unsigned.msi" /qn /norestart JAZZ_CAPTURE_AT_LAUNCH=1
```

Omit `JAZZ_CAPTURE_AT_LAUNCH` entirely for the default, no-opinion install — the user's own
Settings checkbox (or a preset `settings.json`, or the `--capture-at-launch` launch switch) then
decides, exactly as it does today.

## 5. Uninstall command

```text
msiexec.exe /x {ProductCode} /qn /norestart
```

The `ProductCode` is **version-derived** (`Jazz.Version.props`'s `JazzProductCode`), so this string
changes every release. Derive it from the same source the build reads, rather than hard-coding it
in the Intune app definition:

```powershell
dotnet msbuild windows/installer/Jazz.Version.props -getProperty:JazzProductCode -nologo
```

wrapped in braces: `{<that value>}`.

## 6. Detection rule

Use **file detection**, not the MSI product code. The product code changes every release (see
above) and a product-code detection rule would stop detecting the app the moment a newer version
replaced it.

- **Path:** `%LOCALAPPDATA%\Jazz\App`
- **File:** `JazzCapture.exe`
- **Detection method:** File version, "greater than or equal to" the shipped version's
  `ProductVersion` (for example `0.26.5`).

The version stamp on the installed executable is asserted by
`windows/installer/tests/Invoke-MsiLifecycleQualification.ps1`'s `installed-version` check, so a
mismatch between what Intune detects and what the package actually installed is a build/qualify-
time failure, not a silent gap in this document.

## 7. Requirements

- Windows 10 or 11, x64. (ARM64 is not packaged or qualified.)
- No elevation. The install runs entirely in user context.
- No framework prerequisite: the payload is a self-contained `win-x64` publish
  (`windows/installer/build-msi.sh`'s `dotnet publish --self-contained true`), so there is no .NET
  runtime dependency to declare as a requirement rule.

## 8. Exit codes

- `0` — success.
- `1603` — a newer version of Jazz Capture is already installed, or another fatal installer
  failure. The downgrade rule (`Package.wxs`'s `MajorUpgrade`, whose `LaunchCondition` row is
  `NOT WIX_DOWNGRADE_DETECTED`) fails as a generic fatal installer error, not a distinct code —
  recorded CI qualification evidence confirms `1603` for a rejected downgrade
  (`windows/installer/tests/Invoke-UpgradeTestMatrixQualification.ps1`'s `downgrade-rejected`
  check). Consult the MSI log to tell the two apart.
- `1638` — reinstalling different bytes under the same ProductCode and version (the
  "changed-same-version" case CI observes but does not require a specific result for); not a
  downgrade.

**There is no exit code for a bad property value.** See section 10 below — a malformed
`JAZZ_CAPTURE_AT_LAUNCH` does not fail the install.

## 9. Reboot behavior

None required. Map Intune's reboot setting to "No specific action" — the package requests no
restart and none of its resources need one.

## 10. The knowingly accepted gap: install-time property validation

> `msiexec … JAZZ_CAPTURE_AT_LAUNCH=maybe` **succeeds**. The installer does not validate the
> value; it writes whatever you passed. Intune will report the app as installed.
>
> The client then reads `maybe`, cannot recognise it, and refuses to start capture automatically —
> it never falls through to whatever the user's own setting says, which is what #60 scope 1
> requires. Settings shows the checkbox disabled and Status shows *"A setting deployed to this
> machine could not be read…"*.
>
> So a typo produces a **successful Intune deployment of a machine that is sitting enforced-off
> and saying so on screen**, and nothing tells the administrator until someone looks. #60
> acceptance box 3's *"fails visibly"* is satisfied in the client, **not at install time**.

The only reason install-time validation is absent is that the WiX `<Condition>` element that would
provide it aborts the cross-platform `wixl` build this project also relies on (see the comments in
`windows/installer/Package.wxs` and `windows/installer/wixl/product.wxs`), and this project will
not let the two authorings diverge over one validation check. **Check the deployed value after any
change**; do not assume a green Intune install status means the property parsed.

**A narrower, confirmed edge case: never deploy a value that starts with `#`.** Windows Installer
decides the registry type for the value the package writes from the *formatted* text of that
value — after `[JAZZ_CAPTURE_AT_LAUNCH]` has been substituted with whatever was deployed — not
from the package's own `Type="string"` authoring, which only governs what WiX itself would write
for a literal value. Verified directly against a throwaway probe package:
`msiexec … JAZZ_CAPTURE_AT_LAUNCH=#1` writes `REG_DWORD 1`, not `REG_SZ "#1"`. For most malformed
values this makes no difference — a value like `#5` or `#maybe` still ends up unparseable and
still reads as `Malformed`, exactly as any other bad string would. It matters only for the two
specific strings `#0` and `#1`: instead of the `Malformed` result a literal `"#0"`/`"#1"` would
otherwise get, the client reads the resulting `REG_DWORD` as plain `0`/`1` — silently `Disabled`
(no opinion) or `Enabled`, rather than a visible misconfiguration. This crosses no privilege
boundary the package does not already have (`HKCU` is writable by the same user with or without
this MSI), and there is no fix available within the same "zero custom actions, no `<Condition>`
element, `wixl` parity" constraints that already rule out full install-time validation above. Do
not deploy a `#`-prefixed value; there is never a legitimate reason to.

## 11. The MSI property is a first-install deployment input, not a way to change a deployed value

Windows Installer's `AppSearch` mechanism, which is what lets this property "remember" whatever is
already deployed across a repair or an upgrade, reads the registry **and overwrites the property
with what it finds — including a value supplied on the `msiexec` command line — whenever the
search succeeds.** Because a plain install always writes a value (the "0" default), the search
succeeds on every operation after the first install on a given profile. The consequence:

- **First install, `JAZZ_CAPTURE_AT_LAUNCH=1`, on a profile with no prior value:** writes `1`.
  This is the common Intune path, and it works exactly as expected.
- **A later `msiexec … JAZZ_CAPTURE_AT_LAUNCH=0` (or any other value) against a profile that
  already has a deployed value:** `AppSearch` restores the already-deployed value over whatever was
  passed on the command line. The installer preference does not change.

**To change a deployed preference, do not re-run the installer with a different property.**
Instead, either:

- deploy the registry value directly — Intune's settings catalog, an ADMX ingestion, GPO, or a
  user-context script writing `HKCU\Software\Keboola\Jazz\Policy\CaptureAtLaunch` (or the HKLM
  managed rank, `HKLM\Software\Policies\Keboola\Jazz\CaptureAtLaunch`, for a genuinely enforced
  value) — both already supported by the client today (`windows/README.md`'s
  "Managed capture-at-launch policy" section); or
- uninstall and reinstall with the new property value, on a profile with no existing value.

This is the documented behaviour of Windows Installer's `AppSearch`/`RegLocator` mechanism itself
(the standard "remember a property" pattern this package's authoring uses — see the comments in
`windows/installer/Package.wxs`), not an inference specific to this client. It is also recorded,
run over run, rather than merely asserted here:
`windows/installer/tests/Invoke-UpgradeTestMatrixQualification.ps1`'s `upgrade-policy-update-observed`
check reinstalls a package that already has the property deployed, with a different value on the
command line, against the isolated fixture family (never production, so no development or CI
machine is put at risk running it), and **records** — deliberately as an `observed` check, not a
required one — what Windows Installer actually does. Treat the paragraph above as the analysis;
that check's evidence, from an actual CI run, is the confirmation.

## 12. Name history

`JAZZ_CAPTURE_AT_LAUNCH` was previously proposed as `JAZZ_CONTINUOUS_CAPTURE` in an earlier
deployment brief for issue #60. That name is not used anywhere in this repository; only
`JAZZ_CAPTURE_AT_LAUNCH` is real.

## 13. Secrets

The device bundle that authorizes delivery is provisioned separately (an ACL-restricted file or a
tray command — see the root `README.md`'s device-provisioning section) and is never an MSI
property, a command-line argument, an MSI transform, or a log entry. Nothing in this document
introduces a new path for a secret to travel through the installer (#62 constraint 2,
`AGENTS.md`).

## 14. Signing

The MSI is unsigned. Windows SmartScreen will warn on first run
(`windows/installer/Verify-Msi.ps1`'s closing message says the same). There is no code-signing
certificate for this client today; that is a known limitation, not an oversight in this
deployment guide.
