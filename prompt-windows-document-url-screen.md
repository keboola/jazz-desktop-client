# Prompt: Jazz Windows — keep D365 **screen** keys on document URL

Hand this to an agent on **`keboola/jazz-desktop-client`**, branch **`feat/windows-keep-fleet-tray`** (or current Windows mainline). Small change. Do not rewrite capture, OTLP, or screenshots.

## Why (live 3121)

Windows Jazz sanitizes `documentURL` in `ObservedDocumentUrl.Sanitize`: **drop user, password, query, fragment**. Live Packeta F&O events therefore store only:

`https://packeta.operations.eu.dynamics.com/`

Process-mining n-grams cannot tell **which form**. F&O puts the screen in query/hash (`mi=`, `cmp=`, …). CE uses `etn=`, `pagetype=`. Those never reach Keboola.

The `url` OTLP field is **not** the browser address (often `c:\…` / AUMID). Do not “fix” mining by reading that. Fix **documentURL sanitizer** (and UIA source if it never sees the full address).

## Goal

Emit a **privacy-preserving screen context**, not a raw address bar.

Keep HTTP(S):

- scheme + lowercase host + path (as today)
- **allowlisted** query and/or fragment keys only:

  `mi`, `etn`, `pagetype`, `cmp`, `menuitem`, `menuitemname`, `f`

Drop everything else: `id`, GUIDs, `data`, userinfo, other query, random fragment.

Examples:

| Observed (conceptual) | Emit |
| --- | --- |
| `https://packeta.operations.eu.dynamics.com/?cmp=usmf&mi=PurchTable&id={guid}` | `https://packeta.operations.eu.dynamics.com/?cmp=usmf&mi=PurchTable` |
| `https://contoso.crm.dynamics.com/main.aspx?pagetype=entityrecord&etn=account&id={guid}` | `https://contoso.crm.dynamics.com/main.aspx?pagetype=entityrecord&etn=account` |
| `https://example.com/search?q=secret` | `https://example.com/search` (no `q`) |

If F&O puts `mi=` in the **fragment**, parse the fragment the same way (allowlist only).

Still never a business-object id (ANNEX-HOST). Screen/menu name is in scope.

## Code

- `windows/Sources/JazzCaptureCore/ObservedDocumentUrl.cs` — today drops query+fragment unconditionally. Change sanitize for http(s) only.
- Contract: `contract/schema/activity-event.schema.json` `documentURL` description currently says omit query and fragment. Update the description to “omit userinfo; omit query/fragment except allowlisted D365 screen keys; never record ids.”
- Goldens / `OtlpMapper` / any ObservedDocumentUrl tests. If macOS must stay byte-identical, port the same allowlist there **or** document a Windows-only exception and split the golden (prefer **same sanitizer both OS** so archives agree).

Do **not** add a second OTLP field unless the contract owners insist. Prefer one `documentURL` / `document.url` attribute.

## Tests (must fail before the fix)

- Full F&O URL with `mi` + `id` GUID → output contains `mi=`, **not** the GUID.
- CE URL with `etn` + `pagetype` + `id` → `etn`+`pagetype`, no `id`.
- `https://x.example/path?q=secret` → no `q=secret`.
- `file:` behavior unchanged (`file:/%3Clocal%3E/…`).
- Existing non-Dynamics http goldens still drop query.

## Out of scope

HAR/network capture, Chrome extension, traces/metrics, Jazz Processor, Keboola, screenshot pipeline.

## Done

PR: sanitizer + schema text + fixtures green. Unpacked client not required for this slice if unit tests cover the URL table above.
