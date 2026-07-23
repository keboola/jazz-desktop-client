import Foundation

public enum Identifiers {
    /// A new capture session id: ``s-<uuid>`` (matches the extension's convention).
    public static func newSessionId() -> String {
        prefixedUUIDv7("s")
    }

    /// A new label (bracketed-segment) id: ``l-<uuid>``, minted at label start and stamped onto
    /// every event captured while the label is open — downstream treats it as a segment boundary.
    public static func newLabelId() -> String {
        prefixedUUIDv7("l")
    }

    /// A globally collision-resistant archive id. Descriptive prefixes keep ids self-identifying
    /// when they appear in filenames, logs, or a future delivery receipt.
    public static func newArchiveId() -> String {
        prefixedUUIDv7("ar")
    }

    /// Offline-minted identity of the producing installation/origin. It is not authorization.
    public static func newOriginId() -> String {
        prefixedUUIDv7("origin")
    }

    /// Stable identity of a human or system actor captured in an archive manifest.
    public static func newActorId() -> String {
        prefixedUUIDv7("actor")
    }

    /// Identity of one capture source (for example this macOS client installation).
    public static func newSourceId() -> String {
        prefixedUUIDv7("src")
    }

    /// Identity of one immutable NDJSON batch inside an archive draft.
    public static func newArchiveBatchId() -> String {
        prefixedUUIDv7("batch")
    }

    /// Identity reserved for a binary artifact in the archive inventory.
    public static func newArtifactId() -> String {
        prefixedUUIDv7("art")
    }

    /// Identity of one provenance/review assertion in the portable archive.
    public static func newAssertionId() -> String {
        prefixedUUIDv7("asrt")
    }

    /// Identity of one resumable delivery attempt/state record.
    public static func newDeliveryId() -> String {
        prefixedUUIDv7("del")
    }

    /// Local append-only receipt for acquisition of one exact portable archive package.
    public static func newImportReceiptId() -> String {
        prefixedUUIDv7("imr")
    }

    /// Identity of one durable Capture Coach interaction shown or acted on by the user.
    public static func newCoachInteractionId() -> String {
        prefixedUUIDv7("coach")
    }

    /// Identity of a versioned advisory prompt. The server normally mints this id; the helper is
    /// also used by offline fixtures and deterministic client tests.
    public static func newCoachPromptId() -> String {
        prefixedUUIDv7("prompt")
    }

    /// A local installation id used when no server-enrolled device id exists yet.
    public static func newInstallationId() -> String {
        prefixedUUIDv7("installation")
    }

    /// Identity of one continuous acquisition window. A legacy session id may be correlated with
    /// it, but is not reused as the canonical identity.
    public static func newCaptureId() -> String {
        prefixedUUIDv7("cap")
    }

    /// Identity of an ordered producer/reconnect epoch within a capture.
    public static func newStreamId() -> String {
        prefixedUUIDv7("stream")
    }

    /// Globally unique identity of one canonical observation.
    public static func newObservationId() -> String {
        prefixedUUIDv7("obs")
    }

    /// Correlates one physical pointer gesture without pretending its events are business steps.
    public static func newGestureId() -> String {
        prefixedUUIDv7("gesture")
    }

    /// Identity of the immutable consistency declaration emitted when a capture ends.
    public static func newCaptureCommitId() -> String {
        prefixedUUIDv7("cmt")
    }

    /// A per-event id: ``<sessionId>-<sequence>`` so evidence refs are stable + ordered.
    public static func eventId(sessionId: String, sequence: Int) -> String {
        "\(sessionId)-\(sequence)"
    }

    /// RFC 9562 UUIDv7: 48-bit Unix epoch milliseconds followed by 74 random bits. Foundation's
    /// UUID supplies the entropy; the timestamp, version, and variant bits are set explicitly.
    /// Strict monotonic ordering within the same millisecond is deliberately not promised.
    public static func newUUIDv7() -> UUID {
        uuidV7(now: Date(), random: UUID())
    }

    /// Internal injection point keeps the byte layout testable without a clock or RNG abstraction.
    static func uuidV7(now: Date, random: UUID) -> UUID {
        let timestamp = max(0, now.timeIntervalSince1970 * 1_000).rounded(.down)
        let milliseconds = UInt64(timestamp) & 0x0000_ffff_ffff_ffff
        let entropy = random.uuid
        var bytes: [UInt8] = [
            entropy.0, entropy.1, entropy.2, entropy.3,
            entropy.4, entropy.5, entropy.6, entropy.7,
            entropy.8, entropy.9, entropy.10, entropy.11,
            entropy.12, entropy.13, entropy.14, entropy.15,
        ]
        bytes[0] = UInt8((milliseconds >> 40) & 0xff)
        bytes[1] = UInt8((milliseconds >> 32) & 0xff)
        bytes[2] = UInt8((milliseconds >> 24) & 0xff)
        bytes[3] = UInt8((milliseconds >> 16) & 0xff)
        bytes[4] = UInt8((milliseconds >> 8) & 0xff)
        bytes[5] = UInt8(milliseconds & 0xff)
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        let value: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: value)
    }

    private static func prefixedUUIDv7(_ prefix: String) -> String {
        "\(prefix)-\(newUUIDv7().uuidString.lowercased())"
    }
}

public enum Timestamps {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Plain RFC-3339 (no fractional seconds) — ISO8601DateFormatter is all-or-nothing about
    /// fractions, so parsing needs both variants.
    private static let plainFormatter = ISO8601DateFormatter()

    /// ISO-8601 UTC timestamp with fractional seconds (the schema's `timestamp` format).
    public static func iso8601(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }

    /// Parse an ISO-8601 timestamp with or without fractional seconds (the agent emits
    /// fractional, some APIs don't). `nil` when absent or unparseable.
    public static func parse(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        if let date = plainFormatter.date(from: iso) { return date }
        return formatter.date(from: iso)
    }
}
