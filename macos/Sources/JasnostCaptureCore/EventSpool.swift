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
///     <root>/<sessionId>/batch-*.live.json              canonical live projection sidecar
///     <root>/<sessionId>/batch-*.live.otlp.json         exact dual-delivery request bytes
///     <root>/<sessionId>/batch-*.live.*.accepted        digest-bound destination ACKs
///     <root>/journal/<sessionId>/batch-*.ndjson         batches already shipped (markSent)
///     <root>/journal/<sessionId>/meta.json              meta mirror, so the journal remains
///                                                       self-contained if the spool dir is
///                                                       cleaned up later
///     <root>/journal/<sessionId>/span.live.*             exact trace bytes + destination ACKs
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
        /// Present only for liveCompatibility sessions. These are the exact archive identities,
        /// not values reconstructed from the legacy session/trace.
        public var liveCanonicalBinding: JazzLiveCanonicalBinding?
        /// Exact non-secret signed route pinned when this liveCompatibility session starts. nil
        /// preserves the legacy direct-Data-Stream mode.
        public var liveRouteBinding: JazzArchiveUploadRouteBinding?
        /// Exact destination policy derived from the same signed enrollment generation as
        /// `liveRouteBinding`. Archive-only enrollment requires Jazz alone; a signed legacy
        /// endpoint pins dual delivery. nil with a signed route is the pre-policy migration shape
        /// and conservatively retains the historical dual-delivery requirement.
        public var liveDeliveryRequirements: JazzLiveCompatibilityDeliveryRequirements?
        /// Persisted only after the CaptureJournal commits. The trace sender reuses these exact
        /// JCS bytes and digest across retries/relaunches.
        public var liveCaptureCommit: JazzLiveProjectionItem?
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
            liveCanonicalBinding: JazzLiveCanonicalBinding? = nil,
            liveRouteBinding: JazzArchiveUploadRouteBinding? = nil,
            liveDeliveryRequirements: JazzLiveCompatibilityDeliveryRequirements? = nil,
            liveCaptureCommit: JazzLiveProjectionItem? = nil,
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
            self.liveCanonicalBinding = liveCanonicalBinding
            self.liveRouteBinding = liveRouteBinding
            self.liveDeliveryRequirements = liveDeliveryRequirements
            self.liveCaptureCommit = liveCaptureCommit
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
            liveCanonicalBinding = try c.decodeIfPresent(
                JazzLiveCanonicalBinding.self, forKey: .liveCanonicalBinding)
            liveRouteBinding = try c.decodeIfPresent(
                JazzArchiveUploadRouteBinding.self, forKey: .liveRouteBinding)
            liveDeliveryRequirements = try c.decodeIfPresent(
                JazzLiveCompatibilityDeliveryRequirements.self,
                forKey: .liveDeliveryRequirements)
            liveCaptureCommit = try c.decodeIfPresent(
                JazzLiveProjectionItem.self, forKey: .liveCaptureCommit)
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
        public let hasLiveCompatibilityProjection: Bool
        /// Values of `annotation` events, in capture order — the user's own task labels.
        public let labels: [String]
    }

    public enum SpoolError: Error, Equatable {
        case sessionAlreadyExists(String)
        case sessionNotFound(String)
        case projectionConflict(String)
        case deliveryIncomplete(String)
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
        if let requirements = meta.liveDeliveryRequirements {
            guard let route = meta.liveRouteBinding,
                (try? requirements.validate(for: route)) != nil
            else { throw SpoolError.projectionConflict(meta.sessionId) }
        }
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
        try appendProjection(
            sessionId: sessionId,
            observationId: observationId,
            event: event,
            liveBatch: nil)
    }

    /// Durable liveCompatibility projection of the exact canonical observation/artifacts and the
    /// legacy ActivityEvent. The sidecar is committed before the event batch becomes sendable;
    /// therefore a crash can leave an ignored orphan sidecar, but can never expose a new event
    /// batch without its canonical metadata.
    @discardableResult
    public func appendCanonicalProjection(
        sessionId: String,
        binding: JazzLiveCanonicalBinding,
        record: JazzArchiveRecord,
        artifacts: [JazzArchiveArtifact],
        event: ActivityEvent
    ) throws -> PendingBatch? {
        guard record.observationId.hasPrefix("obs-")
        else { throw SpoolError.projectionConflict(record.observationId) }
        guard let meta = sessionMeta(sessionId: sessionId) else {
            throw SpoolError.sessionNotFound(sessionId)
        }
        guard meta.liveCanonicalBinding == binding,
            (try? record.activityRecord().payload) == event
        else { throw SpoolError.projectionConflict(record.observationId) }
        let liveBatch = try JazzLiveProjectionBatch(
            binding: binding,
            record: record,
            artifacts: artifacts)
        return try appendProjection(
            sessionId: sessionId,
            observationId: record.observationId,
            event: event,
            liveBatch: liveBatch)
    }

    private func appendProjection(
        sessionId: String,
        observationId: String,
        event: ActivityEvent,
        liveBatch: JazzLiveProjectionBatch?
    ) throws -> PendingBatch? {
        guard observationId.hasPrefix("obs-"),
            UUID(uuidString: String(observationId.dropFirst(4))) != nil
        else { throw SpoolError.projectionConflict(observationId) }
        let sequence = max(0, event.sequence ?? 0)
        let name = String(format: "batch-%0\(Self.sequencePadWidth)d-%@.ndjson", sequence, observationId)
        let data = try Self.encoder.encode(event) + Data([0x0a])
        let pendingURL = sessionDir(sessionId).appendingPathComponent(name)
        let sentURL = journalSessionDir(sessionId).appendingPathComponent(name)
        let liveData = try liveBatch.map(Self.encoder.encode)
        for existingURL in [pendingURL, sentURL] where fileManager.fileExists(atPath: existingURL.path) {
            guard try Data(contentsOf: existingURL) == data else {
                throw SpoolError.projectionConflict(observationId)
            }
            if let liveData {
                try installLiveSidecar(
                    liveData,
                    observationId: observationId,
                    batchURL: existingURL)
            }
            return existingURL == pendingURL
                ? PendingBatch(sessionId: sessionId, url: pendingURL)
                : nil
        }
        let dir = sessionDir(sessionId)
        guard fileManager.fileExists(atPath: dir.path) else {
            throw SpoolError.sessionNotFound(sessionId)
        }
        if let liveData {
            try installLiveSidecar(
                liveData,
                observationId: observationId,
                batchURL: pendingURL)
        }
        if try !writeOnce(data, to: pendingURL) {
            guard try Data(contentsOf: pendingURL) == data else {
                throw SpoolError.projectionConflict(observationId)
            }
        }
        return PendingBatch(sessionId: sessionId, url: pendingURL)
    }

    /// Exact canonical projection associated with a pending batch, or nil for a legacy/off-mode
    /// batch. Corrupt sidecars fail closed to nil; the server never sees guessed canonical fields.
    public func readLiveProjection(_ batch: PendingBatch) -> JazzLiveProjectionBatch? {
        let url = liveSidecarURL(for: batch.url)
        guard let data = try? Data(contentsOf: url),
            let value = try? Self.decoder.decode(JazzLiveProjectionBatch.self, from: data),
            (try? value.validate()) != nil
        else { return nil }
        return value
    }

    /// Record the session end in meta (the sender ships the span once `endedAt` is set).
    /// Updates the journal mirror too, so a fully-shipped session keeps its end time.
    public func endSession(
        sessionId: String,
        endedAt: String,
        captureCommit: JazzArchiveCaptureCommit? = nil
    ) throws {
        let dir = sessionDir(sessionId)
        let journalDir = journalSessionDir(sessionId)
        guard var meta = readMeta(in: dir) ?? readMeta(in: journalDir) else {
            throw SpoolError.sessionNotFound(sessionId)
        }
        if let captureCommit {
            guard let binding = meta.liveCanonicalBinding,
                binding.captureId == captureCommit.captureId,
                endedAt == captureCommit.endedAt
            else { throw SpoolError.projectionConflict(captureCommit.commitId) }
            let projection = try JazzLiveProjectionItem.commit(captureCommit)
            if let existing = meta.liveCaptureCommit, existing != projection {
                throw SpoolError.projectionConflict(captureCommit.commitId)
            }
            meta.liveCaptureCommit = projection
        } else if meta.liveCanonicalBinding != nil {
            throw SpoolError.projectionConflict(sessionId)
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

    /// Upgrade/recovery binding from a canonical archive. A missing binding may be installed, but
    /// an existing different binding is an identity conflict and is never overwritten.
    public func bindLiveCanonicalSession(
        sessionId: String,
        binding: JazzLiveCanonicalBinding
    ) throws {
        let dir = sessionDir(sessionId)
        let journalDir = journalSessionDir(sessionId)
        guard var meta = readMeta(in: dir) ?? readMeta(in: journalDir) else {
            throw SpoolError.sessionNotFound(sessionId)
        }
        if let existing = meta.liveCanonicalBinding, existing != binding {
            throw SpoolError.projectionConflict(binding.captureId)
        }
        meta.liveCanonicalBinding = binding
        if fileManager.fileExists(atPath: dir.path) {
            try writeMeta(meta, to: dir)
        }
        if fileManager.fileExists(atPath: journalDir.path) {
            try writeMeta(meta, to: journalDir)
        }
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

    /// Work the sender must drain. In addition to ordinary spool batches this includes a
    /// canonical batch already journaled by a pre-dual-delivery client when its pinned Jazz
    /// acknowledgement is still absent. Journal location is durable proof that the legacy stream
    /// accepted those older bytes, so the migration never reclassifies them as unsent legacy data.
    public func deliveryBatches() -> [PendingBatch] {
        var batches = pendingBatches()
        for sessionId in listSessionIds(under: journalRoot).sorted() {
            guard sessionMeta(sessionId: sessionId)?.liveRouteBinding != nil else {
                continue
            }
            for url in listBatchFiles(in: journalSessionDir(sessionId)) {
                let batch = PendingBatch(sessionId: sessionId, url: url)
                guard !liveDeliveryState(batch).isComplete else { continue }
                batches.append(batch)
            }
        }
        return batches.sorted {
            ($0.sessionId, $0.url.lastPathComponent)
                < ($1.sessionId, $1.url.lastPathComponent)
        }
    }

    /// Persist the exact OTLP bytes before either destination is attempted. Once installed, a
    /// retry or newer executable always gets the original bytes rather than re-encoding the
    /// canonical event with potentially different JSON formatting.
    public func prepareLiveDeliveryPayload(
        _ candidate: Data,
        for batch: PendingBatch
    ) throws -> Data {
        guard !candidate.isEmpty,
            candidate.count <= JazzLiveCompatibilityRequestPlan.maximumRequestBytes,
            sessionMeta(sessionId: batch.sessionId)?.liveRouteBinding != nil,
            readLiveProjection(batch) != nil
        else { throw SpoolError.projectionConflict(batch.url.lastPathComponent) }
        return try prepareExactPayload(
            candidate,
            at: liveTransportPayloadURL(for: batch.url),
            identity: batch.url.lastPathComponent)
    }

    public func liveDeliveryState(
        _ batch: PendingBatch
    ) -> JazzLiveCompatibilityDeliveryState {
        let payload = validPayload(at: liveTransportPayloadURL(for: batch.url))
        let digest = payload.map(JazzArchiveDigest.sha256Hex)
        let legacyAccepted =
            isJournalBatchURL(batch.url)
            || markerMatches(
                digest,
                at: liveTransportMarkerURL(for: batch.url, target: .legacy))
        let jazzAccepted = markerMatches(
            digest,
            at: liveTransportMarkerURL(for: batch.url, target: .jazz))
        return JazzLiveCompatibilityDeliveryState(
            payload: payload,
            legacyAccepted: legacyAccepted,
            jazzAccepted: jazzAccepted,
            requiredDestinations: liveRequiredDestinations(
                sessionId: batch.sessionId))
    }

    public func markLiveDeliveryAccepted(
        _ target: JazzLiveCompatibilityDeliveryTarget,
        for batch: PendingBatch
    ) throws {
        let state = liveDeliveryState(batch)
        guard let payload = state.payload else {
            throw SpoolError.deliveryIncomplete(batch.url.lastPathComponent)
        }
        try writeDigestMarker(
            JazzArchiveDigest.sha256Hex(payload),
            to: liveTransportMarkerURL(for: batch.url, target: target),
            identity: batch.url.lastPathComponent)
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

    /// Record completion of the session span. A signed dual-delivery span requires both durable
    /// acknowledgements first; legacy-only spans retain the original single-2xx rule.
    public func markSpanSent(sessionId: String) throws {
        if sessionMeta(sessionId: sessionId)?.liveRouteBinding != nil,
            !liveSpanDeliveryState(sessionId: sessionId).isComplete
        {
            throw SpoolError.deliveryIncomplete(sessionId)
        }
        let journalDir = journalSessionDir(sessionId)
        try fileManager.createDirectory(at: journalDir, withIntermediateDirectories: true)
        if let meta = readMeta(in: sessionDir(sessionId)) ?? readMeta(in: journalDir) {
            try? writeMeta(meta, to: journalDir)  // best-effort mirror; the marker is the record
        }
        try Data().write(to: journalDir.appendingPathComponent(Self.spanSentMarker))
    }

    /// Whether the session span has satisfied its pinned delivery policy.
    public func isSpanSent(sessionId: String) -> Bool {
        let markerExists = fileManager.fileExists(
            atPath: journalSessionDir(sessionId).appendingPathComponent(Self.spanSentMarker).path)
        guard markerExists else { return false }
        guard sessionMeta(sessionId: sessionId)?.liveRouteBinding != nil else {
            return true
        }
        return liveSpanDeliveryState(sessionId: sessionId).isComplete
    }

    public func prepareLiveSpanDeliveryPayload(
        sessionId: String,
        candidate: Data
    ) throws -> Data {
        guard !candidate.isEmpty,
            candidate.count <= JazzLiveCompatibilityRequestPlan.maximumRequestBytes,
            let meta = sessionMeta(sessionId: sessionId),
            meta.liveCanonicalBinding != nil,
            meta.liveRouteBinding != nil,
            meta.liveCaptureCommit != nil
        else { throw SpoolError.projectionConflict(sessionId) }
        let journalDir = journalSessionDir(sessionId)
        try fileManager.createDirectory(at: journalDir, withIntermediateDirectories: true)
        return try prepareExactPayload(
            candidate,
            at: liveSpanPayloadURL(sessionId: sessionId),
            identity: sessionId)
    }

    public func liveSpanDeliveryState(
        sessionId: String
    ) -> JazzLiveCompatibilityDeliveryState {
        let payload = validPayload(at: liveSpanPayloadURL(sessionId: sessionId))
        let digest = payload.map(JazzArchiveDigest.sha256Hex)
        let legacyAccepted =
            fileManager.fileExists(
                atPath: journalSessionDir(sessionId)
                    .appendingPathComponent(Self.spanSentMarker).path)
            || markerMatches(
                digest,
                at: liveSpanMarkerURL(sessionId: sessionId, target: .legacy))
        let jazzAccepted = markerMatches(
            digest,
            at: liveSpanMarkerURL(sessionId: sessionId, target: .jazz))
        return JazzLiveCompatibilityDeliveryState(
            payload: payload,
            legacyAccepted: legacyAccepted,
            jazzAccepted: jazzAccepted,
            requiredDestinations: liveRequiredDestinations(
                sessionId: sessionId))
    }

    public func markLiveSpanDeliveryAccepted(
        _ target: JazzLiveCompatibilityDeliveryTarget,
        sessionId: String
    ) throws {
        let state = liveSpanDeliveryState(sessionId: sessionId)
        guard let payload = state.payload else {
            throw SpoolError.deliveryIncomplete(sessionId)
        }
        try writeDigestMarker(
            JazzArchiveDigest.sha256Hex(payload),
            to: liveSpanMarkerURL(sessionId: sessionId, target: target),
            identity: sessionId)
    }

    /// Move a completed batch into the journal. Signed dual delivery requires both digest-bound
    /// acknowledgements; legacy-only batches retain the original single-2xx rule.
    public func markSent(_ batch: PendingBatch) throws {
        if sessionMeta(sessionId: batch.sessionId)?.liveRouteBinding != nil {
            guard readLiveProjection(batch) != nil else {
                throw SpoolError.projectionConflict(batch.url.lastPathComponent)
            }
            guard liveDeliveryState(batch).isComplete else {
                throw SpoolError.deliveryIncomplete(batch.url.lastPathComponent)
            }
        }
        // A journaled pre-dual-delivery item becomes complete in place after Jazz accepts it.
        if isJournalBatchURL(batch.url) { return }
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
        let sourceSidecar = liveSidecarURL(for: batch.url)
        if fileManager.fileExists(atPath: sourceSidecar.path) {
            let sidecarData = try Data(contentsOf: sourceSidecar)
            let destinationSidecar = liveSidecarURL(for: destination)
            if try !writeOnce(sidecarData, to: destinationSidecar) {
                guard try Data(contentsOf: destinationSidecar) == sidecarData else {
                    throw SpoolError.projectionConflict(destination.lastPathComponent)
                }
            }
        }
        for source in liveTransportCompanionURLs(for: batch.url)
            where fileManager.fileExists(atPath: source.path)
        {
            let destinationCompanion = correspondingCompanionURL(
                source: source,
                sourceBatch: batch.url,
                destinationBatch: destination)
            let data = try Data(contentsOf: source)
            if try !writeOnce(data, to: destinationCompanion) {
                guard try Data(contentsOf: destinationCompanion) == data else {
                    throw SpoolError.projectionConflict(destination.lastPathComponent)
                }
            }
        }
        try fileManager.moveItem(at: batch.url, to: destination)
        try? fileManager.removeItem(at: sourceSidecar)
        for source in liveTransportCompanionURLs(for: batch.url) {
            try? fileManager.removeItem(at: source)
        }
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
                    hasLiveCompatibilityProjection: meta?.liveCanonicalBinding != nil,
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

    private func liveSidecarURL(for batchURL: URL) -> URL {
        let stem = batchURL.deletingPathExtension()
        return URL(fileURLWithPath: stem.path + ".live.json")
    }

    private func liveTransportPayloadURL(for batchURL: URL) -> URL {
        let stem = batchURL.deletingPathExtension()
        return URL(fileURLWithPath: stem.path + ".live.otlp.json")
    }

    private func liveTransportMarkerURL(
        for batchURL: URL,
        target: JazzLiveCompatibilityDeliveryTarget
    ) -> URL {
        let stem = batchURL.deletingPathExtension()
        return URL(
            fileURLWithPath:
                stem.path + ".live.\(target.rawValue).accepted")
    }

    private func liveTransportCompanionURLs(for batchURL: URL) -> [URL] {
        [
            liveTransportPayloadURL(for: batchURL),
            liveTransportMarkerURL(for: batchURL, target: .legacy),
            liveTransportMarkerURL(for: batchURL, target: .jazz),
        ]
    }

    private func correspondingCompanionURL(
        source: URL,
        sourceBatch: URL,
        destinationBatch: URL
    ) -> URL {
        let sourceStem = sourceBatch.deletingPathExtension().path
        let destinationStem = destinationBatch.deletingPathExtension().path
        let suffix = String(source.path.dropFirst(sourceStem.count))
        return URL(fileURLWithPath: destinationStem + suffix)
    }

    private func liveSpanPayloadURL(sessionId: String) -> URL {
        journalSessionDir(sessionId).appendingPathComponent(
            "span.live.otlp.json")
    }

    private func liveSpanMarkerURL(
        sessionId: String,
        target: JazzLiveCompatibilityDeliveryTarget
    ) -> URL {
        journalSessionDir(sessionId).appendingPathComponent(
            "span.live.\(target.rawValue).accepted")
    }

    private func isJournalBatchURL(_ url: URL) -> Bool {
        let journalPath = journalRoot.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(journalPath)
    }

    /// A missing policy on an older signed-route record keeps the stricter historical dual
    /// requirement. A malformed/tampered policy does the same rather than weakening delivery.
    private func liveRequiredDestinations(
        sessionId: String
    ) -> [JazzLiveCompatibilityDeliveryTarget] {
        guard let meta = sessionMeta(sessionId: sessionId),
            let route = meta.liveRouteBinding
        else { return [.legacy] }
        guard let requirements = meta.liveDeliveryRequirements,
            (try? requirements.validate(for: route)) != nil
        else { return [.legacy, .jazz] }
        return requirements.requiredDestinations
    }

    private func prepareExactPayload(
        _ candidate: Data,
        at destination: URL,
        identity: String
    ) throws -> Data {
        if fileManager.fileExists(atPath: destination.path) {
            guard let existing = validPayload(at: destination) else {
                throw SpoolError.projectionConflict(identity)
            }
            return existing
        }
        if try writeOnce(candidate, to: destination) {
            return candidate
        }
        guard let existing = validPayload(at: destination) else {
            throw SpoolError.projectionConflict(identity)
        }
        return existing
    }

    private func validPayload(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url),
            !data.isEmpty,
            data.count <= JazzLiveCompatibilityRequestPlan.maximumRequestBytes
        else { return nil }
        return data
    }

    private func markerMatches(_ digest: String?, at url: URL) -> Bool {
        guard let digest,
            let data = try? Data(contentsOf: url),
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value == digest
    }

    private func writeDigestMarker(
        _ digest: String,
        to destination: URL,
        identity: String
    ) throws {
        let data = Data((digest + "\n").utf8)
        if try !writeOnce(data, to: destination) {
            guard try Data(contentsOf: destination) == data else {
                throw SpoolError.projectionConflict(identity)
            }
        }
    }

    private func installLiveSidecar(
        _ data: Data,
        observationId: String,
        batchURL: URL
    ) throws {
        let destination = liveSidecarURL(for: batchURL)
        if try !writeOnce(data, to: destination) {
            guard try Data(contentsOf: destination) == data else {
                throw SpoolError.projectionConflict(observationId)
            }
        }
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
