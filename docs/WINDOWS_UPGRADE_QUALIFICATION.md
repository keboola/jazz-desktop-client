# Windows upgrade and rollback qualification

Jazz uses a WiX major upgrade scheduled `afterInstallInitialize`. The generated MSI database must
prove this order:

```text
InstallInitialize < RemoveExistingProducts < InstallFinalize
```

That order keeps removal of the previous product inside the Windows Installer rollback
transaction. Source XML is not evidence; both Windows and `wixl` verifiers inspect the generated
`InstallExecuteSequence` table.

## Supported package policy

- Repair from the exact original MSI is supported and restores installer-owned resources.
- A numerically newer version with the stable production UpgradeCode is supported.
- Downgrades are rejected before destructive mutation.
- Changed bytes with the same ProductVersion/ProductCode are unsupported. CI records the actual
  Windows Installer result and proves that it creates neither side-by-side registration nor data
  loss. Such bytes must never replace an asset; a changed package requires a new version.
- One immutable MSI byte stream is attached to one release. Qualification downloads that stream;
  it does not rebuild an equivalent package.

## Maintenance shutdown

The tray host registers with Windows Restart Manager and owns a hidden top-level message sink.
`WM_QUERYENDSESSION`, `WM_ENDSESSION`, and `WM_CLOSE` enter the same idempotent controller. A close
is accepted only after producers stop and every admitted observation drains. An active engine then
calls `CaptureEngine.Stop()` and reaches `Committed`.

Restart registration uses `RESTART_NO_CRASH | RESTART_NO_HANG | RESTART_NO_REBOOT` (`1 | 2 | 8`).
This leaves installer/patch maintenance restart available while preventing an application crash,
hang, or reboot from adding a second launch beside the existing Run-key startup before issue #42
owns single-instance coordination. A registration failure leaves the close sink alive and
disposable but does not crash the tray host.

The maintenance seam deliberately has no confirmation, finalization, export, enqueue, or review
API. Unit tests run it against a real engine and prove that the journal contains the commit while
the finalized archive directory, review assertion, and delivery queue remain absent. A timeout
returns false, preserves the journal, and leaves the same worker available for a bounded retry. A
worker fault is explicit and permanent, disables the misleading retry action, and requires a clean
host restart. Neither outcome authorizes replacement.

## Isolated rollback fixture

`Build-UpgradeTestMatrix.ps1` writes only below the fixed
`windows/installer/artifacts/test-only-upgrade/generated` boundary and builds four packages:

- N (`1.0.0`);
- changed same-version N with an explicit different payload variant;
- normal N+1 (`1.1.0`);
- failing N+1 with a type-19 action immediately after `RemoveExistingProducts`.

The fixture has a test-only UpgradeCode, ProductCodes, fixed component GUIDs, harvested-component
GUID seed, product name, data folder, Run value, shortcut, and output tree. None equals production.
N and N+1 intentionally share their test component family so the synthetic upgrade obeys Windows
Installer component rules. The failing action is compile-time test-only, conditioned on
`WIX_UPGRADE_DETECTED`, and cannot be enabled through a public MSI property. Production verifiers
hard-fail on any test marker, property, action, or sequence row.

## Automated clean-runner matrix

The `Windows rollback-safe upgrade matrix` CI job is the only supported unattended mutation path.
Its driver requires both `GITHUB_ACTIONS=true` and an explicit mutation switch, then refuses a
runner containing either production Jazz or the fixture family. It exercises:

1. clean N install;
2. deletion and exact-package repair of an installer-owned marker;
3. changed-same-version observation;
4. N to N+1 while the exact installed idle host is running;
5. downgrade rejection;
6. deliberate post-removal failure and restoration of N registration, executable, shortcut, and
   Run entry;
7. a normal recovery upgrade after rollback;
8. final uninstall of installer-owned resources.

Before mutation it creates inert, harness-owned sentinels in both the real runtime root
`%LOCALAPPDATA%\Jazz` and the isolated installer root `%LOCALAPPDATA%\JazzUpgradeFixture`. Their
SHA-256 values must remain unchanged after every scenario. The differing installer data-folder
identity does not claim to redirect the application's runtime settings or capture paths.

Evidence uses the existing qualification writer and privacy gate. It records exact MSI hashes,
lengths and identities, scenario exit codes, registrations, resource state, sentinel hashes, and
sanitized verbose logs. It may not contain profile paths, 8.3 aliases, SIDs, usernames, hostnames,
tokens, endpoints, or captured content.

## Manual rows

Hosted automation proves process ownership and Restart Manager closure, not visible behavior.
Issue #40 remains open until a dedicated clean standard-user profile records:

- an active capture committed during upgrade;
- no confirmation, export, delivery intent, or review popup during maintenance shutdown;
- visible tray recovery after rollback;
- reboot-required behavior, if Windows Installer requests it.

No Azure CLI, Jazz backend credential, production endpoint, signing certificate, service, or local
bridge is required.
