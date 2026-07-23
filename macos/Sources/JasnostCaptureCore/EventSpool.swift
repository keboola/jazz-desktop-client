import Foundation

/// Durable on-disk event spool — the retry queue between capture and the OTLP sender.
/// Events are appended here BEFORE any network send; a batch file is moved to the journal
/// only after the sender got an HTTP 2xx, so a crash/offline period never loses events
/// (the spool replaces the old in-memory buffer + its requeue-forever loop).
///
/// Layout under a configurable root (default `~/.jasnost/spool`):
///
///     <root>/<sessionId>/meta.json                      session identity + trace/span ids
///     <root>/<sessionId>/batch-<00000042>.ndjson        one ActivityEvent JSON per line,
///                                                       named by the zero-padded first
///                                                       sequence so name order == send order
///     <root>/journal/<sessionId>/batch-*.ndjson         batches already shipped (markSent)
///     <root>/journal/<sessionId>/meta.json              meta mirror, so the journal remains
///                                                       self-contained if the spool dir is
///                                                       cleaned up later
///
/// `sessions()` is the native sidebar's data source: it merges spool + journal and is
/// corruption-tolerant — unparsable lines/files are skipped, the listing never throws.
public final class EventSpool {
    /// Reserved directory name under the root; session ids ("s-<uuid>") can never collide.
    private static let journalDirName = "journal"
    /// Directory names under the root that are NOT session dirs: the sent-batch journal, the
    /// screenshot uploader's blob staging area (`shots/`), durable narration audio spool
    /// (`narration/`), Jazz archive drafts (`archives/`), archive artifact delivery ledger, and
    /// guided-execution recovery state — owned outside session listing.
    private static let reservedDirNames: Set<String> = [
        journalDirName, "shots", "narration", "archives", "archive-artifact-delivery",
        "guided-execution",
    ]
    /// Width of the zero-padded first-sequence in batch filenames; lexicographic order of
    /// names must equal numeric order for per-session FIFO sending.
    private static let sequencePadWidth = 8
    /// Marker file in `journal/<sessionId>/` recording that the session's `capture-session`
    /// span got an HTTP 2xx — so a relaunch never re-ships it.
    private static let spanSentMarker = "span.sent"

    /// Per-session identity persisted at `meta.json`. The trace/span ids are generated once
    /// at session start so every batch (and the final span) shares them across restarts.
    public struct SessionMeta: Codable, Equatable, Sendable {
        public var sessionId: String
        public var traceId: String
        public var spanId: String
        public var startedAt: String
        public var kind: String?
        public var user: String
        /// The recording machine's name — `host.name` on every event. Persisted so it survives
        /// a crash and the sender can rebuild the OTLP context with it. Defaults to "" (and
        /// decodes missing → "" for meta written before this field existed).
        public var instanceName: String
        /// The session's Area (scope) id/name, picked at session start (ADR 0002). Session-scoped: it
        /// rides every event as the "area.id"/"area.name" OTLP attribute. Persisted so it survives a
        /// crash and the sender can rebuild the context. nil until a pick lands (reads as General).
        public var areaId: String?
        public var areaName: String?
        public var endedAt: String?
        public var schemaVersion: Int

        public init(
            sessionId: String,
            traceId: String,
            spanId: String,
            startedAt: String,
            kind: String? = nil,
            user: String,
            instanceName: String = "",
            areaId: String? = nil,
            areaName: String? = nil,
            endedAt: String? = nil,
            schemaVersion: Int = 1
        ) {
            self.sessionId = sessionId
            self.traceId = traceId
            self.spanId = spanId
            self.startedAt = startedAt
            self.kind = kind
            self.user = user
            self.instanceName = instanceName
            self.areaId = areaId
            self.areaName = areaName
            self.endedAt = endedAt
            self.schemaVersion = schemaVersion
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try c.decode(String.self, forKey: .sessionId)
            traceId = try c.decode(String.self, forKey: .traceId)
            spanId = try c.decode(String.self, forKey: .spanId)
            startedAt = try c.decode(String.self, forKey: .startedAt)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            user = try c.decode(String.self, forKey: .user)
            // Tolerate meta.json written before this field existed (crash-recovery): treat a
            // missing host.name as "" rather than failing the whole decode.
            instanceName = try c.decodeIfPresent(String.self, forKey: .instanceName) ?? ""
            // Tolerate meta.json written before Areas existed (additive optional → no schemaVersion bump).
            areaId = try c.decodeIfPresent(String.self, forKey: .areaId)
            areaName = try c.decodeIfPresent(String.self, forKey: .areaName)
            endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        }
    }

