# S3 versioned contract/authority slice — inactive

Implemented after desktop74c6802, coordinated with Jazz PR357. Normative specification:
[`contract/live/best-effort.md`](../../contract/live/best-effort.md).

- Optional signed `bestEffortCapability` in the existing v2 JWS, with explicit source, expiry,
  ongoing-transmission, sampled-fidelity, loss and unknown-coverage policy. Absent/unsigned/MVP,
  unknown-version, malformed and expired permission fails closed; archive permission is not enough.
- Epoch and envelope bind exact signed generation/bundle, Project/stack/Company/Area/device/source
  and existing canonical observation/artifact bytes. No archive ID or CaptureCommit is manufactured.
- Exact-JCS immutable input selections and shared identity-pin reducers reject same-ID/different
  bytes, reused sequence slots, epoch/capture reassignment and cross-mode aliasing. Input resolution
  rejects missing/extra/altered material; later inputs require a content-addressed successor.
- Explicit provisional/unknown/analysis-blocked/NOT-READY fences. v1 selections are not analysis or
  media-access grants. Existing archive and liveCompatibility authority remains separate.
- Swift OTLP mapper/runner and Python mirror share generated goldens, including exact request bodies,
  attribute types, selection IDs and identity maps. Signed golden03 uses the existing public test key.

Native verification: **903 tests,1 expected live-OTLP skip,0 failures** (seven new S3 tests), all six
prescribed validators and Swift build pass. New Swift files / affected signing and mapper code pass
strict formatting lint; baseline style findings in existing files are retained with no new findings.
The new fixture generator is PEP723-pinned and invoked by the existing live validator; the prescribed
command lists and CI triggers are unchanged. Timestamp-to-OTLP conversion now rejects UInt64 overflow
at the shared mapper instead of trapping on malformed future timestamps.

The processor companion reuses existing signature/native-principal/registry authorization and rejects
injected scope/source, stale enrollment/token state, conflicting bytes and mixed liveCompatibility
attributes. The legacy timeline reader rejects the provisional body; legacy SQL is unchanged.
The processor pins the five-file contract-only revision `305fe14f4904a4edbb08b3e50d3c1f19ce18a411`:
no namespace migration, unrelated fixture regeneration or extra archive ZIP. Only the S3 reader
locally aliases its jazz.dev schema references over the unchanged legacy schema graph.
Windows remains unsupported and must reject the signed capability without advancing its replay ledger.

Reference reducers are bounded contract implementations, **not a deployed durable acceptance ledger**.
A production adapter must transact retained bytes and global identity pins (including archived IDs),
retain conflicts for quarantine and persist before ACK. No HTTP intake, issuer UI, analysis job or
capture constructor is activated here. Further scoped analysis/media admission, durable ingestion,
server-first deployment and physical qualification remain separate. The proposed ADR remains proposed;
implementing a signed permission format is not blanket adoption of its loss choices.

Logs/receipts: `/tmp/jazz-continuous-eaa688eb/s3-contract/`. Existing app, credentials, recordings,
archives and pending delivery were not changed. No production resources or live service probes used.
