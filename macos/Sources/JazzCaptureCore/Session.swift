import Foundation

/// A captured session row from `GET /api/sessions` (mirrors the backend SessionRow / the frontend
/// SessionRow). A pure model so list decoding is unit-testable without networking.
public struct JazzSession: Decodable, Identifiable, Sendable, Equatable {
    public let sessionId: String
    public let user: String?
    public let events: Int
    public let clicks: Int
    public let hasNarration: Bool
    public let started: String?
    public let ended: String?
    public let processed: Bool

    public var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case user, events, clicks
        case hasNarration = "has_narration"
        case started, ended, processed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)  // the only required field
        user = try c.decodeIfPresent(String.self, forKey: .user)
        events = (try? c.decode(Int.self, forKey: .events)) ?? 0
        clicks = (try? c.decode(Int.self, forKey: .clicks)) ?? 0
        hasNarration = (try? c.decode(Bool.self, forKey: .hasNarration)) ?? false
        started = try c.decodeIfPresent(String.self, forKey: .started)
        ended = try c.decodeIfPresent(String.self, forKey: .ended)
        processed = (try? c.decode(Bool.self, forKey: .processed)) ?? false
    }

    /// Memberwise init for tests / non-decoded construction.
    public init(
        sessionId: String, user: String? = nil, events: Int = 0, clicks: Int = 0,
        hasNarration: Bool = false, started: String? = nil, ended: String? = nil,
        processed: Bool = false
    ) {
        self.sessionId = sessionId
        self.user = user
        self.events = events
        self.clicks = clicks
        self.hasNarration = hasNarration
        self.started = started
        self.ended = ended
        self.processed = processed
    }
}

extension JazzSession {
    /// The parsed ``started`` time, tolerant of fractional seconds (e.g. ``…16.74865Z``, which the
    /// default ISO8601DateFormatter rejects). ``nil`` when absent or unparseable.
    public var startedDate: Date? { Self.parseTimestamp(started) }

    /// A short, human-readable start time for the sidebar (e.g. "9 Jun 15:44"); "" when unknown.
    public var startedDisplay: String {
        guard let date = startedDate else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: date)
    }

    /// Parse an ISO-8601 timestamp with or without fractional seconds.
    public static func parseTimestamp(_ iso: String?) -> Date? {
        Timestamps.parse(iso)
    }
}

public enum SessionList {
    /// Decode the `{ "sessions": [...] }` envelope from `GET /api/sessions`, de-duplicated by
    /// session id. Returns [] if the payload isn't the expected shape (a transient bad response
    /// shows "no sessions" rather than crashing the sidebar).
    public static func decode(_ data: Data) -> [JazzSession] {
        struct Envelope: Decodable { let sessions: [JazzSession] }
        let raw = (try? JSONDecoder().decode(Envelope.self, from: data))?.sessions ?? []
        return dedupe(raw)
    }

    /// The API can return more than one row per session_id; keep the richest (most events) per id,
    /// preserving first-seen order. The sidebar needs UNIQUE ids — SwiftUI `List`/`ForEach`
    /// misbehave on duplicate ids, and selection-by-id must match exactly one row (else a click
    /// highlights every duplicate row).
    public static func dedupe(_ sessions: [JazzSession]) -> [JazzSession] {
        var bestById: [String: JazzSession] = [:]
        var order: [String] = []
        for s in sessions {
            if let existing = bestById[s.sessionId] {
                if s.events > existing.events { bestById[s.sessionId] = s }
            } else {
                bestById[s.sessionId] = s
                order.append(s.sessionId)
            }
        }
        return order.compactMap { bestById[$0] }
    }
}
