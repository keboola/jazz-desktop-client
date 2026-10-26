# Prompt: Jazz Windows — capture browser HTTP metadata (not DevTools)

Use this as the system/user brief for an agent working in **`keboola/jazz-desktop-client`**, branch **`feat/windows-keep-fleet-tray`** (or a fork). This is a **new capability**. Do not rewrite capture, OTLP mapping, or screenshot delivery.

## Why

Packeta 3121 live data: Windows Jazz posts **only** `/v1/logs`. Events have app name, sometimes `url`/`page_title`, clicks, screenshots. **`process.id` is empty.** There is **no** Chrome DevTools / HAR / XHR body capture. We cannot see “user called `/api/…`”.

We want **request metadata** (what API/host they hit) so activity fragments can join to a **path class**, not pixels.

## Non-goals

- Full HAR, response/request **bodies**, cookies, `Authorization`, query strings, DevTools UI.
- rrweb / `tabId` / `frameId` (schema has them; Windows **must not** start projecting those unless a separate ADR).
- Changing `MvpStreamSender` off `/v1/logs`.
- Jazz Processor, packeta-poc, Keboola writes.

## Product rule (privacy)

Emit **only**:

- `http.method` (`GET`/`POST`/…)
- `http.host`
- `http.path` — path only, **strip query + fragment + userinfo**
- `http.status` (when known)
- `http.resource_type` if cheap (`xhr` | `fetch` | `document` | `other`)
- correlation: existing `session.id`, `enduser.id`, `host.name`, optional `screenshot_id` if a capture is in flight

**Never** emit: body, cookie, header values, query (`?q=`), tokens.

Same redaction spirit as `documentURL` today (`ObservedDocumentUrl`: no userinfo/query/fragment).

## Suggested shape (lazy)

1. **MV3 extension** for Chrome **and** Edge (same Chromium). `webRequest` **onCompleted** (or `declarativeNetRequest` + extraInfo if that is enough). Not CDP `Network.enable` unless webRequest cannot see fetch.
2. Host Jazz process already running: extension → local named pipe / loopback **only if** that pattern exists; otherwise a small file drop next to the event spool. Prefer **one ActivityEvent** per completed request, `eventType` e.g. `http_request` (add to contract + goldens + OtlpMapper generic attributes — do not invent a traces pipeline).
3. Filter: ignore `chrome-extension:`, `data:`, `blob:`, static `*.css`/`*.woff*`, ping/beacon if noisy. Keep XHR/fetch + main_frame.
4. Cap: e.g. 20 events/sec/session; drop extras, count `http_dropped`.
5. Optional allowlist of host suffixes later (Packeta apps). v1 can log all https hosts minus strip rules; document volume.

## Contract / OTLP

- Extend `contract/schema/activity-event.schema.json` + goldens + Swift/macOS only if the repo requires lockstep; if Windows-only is allowed, still update schema + Windows mapper + fixtures.
- `OtlpMapper`: new string keys, empty `""` if missing; **do not** put HTTP fields on narration events.
- Delivery stays `LogsRequest` → `/v1/logs`.

## Tests (smallest that can fail)

- Path `https://app.example/invoices?id=secret` → host `app.example`, path `/invoices`, **no** `id=secret`.
- POST JSON body not in OTLP JSON.
- Extension absent → capture still works (events without http_*).
- Existing screenshot + click goldens unchanged.

## Done

PR on the Windows client branch: extension install path (unpacked/dev first, no store), mapper keys, one fixture. No Keboola deploy.

## Context for the agent

Live SoR: Keboola project **3121**. Lane `win-process-arch` is design; this prompt is the client follow-on. Legal for screenshots→Vertex was cleared separately; **HTTP bodies are not cleared** — do not add them.
