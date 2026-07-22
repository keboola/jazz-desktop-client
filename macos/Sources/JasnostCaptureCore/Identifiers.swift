import Foundation

public enum Identifiers {
    /// A new capture session id: ``s-<uuid>`` (matches the extension's convention).
    public static func newSessionId() -> String {
        "s-\(UUID().uuidString.lowercased())"
    }

    /// A new label (bracketed-segment) id: ``l-<uuid>``, minted at label start and stamped onto
    /// every event captured while the label is open — downstream treats it as a segment boundary.
    public static func newLabelId() -> String {
        "l-\(UUID().uuidString.lowercased())"
    }

    /// A per-event id: ``<sessionId>-<sequence>`` so evidence refs are stable + ordered.
    public static func eventId(sessionId: String, sequence: Int) -> String {
        "\(sessionId)-\(sequence)"
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