    /// One unsent batch file, ready for the sender. Ordering inside a session follows the
    /// zero-padded filename (== first sequence in the batch).
    public struct PendingBatch: Equatable, Sendable {
        public let sessionId: String
        public let url: URL

        public init(sessionId: String, url: URL) {
            self.sessionId = sessionId
            self.url = url
        }
    }

    /// Sidebar row: merged spool+journal view of one session.
    public struct SessionSummary: Identifiable, Equatable, Sendable {
        public let id: String  // sessionId
        public let startedAt: String?
        public let endedAt: String?
        public let kind: String?
        public let user: String?
        /// Parsable events across spool + journal (sent + pending).
        public let eventCount: Int
        public let sentCount: Int
        public let pendingCount: Int
        /// Values of `annotation` events, in capture order — the user's own task labels.
        public let labels: [String]
    }

    public enum SpoolError: Error, Equatable {
        case sessionAlreadyExists(String)
        case sessionNotFound(String)
        case projectionConflict(String)
    }

    public let root: URL
    private var journalRoot: URL {
        root.appendingPathComponent(Self.journalDirName, isDirectory: true)
    }

    private let fileManager = FileManager.default
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Projection retries compare canonical bytes. JSON object key order is otherwise an
        // implementation detail and the same ActivityEvent can sporadically encode differently,
        // turning an idempotent retry into a false projection conflict.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private static let decoder = JSONDecoder()

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jasnost/spool", isDirectory: true)
    ) {
        self.root = root
    }

    // MARK: - Writing

    /// Exclusively claim the session directory and persist its meta. UUIDs make a collision
    /// extraordinarily unlikely, but correctness never relies on probability: an existing id is
    /// rejected and its evidence is never overwritten. This also closes the check/create race
    /// between two writers using the same root.
    public func createSession(_ meta: SessionMeta) throws {
        let dir = sessionDir(meta.sessionId)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: dir.path) else {
            throw SpoolError.sessionAlreadyExists(meta.sessionId)
        }
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: false)
        } catch {
            if fileManager.fileExists(atPath: dir.path) {
                throw SpoolError.sessionAlreadyExists(meta.sessionId)
            }
            throw error
        }
        // If the meta write fails, leave the claimed directory in place. Reusing the id would be
        // less safe than leaking an empty diagnostic directory, and another writer may already
        // have observed the claim.
        try writeMeta(meta, to: dir)
    }

    /// Append one batch as `batch-<padded-first-sequence>.ndjson`. Returns nil for an empty
    /// batch (nothing written). Events missing a sequence pad as 0; a filename collision
    /// (possible only then) gets a `-N` suffix so no batch ever overwrites another.
    @discardableResult
    public func appendBatch(sessionId: String, events: [ActivityEvent]) throws -> PendingBatch? {
        guard !events.isEmpty else { return nil }
        let dir = sessionDir(sessionId)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let firstSequence = events.first?.sequence ?? 0
        let base = String(format: "batch-%0\(Self.sequencePadWidth)d", firstSequence)
        var url = dir.appendingPathComponent("\(base).ndjson")
        var suffix = 1
        while fileManager.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(suffix).ndjson")
            suffix += 1
        }

        var lines: [String] = []
        for event in events {
            let data = try Self.encoder.encode(event)  // single-line JSON (no .prettyPrinted)
            lines.append(String(decoding: data, as: UTF8.self))
        }
        let payload = lines.joined(separator: "\n") + "\n"
        try Data(payload.utf8).write(to: url, options: .atomic)
        return PendingBatch(sessionId: sessionId, url: url)
    }

    /// Idempotent compatibility projection of one canonical archive observation. The stable
    /// observation id remains in the filename across retries and a conflicting retry is surfaced
    /// instead of creating a second OTLP event with different bytes.
    @discardableResult
    public func appendProjection(
        sessionId: String,
        observationId: String,
        event: ActivityEvent
    ) throws -> PendingBatch? {
        guard observationId.hasPrefix("obs-"),
            UUID(uuidString: String(observationId.dropFirst(4))) != nil
        else { throw SpoolError.projectionConflict(observationId) }
        let sequence = max(0, event.sequence ?? 0)
        let name = String(format: "batch-%0\(Self.sequencePadWidth)d-%@.ndjson", sequence, observationId)
        let data = try Self.encoder.encode(event) + Data([0x0a])
        let pendingURL = sessionDir(sessionId).appendingPathComponent(name)
        let sentURL = journalSessionDir(sessionId).appendingPathComponent(name)
        for existingURL in [pendingURL, sentURL] where fileManager.fileExists(atPath: existingURL.path) {
            guard try Data(contentsOf: existingURL) == data else {
                throw SpoolError.projectionConflict(observationId)
            }
            return existingURL == pendingURL
                ? PendingBatch(sessionId: sessionId, url: pendingURL)
                : nil
        }
        let dir = sessionDir(sessionId)
        guard fileManager.fileExists(atPath: dir.path) else {
            throw SpoolError.sessionNotFound(sessionId)
        }
        if try !writeOnce(data, to: pendingURL) {
            guard try Data(contentsOf: pendingURL) == data else {
                throw SpoolError.projectionConflict(observationId)
            }
        }
        return PendingBatch(sessionId: sessionId, url: pendingURL)
    }

    /// Record the session end in meta (the sender ships the span once `endedAt` is set).
    /// Updates the journal mirror too, so a fully-shipped session keeps its end time.
    public func endSession(sessionId: String, endedAt: String) throws {
        let dir = sessionDir(sessionId)
        let journalDir = journalSessionDir(sessionId)
        guard var meta = readMeta(in: dir) ?? readMeta(in: journalDir) else {
            throw SpoolError.sessionNotFound(sessionId)
        }
        meta.endedAt = endedAt
        try writeMeta(meta, to: dir)
        if fileManager.fileExists(atPath: journalDir.path) {
            try writeMeta(meta, to: journalDir)
        }
    }

    /// Read the persisted meta for a session (spool first, then journal mirror).
    public func sessionMeta(sessionId: String) -> SessionMeta? {
        readMeta(in: sessionDir(sessionId)) ?? readMeta(in: journalSessionDir(sessionId))
    }

    // MARK: - Sending

    /// All unsent batches, ordered by session directory name, then by batch filename — the
    /// per-session FIFO order the sender must preserve. Never throws (an unreadable dir
    /// simply yields no batches).
    public func pendingBatches() -> [PendingBatch] {
        var batches: [PendingBatch] = []
        for sessionId in listSessionIds(under: root).sorted() {
            let dir = sessionDir(sessionId)
            for url in listBatchFiles(in: dir) {
                batches.append(PendingBatch(sessionId: sessionId, url: url))
            }
        }
        return batches
    }

    /// Parse one batch file back into events, skipping corrupt lines — a damaged line must
    /// not block the rest of the batch from shipping. An unreadable file yields [].
    public func readEvents(_ batch: PendingBatch) -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: batch.url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            try? Self.decoder.decode(ActivityEvent.self, from: Data($0.utf8))
        }
    }

    /// Sessions whose `capture-session` span is ready to ship: ended (`endedAt` set), all
    /// batches already journaled (nothing pending in the spool), span not yet marked sent.
    /// Sorted by startedAt so the sender ships spans in capture order. Never throws.
    public func sessionsAwaitingSpan() -> [SessionMeta] {
        let ids = Set(listSessionIds(under: root)).union(listSessionIds(under: journalRoot))
        return ids.compactMap { sessionId -> SessionMeta? in
            guard
                let meta = readMeta(in: sessionDir(sessionId))
                    ?? readMeta(in: journalSessionDir(sessionId)),
                meta.endedAt != nil,
                listBatchFiles(in: sessionDir(sessionId)).isEmpty,
                !isSpanSent(sessionId: sessionId)
            else { return nil }
            return meta
        }
        .sorted { ($0.startedAt, $0.sessionId) < ($1.startedAt, $1.sessionId) }
    }

    /// Record that the session's span got an HTTP 2xx — call ONLY then. Mirrors meta into
    /// the journal alongside the marker so the journal stays self-contained.
    public func markSpanSent(sessionId: String) throws {
        let journalDir = journalSessionDir(sessionId)
        try fileManager.createDirectory(at: journalDir, withIntermediateDirectories: true)
        if let meta = readMeta(in: sessionDir(sessionId)) ?? readMeta(in: journalDir) {
            try? writeMeta(meta, to: journalDir)  // best-effort mirror; the marker is the record
        }
        try Data().write(to: journalDir.appendingPathComponent(Self.spanSentMarker))
    }

    /// Whether the session's span was already accepted by the stream.
    public func isSpanSent(sessionId: String) -> Bool {
        fileManager.fileExists(
            atPath: journalSessionDir(sessionId).appendingPathComponent(Self.spanSentMarker).path)
    }

    /// Move a sent batch into the journal — call ONLY after an HTTP 2xx from the stream.
    /// Mirrors meta.json alongside so the journal stays self-contained.
    public func markSent(_ batch: PendingBatch) throws {
        let journalDir = journalSessionDir(batch.sessionId)
        try fileManager.createDirectory(at: journalDir, withIntermediateDirectories: true)
        var destination = journalDir.appendingPathComponent(batch.url.lastPathComponent)
        // A duplicate name in the journal (re-sent batch after a crash between send and
        // markSent) must not block: keep both under a unique name.
        var suffix = 1
        while fileManager.fileExists(atPath: destination.path) {
            let stem = batch.url.deletingPathExtension().lastPathComponent
            destination = journalDir.appendingPathComponent("\(stem).resent-\(suffix).ndjson")
            suffix += 1
        }
        try fileManager.moveItem(at: batch.url, to: destination)
        if let meta = readMeta(in: sessionDir(batch.sessionId)) {
            try? writeMeta(meta, to: journalDir)  // best-effort mirror; sending must not fail
        }
    }

    // MARK: - Listing (sidebar)

    /// Merged spool + journal listing, newest first. Corruption-tolerant: garbage meta or
    /// event lines are skipped; this never throws (a broken file must not break the sidebar).
    public func sessions() -> [SessionSummary] {
        let spoolIds = Set(listSessionIds(under: root))
        let journalIds = Set(listSessionIds(under: journalRoot))
        var summaries: [SessionSummary] = []
        for sessionId in spoolIds.union(journalIds) {
            let spoolDir = sessionDir(sessionId)
            let journalDir = journalSessionDir(sessionId)
            // Spool meta wins (endSession writes there first); journal mirror is the fallback.
            let meta = readMeta(in: spoolDir) ?? readMeta(in: journalDir)

            // Journal first: those batches were captured (and sent) earlier, so label order
            // stays chronological.
            let sent = scanBatches(in: journalDir)
            let pending = scanBatches(in: spoolDir)
            summaries.append(
                SessionSummary(
                    id: sessionId,
                    startedAt: meta?.startedAt,
                    endedAt: meta?.endedAt,
                    kind: meta?.kind,
                    user: meta?.user,
                    eventCount: sent.count + pending.count,
                    sentCount: sent.count,
                    pendingCount: pending.count,
                    labels: sent.labels + pending.labels
                ))
        }
        // Newest first for the sidebar; sessions without a parsable start sink to the bottom.
        return summaries.sorted { lhs, rhs in
            switch (lhs.startedAt, rhs.startedAt) {
            case let (l?, r?) where l != r: return l > r  // ISO-8601 sorts lexicographically
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.id < rhs.id
            }
        }
    }

    /// All parsable events of one session in capture order: journal batches first (they
    /// were captured and shipped earlier), then still-pending spool batches, each in
    /// zero-padded filename order. Feeds the local replay path — no network round-trip.
    /// Corruption-tolerant: damaged lines/files are skipped; never throws.
    public func sessionEvents(sessionId: String) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        for dir in [journalSessionDir(sessionId), sessionDir(sessionId)] {
            for url in listBatchFiles(in: dir) {
                events.append(
                    contentsOf: readEvents(PendingBatch(sessionId: sessionId, url: url)))
            }
        }
        return events
    }

    // MARK: - Internals

    private func sessionDir(_ sessionId: String) -> URL {
        root.appendingPathComponent(sessionId, isDirectory: true)
    }

    private func journalSessionDir(_ sessionId: String) -> URL {
        journalRoot.appendingPathComponent(sessionId, isDirectory: true)
    }

    private func writeMeta(_ meta: SessionMeta, to dir: URL) throws {
        let data = try Self.encoder.encode(meta)
        try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    private func writeOnce(_ data: Data, to destination: URL) throws -> Bool {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        do {
            try fileManager.linkItem(at: temporary, to: destination)
            return true
        } catch where fileManager.fileExists(atPath: destination.path) {
            return false
        }
    }

    /// nil on missing OR corrupt meta — listing degrades instead of failing.
    private func readMeta(in dir: URL) -> SessionMeta? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json"))
        else { return nil }
        return try? Self.decoder.decode(SessionMeta.self, from: data)
    }

    /// Session subdirectories under `base` (skips reserved dirs and stray files).
    private func listSessionIds(under base: URL) -> [String] {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            let name = url.lastPathComponent
            return Self.reservedDirNames.contains(name) ? nil : name
        }
    }

    /// Batch files in a session dir, sorted by name (zero-padding makes that FIFO order).
    private func listBatchFiles(in dir: URL) -> [URL] {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return
            entries
            .filter {
                $0.lastPathComponent.hasPrefix("batch-") && $0.pathExtension == "ndjson"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Count parsable events + collect annotation labels across a dir's batches, skipping
    /// anything unreadable (corruption tolerance).
    private func scanBatches(in dir: URL) -> (count: Int, labels: [String]) {
        var count = 0
        var labels: [String] = []
        for url in listBatchFiles(in: dir) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard
                    let event = try? Self.decoder.decode(
                        ActivityEvent.self, from: Data(line.utf8))
                else { continue }  // corrupt line: skip, keep counting the rest
                count += 1
                if event.eventType == EventType.annotation.rawValue,
                    let value = event.value, !value.isEmpty
                {
                    labels.append(value)
                }
            }
        }
        return (count, labels)
    }
}

extension EventSpool.SessionSummary {
    /// Parsed start time (ISO-8601, with or without fractional seconds); nil when unknown.
    public var startedDate: Date? { Timestamps.parse(startedAt) }

    /// A short, human-readable start time for the sidebar (e.g. "9 Jun 15:44"), in local
    /// time; "" when the start is unknown (corrupt/missing meta).
    public var startedDisplay: String {
        guard let date = startedDate else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: date)
    }

    /// Human-readable session duration ("23s", "5m 23s", "1h 05m"); "" while the session
    /// is still open or when either timestamp is missing/unparsable.
    public var durationDisplay: String {
        guard
            let start = Timestamps.parse(startedAt),
            let end = Timestamps.parse(endedAt)
        else { return "" }
        return Self.formatDuration(end.timeIntervalSince(start))
    }

    /// Seconds → compact duration text. Negative clamps to 0 (clock skew must not render
    /// nonsense in the sidebar).
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}
