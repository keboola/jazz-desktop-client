# Device bundle (MVP)

Copy `device-bundle.example.json` to `device-bundle.json` in this folder, fill the
`REPLACE_ME_*` values from Jazz/Keboola, and **do not commit** `device-bundle.json`.

This JSON is the **same on every PC**. Who is capturing is **not** in this file:
Jazz stamps `enduser.id` (Windows login) and `host.name` (machine) on every OTLP event.

## Shape

| Field | What to put |
| --- | --- |
| `token` | Scoped Storage API token (`<projectId>-…`, never a master token) |
| `tokenId` | That token's id |
| `expiresAt` | RFC 3339 UTC, e.g. `2027-12-31T23:59:59Z` |
| `projectId` | Digits only |
| `stackURL` | Canonical stack, no trailing slash, e.g. `https://connection.keboola.com` |
| `streamEndpoint` | HTTPS Data Stream ingest URL **without** `/v1/logs` (the client appends it). Path is secret. |
| `streamSourceId` | Shared source id for the fleet (optional but typical) |
| `deviceId` | Shared fleet id for this MVP path — not a per-laptop identity |

## On each computer

After the per-user MSI, copy the filled file here (current-user ACL only):

`%LOCALAPPDATA%\Jazz\provisioning\device-bundle.json`

Jazz consumes it once and wipes the file. Then start with `--capture-at-launch`.

## Intune / fleet

Use `windows/installer/Deploy-JazzCapture.ps1` in the **user** context (not SYSTEM):

```powershell
pwsh -File windows/installer/Deploy-JazzCapture.ps1 `
  -MsiPath .\JazzCapture-0.26.5-win-x64-unsigned.msi `
  -BundlePath .\device-bundle.json
```

That installs the MSI, sets HKCU Run to `JazzCapture.exe --capture-at-launch`, copies the bundle
with a current-user ACL, and starts the app. The flag is `--capture-at-launch` (there is no
`--auto-capture`). Same MSI + same JSON on every PC; `enduser.id` / `host.name` differentiate users.

### If the JSON arrives later

- **Jazz not running yet:** next start (logon Run key or the script) consumes the file.
- **Jazz already running:** intake keeps retrying (backoff up to 60s) whether a credential is
  missing, active, or was hard-refused. Dropping a new `device-bundle.json` is consumed without a
  restart. A new non-empty file replaces a previous credential on the next successful consume.

Never put `token` or `streamEndpoint` on the command line, in chat, or in git.
