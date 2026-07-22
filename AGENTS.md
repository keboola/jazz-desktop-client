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
- The capture path is direct: OTLP goes to the configured endpoint and screenshots/audio go to
  Keboola Files. Do not introduce a local bridge or a local service.
- Secrets never enter Git or command-line arguments. Tokens and stream endpoints live in the
  Keychain; events are masked before being queued or uploaded.
- Event and narration spools are durability mechanisms. A network failure must retain their data.

## Verification

Run uv run --no-project --with jsonschema python contract/validate_schemas.py, then from macos/
run swift build && swift test.
