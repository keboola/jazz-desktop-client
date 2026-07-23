# ADR 0002 — Source-neutral media evidence and live delivery converge on one commit

- **Status:** Accepted
- **Date:** 2026-07-23
- **Tracks:** [keboola/jazz-desktop-client#8](https://github.com/keboola/jazz-desktop-client/issues/8)
- **Relates to:** [ADR 0001](0001-local-first-jazz-archive.md)

## Context

A future capture may come from a shared screen in an online meeting rather than native macOS APIs.
That source can provide video, audio, and a transcript while providing no Accessibility tree, direct
input, pointer events, or verified mapping from a media track to a person. Live feedback may also
need provisional delivery before the archive is finalized.

Mapping this evidence into sparse `ActivityEvent` objects would erase what the source actually saw
and invite consumers to interpret meeting pixels as native input. Making live streaming a second
semantic model would split replay, Process Memory, and archive reconciliation.

## Decision

`jazz.media-observation` is the canonical typed payload for `screen_share_video`, `meeting_audio`,
and `transcript` segments. Each segment binds a storage-neutral artifact ID and role, a source-clock
interval, clock domain/epoch, explicit timing uncertainty, and an attribution status. An identified
or anonymous participant requires a matching actor. Provider participant identity is capture-time
observed evidence; speaker self-declaration is declared evidence. Manual review belongs in an
append-only assertion and voice matching in a versioned derived assertion with model provenance.
Unknown means
unknown: it carries a reason and cannot inherit organizer, uploader, device-owner, display-name, or
other actor metadata.

Sources enumerate both supplied and unavailable capabilities. Meeting capture therefore declares
native Accessibility, pointer, keyboard, and direct-input signals unavailable instead of omitting
fields or fabricating them. Independent video, audio, and transcript clock domains remain
independent; temporal overlap is not a causal assertion.

Live delivery embeds the same canonical observation envelopes, artifact documents, and
`CaptureCommit` used by the archive. Connection epochs, delivery sequence, acknowledgements, sparse
watermarks, and retry state are transport metadata only. Same ID and digest is idempotent. Same ID
with different content, a stream-slot collision, or a reconnect state that differs from the last
acknowledgement fails closed. Artifact metadata alone is not receipt of its content. An artifact
enters the resume acknowledgement only after a trusted receiver-side durable-store result verifies
the received bytes against both canonical `content.sha256` and `content.byteLength`. A provisional
commit is accepted only when all canonical records, artifact metadata, and verified blobs closed by
that byte-identical commit are present.

Downstream evidence links reference canonical observation, artifact, transcript-span, or assertion
identity. Consumers must not reclassify meeting media as a native `ActivityEvent`. Derived process
causality, handoffs, and identity resolution retain their own evidence and provenance.

## Scope

This decision supplies a language-neutral schema, archive golden, live conformance transcript,
Foundation models/runner, and server-verifier mirror. It does not integrate a meeting vendor,
define a network framing or authentication mechanism, add a local bridge/service, or change the
confirmed-archive default from ADR 0003. `liveCompatibility` remains the explicit OTLP/Files
migration projection.

## Enforcement

- `04-meeting-screen-share` proves video, audio, transcript, unknown participant identity,
  unavailable native capabilities, independent clocks, and one archive commit.
- `01-reconnect-late-media` proves duplicate delivery, sparse acknowledgement, reconnect, late
  media, and repeated delivery of the same commit converge without duplicate canonical evidence.
- Python, Swift, and server tests reject guessed identity, duplicate ID with different content,
  undeclared clocks, artifact mismatch, and reconnect-watermark mismatch.

## Consequences

An installed desktop, a future meeting source, archive upload, and future streaming can share one
evidence contract. Meeting-specific acquisition remains outside the portable core, and downstream
models stay evidence-source-neutral. The deliberate cost is explicit clocks, uncertainty,
capability gaps, and identity states instead of convenient but unauditable inference.
