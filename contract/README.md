# Desktop capture contract

This directory defines the language-neutral protocol between desktop clients and Jazz's ingestion
and processor layers.

## Included interfaces

- schema/activity-event.schema.json — the raw event a client emits.
- schema/area-registry.schema.json — the registry a client reads to offer guided process labels.
- conformance/fixtures/ — canonical ActivityEvents + SessionContext to OTLP logs/traces vectors.
  Swift, .NET, and the processor's Python mirror must deep-compare their output with these files.

The fixtures are committed expected output, not a serialization library. A mapping change is a
cross-repository change: update this contract and the processor mirror together, pin the resulting
desktop-client commit in the processor submodule, and make every runner green.

The device-enrollment payload is intentionally not represented here yet: its current authoritative
parser is macos/Sources/JasnostCaptureCore/DeviceBundle.swift. Before a Windows implementation
needs it, promote that payload to a schema in a separately reviewed compatibility change.

## Validation

```bash
uv run --no-project --with jsonschema python contract/validate_schemas.py
```
