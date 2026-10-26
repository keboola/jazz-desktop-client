# Windows HTTP metadata capture — parked plan

Status: **in progress** (slice 1: invite + unpacked helper). HTTP metadata events are not shipped yet.  
Brief: `prompt-windows-http-capture.md` in repo root.

## Goal

See which **HTTPS hosts/paths** the user hit in Chrome/Edge (XHR/fetch/document), so activity can join to a path class — not pixels, not HAR.

## Possible?

**Yes.** Chromium MV3 `webRequest.onCompleted` (Chrome + Edge). No admin, no packet driver, no extra Windows mic/screen permission.

## Permissions (what the user/org must grant)

| Needed? | What |
| --- | --- |
| No | New Windows privacy toggles, admin, NDIS/WinDivert |
| **Yes** | Browser extension: “Read and change your data on websites” (`webRequest` + `https://*/*`) |
| Optional | Incognito: “allow in private” |
| Fleet | Intune `ExtensionInstallForcelist` (silent). Jazz **cannot** install the extension itself. |

Without the extension, Jazz keeps working; there are no `http_*` fields.

## Without Intune (user path)

1. MSI ships unpacked MV3 under `%LOCALAPPDATA%\Jazz\App\http-helper\`.
2. Tray nags if the helper is missing: open `chrome://extensions` / `edge://extensions`.
3. User: Developer mode → Load unpacked → Allow host access.
4. Extension → Jazz via **named pipe or file drop** next to the event spool (no extra OS prompt).
5. Jazz emits one `http_request` ActivityEvent per completed request → existing `/v1/logs`.

Silent install without Intune is **not** possible (Chrome blocks desktop apps from installing extensions).

## Privacy (must not ship otherwise)

Emit only: `http.method`, `http.host`, `http.path` (no query/fragment/userinfo), `http.status`, cheap `http.resource_type`.  
**Never** body, cookies, headers, query, tokens. Legal: HTTP **bodies** are not cleared.

## Contract

New event type e.g. `http_request`. Schema + goldens + `OtlpMapper`. Do not put HTTP keys on narration events.  
AGENTS.md lockstep: if the emitted contract changes, update schema, fixtures, Swift, processor in the same change unless product explicitly allows Windows-only.

## Filters / caps

Ignore `chrome-extension:`, `data:`, `blob:`, static css/woff, noisy ping/beacon. Keep xhr/fetch + main_frame. Cap ~20 events/sec/session; count drops.

## Tests (minimum)

- `https://app.example/invoices?id=secret` → host `app.example`, path `/invoices`, no `id=secret`.
- POST body absent from OTLP.
- Extension absent → capture still works.
- Existing click/screenshot goldens unchanged.

## Out of scope

HAR, DevTools/CDP unless webRequest cannot see fetch, rrweb tab/frame ids, changing off `/v1/logs`, Jazz Processor / Keboola deploy.

## Done when unparked

PR on `feat/windows-keep-fleet-tray`: unpacked extension, mapper keys, one fixture. No store listing required for pilot.
