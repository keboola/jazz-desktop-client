# Device bundle (MVP)

Copy `device-bundle.example.json` to `device-bundle.json` in this folder, fill the
placeholders from Keboola, and **do not commit** `device-bundle.json`.

The JSON is the **same on every PC**. Who is capturing is **not** in this file:
Jazz stamps `enduser.id` (Windows login) and `host.name` (machine) on every OTLP event.

## Shape

| Field | What to put |
| --- | --- |
| `token` | Scoped Storage API token (`<projectId>-…`, never a master token) |
| `tokenId` | That token's id |
| `expiresAt` | RFC 3339 UTC |
| `projectId` | Digits only |
| `stackURL` | Canonical stack, no trailing slash |
| `streamEndpoint` | HTTPS Data Stream ingest URL **without** `/v1/logs` (the client appends it) |
| `sinkBucketId` | Bucket the token may write |
| `deviceId` | Shared fleet id for this MVP path |

## On each computer (if the MSI does not embed the bundle)

After install, drop the filled file at:

`%LOCALAPPDATA%\Jazz\provisioning\device-bundle.json`

Jazz consumes it and deletes the file.

## The installer carries no bundle

The MSI never contains `device-bundle.json`. A machine joined to Entra ID gets its bundle from the
Jazz server (`docs/INTUNE_DEPLOYMENT.md`, section 4). Other machines use the file drop above or the
tray's provisioning window.

Never put `token` or `streamEndpoint` on the command line, in chat, or in git.
