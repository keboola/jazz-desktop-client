# Jazz Desktop Client

Native, consent-based desktop capture clients for Jazz. The repository currently ships the macOS
client and is structured so a Windows client can adopt the same capture wire without sharing
platform-specific code.

```
contract/  language-neutral capture contracts and OTLP golden fixtures
macos/     Swift 6 menu-bar client
windows/   reserved for the future .NET client
```

The clients capture only during an explicitly started session. They redact sensitive data before
upload, spool events durably on disk, send OTLP/JSON directly to Keboola, and upload blobs directly
to Keboola Files. Neither client runs a local bridge or stores the master token.

## Contract ownership

contract/ is the source of truth for client-facing capture contracts. Every desktop implementation
must reproduce the OTLP goldens in contract/conformance/fixtures. The processor consumes this
directory as a pinned Git submodule, so its mirror mapping is checked against exactly the same
fixtures.

The contract currently contains the emitted ActivityEvent schema and the Area registry read by a
client for guided labels. Process, BDM, ontology, and other processor-only schemas remain in
[keboola/jasnost](https://github.com/keboola/jasnost).

## macOS development

```bash
cd macos
swift build
swift test
./dev-codesign-setup.sh
./build-app.sh
open "Jazz Capture.app"
```

See [macos/README.md](macos/README.md) for permissions, signing, and release instructions.

## Verification

```bash
uv run --no-project --with jsonschema python contract/validate_schemas.py
cd macos && swift build && swift test
```
