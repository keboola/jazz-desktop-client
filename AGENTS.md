# AGENTS.md

## Scope

This repository owns native desktop capture clients and their cross-platform capture contract.
macos/ is Swift 6; windows/ is reserved for a future .NET client. Keep platform UI and OS APIs
out of portable contract material.

## Non-negotiable rules

- contract/ is shared by every capture agent and the Jasnost processor. A change to an emitted
  event or its OTLP mapping must update the schema, golden fixtures, Swift runner, and processor
  mirror in the same coordinated change.
- Keep JasnostCaptureCore pure Foundation and fully unit-testable. TCC APIs belong only in the
  executable target.
- The default capture path is local-first: canonical observations and artifacts are committed to a
  Jazz Archive without network dependency. Only explicit archive-level confirmation may finalize
  and enqueue one immutable `.jazz-archive`; rejection never queues delivery.
- `liveCompatibility` is an explicit migration policy. When enabled, OTLP and Keboola Files are
  projections of the same canonical IDs and CaptureCommit, never independent capture truth.
- Whole-archive delivery has its own durable queue and preserves archive ID, content digest, exact
  ZIP SHA-256, length, and bytes across retries/relaunches. Do not introduce a local bridge or
  local service.
- Secrets never enter Git or command-line arguments. Tokens and stream endpoints live in the
  Keychain; events are masked before being queued or uploaded.
- Archive journals and all delivery spools are durability mechanisms. A network failure, expired
  credential, cancellation, rejection, or quarantine must retain canonical local data.

## Verification

Run `uv run --no-project --with jsonschema python contract/validate_schemas.py`,
`uv run --no-project --with jsonschema python contract/archive/validate_archives.py`, and
`python contract/archive/container/generate_fixtures.py --check`, and
`uv run --no-project --with jsonschema python contract/live/validate_live_transport.py`; then
from macos/ run `swift build && swift test`.
