import Foundation

/// Durable capture lifecycle. `idle` is the state of a journal instance before a persisted capture
/// is prepared; every other state is stored beside the archive draft and survives a relaunch.
public enum CaptureJournalLifecycle: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case starting
    case recording
    case closingInput
    case draining
    case committed
}

/// Stable handle returned before asynchronous observation work starts. A completion must present the
/// whole token, preventing a callback from an older capture generation from resolving new work.
public struct CaptureJournalReservationToken: Codable, Equatable, Hashable, Sendable {
    public let reservationId: String
    public let archiveId: String
    public let captureId: String
    public let streamId: String
    public let streamSequence: Int

    fileprivate init(
        reservationId: String,
        archiveId: String,
        captureId: String,
        streamId: String,
        streamSequence: Int
    ) {
        self.reservationId = reservationId
        self.archiveId = archiveId
        self.captureId = captureId
        self.streamId = streamId
        self.streamSequence = streamSequence
    }
}

/// Artifact work is tracked independently from observation sequence positions. Bytes are persisted
/// content-addressed in the archive draft before a token is resolved or exposed to a network
/// projection.
public struct CaptureJournalArtifactToken: Codable, Equatable, Hashable, Sendable {
    public let reservationId: String
    public let archiveId: String
    public let captureId: String
    public let artifactId: String

    fileprivate init(
        reservationId: String,
        archiveId: String,
        captureId: String,
        artifactId: String
    ) {
        self.reservationId = reservationId
        self.archiveId = archiveId
        self.captureId = captureId
        self.artifactId = artifactId
    }
}

public struct CaptureJournalSnapshot: Equatable, Sendable {
    public let lifecycle: CaptureJournalLifecycle
    public let archiveId: String?
    public let captureId: String?
    public let nextSequenceByStream: [String: Int]
    public let pendingReservationCount: Int
    public let resolvedObservationCount: Int
    public let gapCount: Int
    public let pendingArtifactCount: Int
    public let resolvedArtifactCount: Int

    fileprivate static let idle = CaptureJournalSnapshot(
        lifecycle: .idle,
        archiveId: nil,
        captureId: nil,
        nextSequenceByStream: [:],
        pendingReservationCount: 0,
        resolvedObservationCount: 0,
        gapCount: 0,
        pendingArtifactCount: 0,
        resolvedArtifactCount: 0)
}

public enum CaptureJournalError: Error, Equatable, CustomStringConvertible {
    case noActiveCapture
    case archiveAlreadyClaimed(String)
    case captureAlreadyActive(String)
    case stateNotFound(String)
    case corruptState(String)
    case invalidTransition(from: CaptureJournalLifecycle, to: CaptureJournalLifecycle)
    case streamNotFound(String)
    case emptyStream(String)
    case streamHasNoObservation(String)
    case staleReservation(String)
    case completionInProgress(String)
    case completionConflict(String)
    case duplicateArtifact(String)
    case artifactNotFound(String)
    case pendingWork(reservations: Int, artifacts: Int)
    case invalidArtifactDigest(String)
    case appendAfterCommit

    public var description: String {
        switch self {
        case .noActiveCapture: return "No active capture journal"
        case let .archiveAlreadyClaimed(id): return "Capture journal archive already claimed: \(id)"
        case let .captureAlreadyActive(id): return "Capture journal is already active: \(id)"
        case let .stateNotFound(id): return "Capture journal state not found: \(id)"
        case let .corruptState(detail): return "Corrupt capture journal state: \(detail)"
        case let .invalidTransition(from, to):
            return "Invalid capture journal transition: \(from.rawValue) -> \(to.rawValue)"
        case let .streamNotFound(id): return "Capture journal stream not found: \(id)"
        case let .emptyStream(id): return "Capture journal stream has no reservations: \(id)"
        case let .streamHasNoObservation(id):
            return "Capture journal stream has no resolved observation: \(id)"
        case let .staleReservation(id): return "Stale capture journal reservation: \(id)"
        case let .completionInProgress(id):
            return "Capture journal completion is already in progress: \(id)"
        case let .completionConflict(id): return "Capture journal completion conflicts: \(id)"
        case let .duplicateArtifact(id): return "Capture journal artifact already exists: \(id)"
        case let .artifactNotFound(id): return "Capture journal artifact not found: \(id)"
        case let .pendingWork(reservations, artifacts):
            return "Capture journal still has pending work (reservations: \(reservations), artifacts: \(artifacts))"
        case let .invalidArtifactDigest(value): return "Invalid artifact SHA-256: \(value)"
        case .appendAfterCommit: return "Capture journal rejects work after commit"
        }
    }
}

/// Single-writer, Foundation-only coordinator over ``JazzArchiveDraftStore``.
///
/// The coordinator file lives outside the portable archive draft. It is working state, analogous to
/// `sync/`, and records lifecycle plus pending producer work. Every reservation is persisted before
/// it is returned to a producer. Observation completion uses a small write-ahead intent so a relaunch
/// can distinguish "not appended" from "appended but not acknowledged in the ledger".
public actor CaptureJournal {
    private struct PersistedDocument: Codable, Sendable {
        var schemaVersion: Int
        var lifecycle: CaptureJournalLifecycle
        var archiveId: String
        var captureId: String
        var manifest: JazzArchiveManifest
        var session: JazzArchiveSession
        var streams: [StreamLedger]
        var artifacts: [ArtifactEntry]
        var commitIntent: CommitIntent?
    }

    private struct StreamLedger: Codable, Sendable {
        var streamId: String
        var nextSequence: Int
        var reservations: [ReservationEntry]
    }

    private enum ReservationStatus: String, Codable, Sendable {
        case pending
        case resolvingObservation
        case observation
        case gap
    }

    private struct ReservationEntry: Codable, Sendable {
        var reservationId: String
        var streamId: String
        var streamSequence: Int
        var status: ReservationStatus
        var observation: JazzArchiveRecord?
        var observationDigest: String?
        var gap: JazzArchiveSequenceGap?
    }

    private enum ArtifactStatus: String, Codable, Sendable {
        case pending
        case resolved
    }

    private struct ArtifactEntry: Codable, Sendable {
        var reservationId: String
        var artifactId: String
        var status: ArtifactStatus
        var sha256: String?
        var byteLength: Int64?
        var metadata: [String: JazzArchiveJSONValue]?
    }

    private struct CommitIntent: Codable, Equatable, Sendable {
        var endedAt: String
        var status: JazzArchiveSessionStatus?
    }

    public nonisolated let root: URL

    private let fileManager: FileManager
    private let archiveStore: JazzArchiveDraftStore
    private var document: PersistedDocument?

    private static let stateSchemaVersion = 1
    private static let stateRootName = ".capture-journal"
    private static let stateFileName = "state.json"
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        self.archiveStore = JazzArchiveDraftStore(root: root, fileManager: fileManager)
    }

    public func snapshot() -> CaptureJournalSnapshot {
        document.map(Self.snapshot) ?? .idle
    }

    /// Persist the `starting` claim without creating the archive draft yet. Keeping this explicit
    /// makes the first crash boundary testable: a relaunch can finish draft creation from the stored
    /// manifest/session before any event tap is enabled.
    @discardableResult
    public func prepare(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws -> CaptureJournalSnapshot {
        if let document, document.lifecycle != .committed {
            throw CaptureJournalError.captureAlreadyActive(document.archiveId)
        }
        try Self.validateStart(manifest: manifest, session: session)

        let stateDirectory = stateDirectory(manifest.archiveId)
        try fileManager.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: stateDirectory.path) else {
            throw CaptureJournalError.archiveAlreadyClaimed(manifest.archiveId)
        }
        do {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: false)
        } catch {
            if fileManager.fileExists(atPath: stateDirectory.path) {
                throw CaptureJournalError.archiveAlreadyClaimed(manifest.archiveId)
            }
            throw error
        }

        let streams = session.streamIds.sorted().map {
            StreamLedger(streamId: $0, nextSequence: 0, reservations: [])
        }
        let prepared = PersistedDocument(
            schemaVersion: Self.stateSchemaVersion,
            lifecycle: .starting,
            archiveId: manifest.archiveId,
            captureId: session.captureId,
            manifest: manifest,
            session: session,
            streams: streams,
            artifacts: [],
            commitIntent: nil)
        do {
            try persist(prepared)
        } catch {
            // Keep the exclusive claim directory. Reusing an identity after a partial claim is less
            // safe than surfacing it for recovery/diagnostics.
            throw error
        }
        document = prepared
        return Self.snapshot(prepared)
    }

    /// Finish `starting` and enter `recording`. This creates or verifies the underlying draft.
    @discardableResult
    public func startRecording() async throws -> CaptureJournalSnapshot {
        guard var current = document else { throw CaptureJournalError.noActiveCapture }
        guard current.lifecycle == .starting else {
            throw CaptureJournalError.invalidTransition(
                from: current.lifecycle, to: .recording)
        }
        let recovered = try await ensureDraft(for: current)
        current.manifest = recovered.manifest
        current.session = recovered.session
        current.lifecycle = .recording
        try install(current)
        return Self.snapshot(current)
    }

    /// Convenience for callers that do not need to pause at the durable `starting` boundary.
    @discardableResult
    public func begin(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) async throws -> CaptureJournalSnapshot {
        _ = try prepare(manifest: manifest, session: session)
        return try await startRecording()
    }

    /// Load an existing coordinator document and reconcile any operation whose intent was persisted
    /// immediately before a simulated process kill. `starting` resumes draft creation, observation
    /// intents become exactly one archive record, and a persisted commit intent finishes the commit.
    @discardableResult
    public func reopen(archiveId: String) async throws -> CaptureJournalSnapshot {
        var recovered = try load(archiveId: archiveId)
        document = recovered

        if recovered.lifecycle == .starting {
            let draft = try await ensureDraft(for: recovered)
            recovered.manifest = draft.manifest
            recovered.session = draft.session
            recovered.lifecycle = .recording
        } else {
            let manifest = try await archiveStore.manifest(archiveId: recovered.archiveId)
            let session = try await archiveStore.session(
                archiveId: recovered.archiveId, captureId: recovered.captureId)
            try Self.validateIdentity(recovered, manifest: manifest, session: session)
            recovered.manifest = manifest
            recovered.session = session
        }

        if recovered.lifecycle != .committed {
            recovered = try await reconcileObservationIntents(recovered)
            recovered = try await reconcileArtifactIntents(recovered)
        }
        if recovered.lifecycle == .draining, recovered.commitIntent != nil {
            let result = try await performCommit(recovered)
            recovered = result.document
        } else if recovered.lifecycle == .committed {
            _ = try await archiveStore.captureCommit(
                archiveId: recovered.archiveId, captureId: recovered.captureId)
        }
        try install(recovered)
        return Self.snapshot(recovered)
    }

    /// Incomplete coordinator claims visible on disk. Corrupt entries are deliberately included:
    /// callers can surface them instead of silently losing evidence.
    public func recoverableArchiveIds() -> [String] {
        guard
            let directories = try? fileManager.contentsOfDirectory(
                at: stateRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return directories.compactMap { url -> String? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let id = url.lastPathComponent
            guard let data = try? Data(contentsOf: url.appendingPathComponent(Self.stateFileName)),
                let value = try? Self.decoder.decode(PersistedDocument.self, from: data)
            else {
                // A claimed directory without readable state is recoverable/diagnostic work too.
                return id
            }
            return value.lifecycle == .committed ? nil : value.archiveId
        }.sorted()
    }

    /// Reserve the next producer-local stream position and persist it before returning. New work is
    /// admitted only while recording; already admitted work may finish during close/drain.
    public func reserve(streamId: String) throws -> CaptureJournalReservationToken {
        guard var current = document else { throw CaptureJournalError.noActiveCapture }
        try Self.requireNotCommitted(current)
        guard current.lifecycle == .recording else {
            throw CaptureJournalError.invalidTransition(
                from: current.lifecycle, to: .recording)
        }
        guard let streamIndex = current.streams.firstIndex(where: { $0.streamId == streamId }) else {
            throw CaptureJournalError.streamNotFound(streamId)
        }
        let sequence = current.streams[streamIndex].nextSequence
        let token = CaptureJournalReservationToken(
            reservationId: Self.newWorkingId(prefix: "res"),
            archiveId: current.archiveId,
            captureId: current.captureId,
            streamId: streamId,
            streamSequence: sequence)
        current.streams[streamIndex].nextSequence += 1
        current.streams[streamIndex].reservations.append(ReservationEntry(
            reservationId: token.reservationId,
            streamId: streamId,
            streamSequence: sequence,
            status: .pending,
            observation: nil,
            observationDigest: nil,
            gap: nil))
        try install(current)
        return token
    }

    /// Resolve a reserved position to one canonical observation. Sequential duplicate completion is
    /// idempotent; a different observation, a stale capture token, or completion after commit fails.
    public func resolveObservation<Payload: Codable & Sendable>(
        _ token: CaptureJournalReservationToken,
        record inputRecord: ArchiveRecord<Payload>
    ) async throws {
        let record = try JazzArchiveRecord(erasing: inputRecord)
        guard var current = document else { throw CaptureJournalError.noActiveCapture }
        try Self.requireResolutionLifecycle(current)
        let location = try locate(token, in: current)
        try Self.validate(record: record, token: token)
        try record.validateRecord(manifest: current.manifest, session: current.session)
        let digest = JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(record))
        let existing = current.streams[location.stream].reservations[location.reservation]
        switch existing.status {
        case .pending:
            current.streams[location.stream].reservations[location.reservation].status =
                .resolvingObservation
            current.streams[location.stream].reservations[location.reservation].observation = record
            current.streams[location.stream].reservations[location.reservation].observationDigest =
                digest
            try install(current)  // write-ahead intent
        case .resolvingObservation:
            throw CaptureJournalError.completionInProgress(token.reservationId)
        case .observation:
            guard existing.observation?.observationId == record.observationId,
                existing.observationDigest == digest
            else { throw CaptureJournalError.completionConflict(token.reservationId) }
            return
        case .gap:
            throw CaptureJournalError.completionConflict(token.reservationId)
        }

        try await appendIdempotently(
            record, archiveId: current.archiveId, reservationId: token.reservationId)

        guard var latest = document else { throw CaptureJournalError.noActiveCapture }
        try Self.requireResolutionLifecycle(latest)
        let latestLocation = try locate(token, in: latest)
        let intent = latest.streams[latestLocation.stream].reservations[latestLocation.reservation]
        guard intent.status == .resolvingObservation,
            intent.observation?.observationId == record.observationId,
            intent.observationDigest == digest
        else { throw CaptureJournalError.completionConflict(token.reservationId) }
        latest.streams[latestLocation.stream].reservations[latestLocation.reservation].status =
            .observation
        try install(latest)
    }

    /// Resolve a reserved position without inventing evidence. The explicit reason is carried into
    /// the CaptureCommit rather than inferred from a hole after the fact.
    public func resolveGap(
        _ token: CaptureJournalReservationToken,
        reason: JazzArchiveGapReason,
        detail: String? = nil
    ) throws {
        guard var current = document else { throw CaptureJournalError.noActiveCapture }
        try Self.requireResolutionLifecycle(current)
        let location = try locate(token, in: current)
        let gap = JazzArchiveSequenceGap(
            streamId: token.streamId,
            firstSequence: token.streamSequence,
            lastSequence: token.streamSequence,
            reason: reason,
            detail: detail)
        let existing = current.streams[location.stream].reservations[location.reservation]
        switch existing.status {
        case .pending:
            current.streams[location.stream].reservations[location.reservation].status = .gap
            current.streams[location.stream].reservations[location.reservation].gap = gap
            try install(current)
        case .gap:
            guard existing.gap == gap else {
                throw CaptureJournalError.completionConflict(token.reservationId)
            }
        case .resolvingObservation, .observation:
            throw CaptureJournalError.completionConflict(token.reservationId)
        }
    }

    /// Register artifact work before byte hashing/copying starts.
    public func reserveArtifact(
        artifactId: String = Identifiers.newArtifactId(),
        metadata: [String: JazzArchiveJSONValue]? = nil
    ) throws -> CaptureJournalArtifactToken {
        guard var current = document else { throw CaptureJournalError.noActiveCapture }
        try Self.requireNotCommitted(current)
        guard current.lifecycle == .recording else {
            throw CaptureJournalError.invalidTransition(
                from: current.lifecycle, to: .recording)
        }
        guard !current.artifacts.contains(where: { $0.artifactId == artifactId }) else {
            throw CaptureJournalError.duplicateArtifact(artifactId)
        }
        let token = CaptureJournalArtifactToken(
            reservationId: Self.newWorkingId(prefix: "ares"),
            archiveId: current.archiveId,
            captureId: current.captureId,
            artifactId: artifactId)
        current.artifacts.append(ArtifactEntry(
            reservationId: token.reservationId,
            artifactId: artifactId,
            status: .pending,
            sha256: nil,
            byteLength: nil,
            metadata: metadata))
        try install(current)
        return token
    }

    /// Resolve artifact integrity metadata. The same result is idempotent; a changed digest/length
    /// is a conflict and can never silently replace already observed material.
    public func resolveArtifact(
        _ token: CaptureJournalArtifactToken,
        sha256: String,
        byteLength: Int64,
        metadata: [String: JazzArchiveJSONValue]? = nil
    ) throws {
        guard var current = document else { throw CaptureJournalError.noActiveCapture }
        try Self.requireResolutionLifecycle(current)
        try Self.validateSHA256(sha256)
        guard byteLength >= 0 else {
            throw CaptureJournalError.completionConflict(token.reservationId)
        }
        let index = try locateArtifact(token, in: current)
        let existing = current.artifacts[index]
        switch existing.status {
        case .pending:
            current.artifacts[index].status = .resolved
            current.artifacts[index].sha256 = sha256
            current.artifacts[index].byteLength = byteLength
            if let metadata { current.artifacts[index].metadata = metadata }
            try install(current)
        case .resolved:
            guard existing.sha256 == sha256,
                existing.byteLength == byteLength,
                metadata == nil || existing.metadata == metadata
            else {
                throw CaptureJournalError.completionConflict(token.reservationId)
            }
        }
    }

    /// Persist bytes plus their canonical metadata into the archive draft, then resolve the
    /// durable producer ledger. A caller may start a Files upload only after this returns.
    @discardableResult
    public func ingestArtifact(
        _ token: CaptureJournalArtifactToken,
        bytes: Data,
        kind: String,
        mediaType: String,
        contentSchema: String? = nil,
        sourceRefs: [JazzArchiveSourceRef],
        actorRefs: [JazzArchiveActorRef] = [],
        labelRefs: [String] = [],
        observationRefs: [String] = [],
        captureInterval: JazzArchiveArtifactCaptureInterval? = nil,
        provenance: JazzArchiveProvenance,
        quality: JazzArchiveQuality,
        privacy: JazzArchivePrivacy,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) async throws -> JazzArchiveArtifact {
        try await ingestArtifact(
            token,
            payload: .bytes(bytes),
            kind: kind,
            mediaType: mediaType,
            contentSchema: contentSchema,
            sourceRefs: sourceRefs,
            actorRefs: actorRefs,
            labelRefs: labelRefs,
            observationRefs: observationRefs,
            captureInterval: captureInterval,
            provenance: provenance,
            quality: quality,
            privacy: privacy,
            extensions: extensions)
    }

    /// Persist an artifact from either small in-memory bytes or a sealed journal-owned file. The
    /// latter is fingerprinted and copied in bounded chunks and consumed only after canonical
    /// persistence succeeds.
    @discardableResult
    public func ingestArtifact(
        _ token: CaptureJournalArtifactToken,
        payload: CaptureJournalArtifactPayload,
        kind: String,
        mediaType: String,
        contentSchema: String? = nil,
        sourceRefs: [JazzArchiveSourceRef],
        actorRefs: [JazzArchiveActorRef] = [],
        labelRefs: [String] = [],
        observationRefs: [String] = [],
        captureInterval: JazzArchiveArtifactCaptureInterval? = nil,
        provenance: JazzArchiveProvenance,
        quality: JazzArchiveQuality,
        privacy: JazzArchivePrivacy,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) async throws -> JazzArchiveArtifact {
        guard let current = document else { throw CaptureJournalError.noActiveCapture }
        try Self.requireResolutionLifecycle(current)
        _ = try locateArtifact(token, in: current)
        let fingerprint: JazzArchiveFileFingerprint
        switch payload {
        case let .bytes(bytes):
            fingerprint = JazzArchiveFileFingerprint(
                sha256: JazzArchiveDigest.sha256Hex(bytes), byteLength: Int64(bytes.count))
        case let .claimedFile(claim):
            try claim.validate()
            fingerprint = try JazzArchiveFileIO.fingerprint(claim.url)
            try claim.validate()
        }
        let digest = fingerprint.sha256
        let path = "blobs/sha256/\(digest.prefix(2))/\(digest)"
        let artifact = JazzArchiveArtifact(
            artifactId: token.artifactId,
            captureId: token.captureId,
            origin: .captured,
            kind: kind,
            contentSchema: contentSchema,
            content: JazzArchiveArtifactContent(
                path: path,
                mediaType: mediaType,
                byteLength: fingerprint.byteLength,
                sha256: digest),
            sourceRefs: sourceRefs,
            actorRefs: actorRefs,
            labelRefs: labelRefs,
            observationRefs: observationRefs,
            captureInterval: captureInterval,
            provenance: provenance,
            quality: quality,
            privacy: privacy,
            extensions: extensions)
        try artifact.validate(manifest: current.manifest, session: current.session)
        switch payload {
        case let .bytes(bytes):
            _ = try await archiveStore.ingestArtifact(
                archiveId: current.archiveId,
                captureId: current.captureId,
                artifact: artifact,
                bytes: bytes)
        case let .claimedFile(claim):
            _ = try await archiveStore.ingestArtifact(
                archiveId: current.archiveId,
                captureId: current.captureId,
                artifact: artifact,
                claimedFile: claim)
            claim.discard()
        }
        try resolveArtifact(
            token,
            sha256: digest,
            byteLength: fingerprint.byteLength,
            metadata: Self.artifactMetadata(artifact))
        return artifact
    }

    @discardableResult
    public func closeInput() throws -> CaptureJournalSnapshot {
        try transition(from: .recording, to: .closingInput)
    }

    @discardableResult
    public func beginDraining() throws -> CaptureJournalSnapshot {
        try transition(from: .closingInput, to: .draining)
    }

    /// Commit never waits for network. It refuses unresolved local work, persists commit intent,
    /// and only then asks the archive draft store to write the transport-neutral CaptureCommit.
    @discardableResult
    public func commit(
        endedAt: String,
        status: JazzArchiveSessionStatus = .closed
    ) async throws -> JazzArchiveCaptureCommit {
        guard var current = document else { throw CaptureJournalError.noActiveCapture }
        try Self.requireNotCommitted(current)
        guard current.lifecycle == .draining else {
            throw CaptureJournalError.invalidTransition(
                from: current.lifecycle, to: .committed)
        }
        try Self.requireComplete(current)
        if let intent = current.commitIntent {
            guard intent.endedAt == endedAt, (intent.status ?? .closed) == status else {
                throw CaptureJournalError.completionConflict("commit")
            }
        } else {
            current.commitIntent = CommitIntent(endedAt: endedAt, status: status)
            try install(current)  // crash recovery resumes this exact commit
        }

        let result = try await performCommit(current)
        try install(result.document)
        return result.commit
    }

    /// Close an interrupted capture after relaunch without inventing observations. Any producer
    /// reservation that never reached canonical evidence becomes an explicit recovery gap; an
    /// artifact reservation is discarded only when no content-addressed artifact was published.
    @discardableResult
    public func recoverInterrupted(
        archiveId: String,
        endedAt: String = Timestamps.iso8601()
    ) async throws -> JazzArchiveCaptureCommit {
        let reopened = try await reopen(archiveId: archiveId)
        if reopened.lifecycle == .committed {
            guard let captureId = reopened.captureId else {
                throw CaptureJournalError.corruptState("committed capture identity")
            }
            return try await archiveStore.captureCommit(
                archiveId: archiveId,
                captureId: captureId)
        }
        guard var current = document else { throw CaptureJournalError.noActiveCapture }
        for streamIndex in current.streams.indices {
            for reservationIndex in current.streams[streamIndex].reservations.indices {
                let entry = current.streams[streamIndex].reservations[reservationIndex]
                guard entry.status == .pending else { continue }
                current.streams[streamIndex].reservations[reservationIndex].status = .gap
                current.streams[streamIndex].reservations[reservationIndex].gap =
                    JazzArchiveSequenceGap(
                        streamId: entry.streamId,
                        firstSequence: entry.streamSequence,
                        lastSequence: entry.streamSequence,
                        reason: .recoveryTruncation,
                        detail: "producer did not finish before process termination")
            }
        }
        current.artifacts.removeAll { $0.status == .pending }
        current.lifecycle = .draining
        current.commitIntent = CommitIntent(endedAt: endedAt, status: .recovered)
        try install(current)
        let result = try await performCommit(current)
        try install(result.document)
        return result.commit
    }

    // MARK: - Recovery and commit internals

    private func ensureDraft(
        for current: PersistedDocument
    ) async throws -> (manifest: JazzArchiveManifest, session: JazzArchiveSession) {
        do {
            let manifest = try await archiveStore.manifest(archiveId: current.archiveId)
            let session = try await archiveStore.session(
                archiveId: current.archiveId, captureId: current.captureId)
            try Self.validateIdentity(current, manifest: manifest, session: session)
            return (manifest, session)
        } catch let error as JazzArchiveError {
            guard case .archiveNotFound = error else { throw error }
            let manifest = try await archiveStore.create(
                manifest: current.manifest, session: current.session)
            let session = try await archiveStore.session(
                archiveId: current.archiveId, captureId: current.captureId)
            return (manifest, session)
        }
    }

    private func reconcileObservationIntents(
        _ input: PersistedDocument
    ) async throws -> PersistedDocument {
        var recovered = input
        var changed = false
        for streamIndex in recovered.streams.indices {
            for reservationIndex in recovered.streams[streamIndex].reservations.indices {
                let reservation = recovered.streams[streamIndex].reservations[reservationIndex]
                guard reservation.status == .resolvingObservation,
                    let record = reservation.observation,
                    let digest = reservation.observationDigest
                else { continue }
                let actualDigest = JazzArchiveDigest.sha256Hex(
                    try JazzArchiveCanonicalJSON.encode(record))
                guard actualDigest == digest else {
                    throw CaptureJournalError.corruptState(
                        "observation intent digest \(reservation.reservationId)")
                }
                try await appendIdempotently(
                    record,
                    archiveId: recovered.archiveId,
                    reservationId: reservation.reservationId)
                recovered.streams[streamIndex].reservations[reservationIndex].status = .observation
                changed = true
            }
        }
        if changed { try persist(recovered) }
        return recovered
    }

    private func reconcileArtifactIntents(
        _ input: PersistedDocument
    ) async throws -> PersistedDocument {
        var recovered = input
        var changed = false
        for index in recovered.artifacts.indices where recovered.artifacts[index].status == .pending {
            let entry = recovered.artifacts[index]
            guard
                let artifact = try? await archiveStore.artifact(
                    archiveId: recovered.archiveId,
                    captureId: recovered.captureId,
                    artifactId: entry.artifactId)
            else { continue }
            recovered.artifacts[index].status = .resolved
            recovered.artifacts[index].sha256 = artifact.content.sha256
            recovered.artifacts[index].byteLength = artifact.content.byteLength
            recovered.artifacts[index].metadata = Self.artifactMetadata(artifact)
            changed = true
        }
        if changed { try persist(recovered) }
        return recovered
    }

    private func appendIdempotently(
        _ record: JazzArchiveRecord,
        archiveId: String,
        reservationId: String
    ) async throws {
        let records = try await archiveStore.allRecords(
            archiveId: archiveId,
            captureId: record.captureId)
        if let existing = records.first(where: {
            $0.streamId == record.streamId && $0.streamSequence == record.streamSequence
        }) {
            let expected = JazzArchiveDigest.sha256Hex(
                try JazzArchiveCanonicalJSON.encode(record))
            let actual = JazzArchiveDigest.sha256Hex(
                try JazzArchiveCanonicalJSON.encode(existing))
            guard existing.observationId == record.observationId, actual == expected else {
                throw CaptureJournalError.completionConflict(reservationId)
            }
            return
        }
        _ = try await archiveStore.append(
            archiveId: archiveId,
            captureId: record.captureId,
            records: [record],
            batchId: Self.batchId(reservationId: reservationId))
    }

    private func performCommit(
        _ input: PersistedDocument
    ) async throws -> (document: PersistedDocument, commit: JazzArchiveCaptureCommit) {
        var committed = input
        try Self.requireComplete(committed)
        guard let intent = committed.commitIntent else {
            throw CaptureJournalError.corruptState("missing commit intent")
        }
        let gaps = Self.coalescedGaps(committed)
        let artifactDigests = Dictionary(uniqueKeysWithValues: committed.artifacts.map {
            ($0.artifactId, $0.sha256!)
        })
        let session = try await archiveStore.end(
            archiveId: committed.archiveId,
            captureId: committed.captureId,
            endedAt: intent.endedAt,
            status: intent.status ?? .closed,
            artifactDigests: artifactDigests,
            declaredGaps: gaps)
        let manifest = try await archiveStore.manifest(archiveId: committed.archiveId)
        let commit = try await archiveStore.captureCommit(
            archiveId: committed.archiveId, captureId: committed.captureId)
        committed.session = session
        committed.manifest = manifest
        committed.lifecycle = .committed
        return (committed, commit)
    }

    // MARK: - State mutation

    private func transition(
        from expected: CaptureJournalLifecycle,
        to next: CaptureJournalLifecycle
    ) throws -> CaptureJournalSnapshot {
        guard var current = document else { throw CaptureJournalError.noActiveCapture }
        try Self.requireNotCommitted(current)
        guard current.lifecycle == expected else {
            throw CaptureJournalError.invalidTransition(from: current.lifecycle, to: next)
        }
        current.lifecycle = next
        try install(current)
        return Self.snapshot(current)
    }

    private func install(_ value: PersistedDocument) throws {
        try Self.validatePersisted(value)
        try persist(value)
        document = value
    }

    private func persist(_ value: PersistedDocument) throws {
        let url = stateURL(value.archiveId)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    private func load(archiveId: String) throws -> PersistedDocument {
        let url = stateURL(archiveId)
        guard fileManager.fileExists(atPath: url.path) else {
            throw CaptureJournalError.stateNotFound(archiveId)
        }
        do {
            let value = try Self.decoder.decode(
                PersistedDocument.self, from: Data(contentsOf: url))
            guard value.archiveId == archiveId else {
                throw CaptureJournalError.corruptState("archive identity mismatch")
            }
            try Self.validatePersisted(value)
            return value
        } catch let error as CaptureJournalError {
            throw error
        } catch {
            throw CaptureJournalError.corruptState(error.localizedDescription)
        }
    }

    private var stateRoot: URL {
        root.appendingPathComponent(Self.stateRootName, isDirectory: true)
    }

    private func stateDirectory(_ archiveId: String) -> URL {
        stateRoot.appendingPathComponent(archiveId, isDirectory: true)
    }

    private func stateURL(_ archiveId: String) -> URL {
        stateDirectory(archiveId).appendingPathComponent(Self.stateFileName)
    }

    // MARK: - Validation

    private func locate(
        _ token: CaptureJournalReservationToken,
        in value: PersistedDocument
    ) throws -> (stream: Int, reservation: Int) {
        guard token.archiveId == value.archiveId, token.captureId == value.captureId else {
            throw CaptureJournalError.staleReservation(token.reservationId)
        }
        guard let stream = value.streams.firstIndex(where: { $0.streamId == token.streamId }),
            let reservation = value.streams[stream].reservations.firstIndex(where: {
                $0.reservationId == token.reservationId
            })
        else { throw CaptureJournalError.staleReservation(token.reservationId) }
        let entry = value.streams[stream].reservations[reservation]
        guard entry.streamId == token.streamId,
            entry.streamSequence == token.streamSequence
        else { throw CaptureJournalError.staleReservation(token.reservationId) }
        return (stream, reservation)
    }

    private func locateArtifact(
        _ token: CaptureJournalArtifactToken,
        in value: PersistedDocument
    ) throws -> Int {
        guard token.archiveId == value.archiveId, token.captureId == value.captureId else {
            throw CaptureJournalError.staleReservation(token.reservationId)
        }
        guard let index = value.artifacts.firstIndex(where: {
            $0.reservationId == token.reservationId && $0.artifactId == token.artifactId
        }) else { throw CaptureJournalError.artifactNotFound(token.artifactId) }
        return index
    }

    private static func validateStart(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws {
        try manifest.validate()
        try session.validate()
        guard manifest.state == .live, session.status == .open,
            manifest.archiveId == session.archiveId,
            manifest.sessions.contains(where: { $0.captureId == session.captureId }),
            Set(session.streamIds).count == session.streamIds.count
        else { throw CaptureJournalError.corruptState("invalid starting manifest/session") }
    }

    private static func validateIdentity(
        _ value: PersistedDocument,
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws {
        guard manifest.archiveId == value.archiveId,
            session.archiveId == value.archiveId,
            session.captureId == value.captureId
        else { throw CaptureJournalError.corruptState("archive/capture identity mismatch") }
    }

    private static func validatePersisted(_ value: PersistedDocument) throws {
        guard value.schemaVersion == Self.stateSchemaVersion else {
            throw CaptureJournalError.corruptState(
                "unsupported schema version \(value.schemaVersion)")
        }
        try validateIdentity(value, manifest: value.manifest, session: value.session)
        guard value.lifecycle != .idle else {
            throw CaptureJournalError.corruptState("idle must not be persisted")
        }
        let streamIds = value.streams.map(\.streamId)
        guard Set(streamIds).count == streamIds.count,
            Set(streamIds) == Set(value.session.streamIds)
        else { throw CaptureJournalError.corruptState("stream registry mismatch") }
        var reservationIds = Set<String>()
        for stream in value.streams {
            guard stream.nextSequence >= 0 else {
                throw CaptureJournalError.corruptState("negative next sequence")
            }
            var sequences = Set<Int>()
            for reservation in stream.reservations {
                guard reservation.streamId == stream.streamId,
                    reservation.streamSequence >= 0,
                    reservation.streamSequence < stream.nextSequence,
                    sequences.insert(reservation.streamSequence).inserted,
                    reservationIds.insert(reservation.reservationId).inserted
                else { throw CaptureJournalError.corruptState("invalid reservation ledger") }
                switch reservation.status {
                case .pending:
                    guard reservation.observation == nil,
                        reservation.observationDigest == nil,
                        reservation.gap == nil
                    else { throw CaptureJournalError.corruptState("pending has resolution") }
                case .resolvingObservation, .observation:
                    guard let observation = reservation.observation,
                        let observationDigest = reservation.observationDigest,
                        observation.streamId == stream.streamId,
                        observation.streamSequence == reservation.streamSequence,
                        reservation.gap == nil
                    else { throw CaptureJournalError.corruptState("invalid observation resolution") }
                    let actualDigest = JazzArchiveDigest.sha256Hex(
                        try JazzArchiveCanonicalJSON.encode(observation))
                    guard observationDigest == actualDigest else {
                        throw CaptureJournalError.corruptState("observation resolution digest")
                    }
                case .gap:
                    guard let gap = reservation.gap,
                        gap.streamId == stream.streamId,
                        gap.firstSequence == reservation.streamSequence,
                        gap.lastSequence == reservation.streamSequence,
                        reservation.observation == nil,
                        reservation.observationDigest == nil
                    else { throw CaptureJournalError.corruptState("invalid gap resolution") }
                }
            }
            guard sequences.count == stream.nextSequence else {
                throw CaptureJournalError.corruptState("non-contiguous reservation ledger")
            }
        }
        guard Set(value.artifacts.map(\.artifactId)).count == value.artifacts.count,
            Set(value.artifacts.map(\.reservationId)).count == value.artifacts.count
        else { throw CaptureJournalError.corruptState("duplicate artifact ledger") }
        for artifact in value.artifacts {
            switch artifact.status {
            case .pending:
                guard artifact.sha256 == nil, artifact.byteLength == nil else {
                    throw CaptureJournalError.corruptState("pending artifact has resolution")
                }
            case .resolved:
                guard let sha256 = artifact.sha256, let byteLength = artifact.byteLength,
                    byteLength >= 0
                else { throw CaptureJournalError.corruptState("resolved artifact lacks metadata") }
                try validateSHA256(sha256)
            }
        }
        if value.lifecycle == .committed {
            guard value.commitIntent != nil, value.session.captureCommit != nil else {
                throw CaptureJournalError.corruptState("committed state lacks commit")
            }
        }
    }

    private static func validate(
        record: JazzArchiveRecord,
        token: CaptureJournalReservationToken
    ) throws {
        guard record.captureId == token.captureId,
            record.streamId == token.streamId,
            record.streamSequence == token.streamSequence
        else { throw CaptureJournalError.staleReservation(token.reservationId) }
    }

    private static func validateSHA256(_ value: String) throws {
        guard value.count == 64,
            value.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw CaptureJournalError.invalidArtifactDigest(value) }
    }

    private static func requireNotCommitted(_ value: PersistedDocument) throws {
        guard value.lifecycle != .committed else {
            throw CaptureJournalError.appendAfterCommit
        }
    }

    private static func requireResolutionLifecycle(_ value: PersistedDocument) throws {
        try requireNotCommitted(value)
        guard [.recording, .closingInput, .draining].contains(value.lifecycle) else {
            throw CaptureJournalError.invalidTransition(
                from: value.lifecycle, to: .draining)
        }
    }

    private static func requireComplete(_ value: PersistedDocument) throws {
        let pendingReservations = value.streams.flatMap(\.reservations).filter {
            $0.status == .pending || $0.status == .resolvingObservation
        }.count
        let pendingArtifacts = value.artifacts.filter { $0.status == .pending }.count
        guard pendingReservations == 0, pendingArtifacts == 0 else {
            throw CaptureJournalError.pendingWork(
                reservations: pendingReservations, artifacts: pendingArtifacts)
        }
        for stream in value.streams {
            guard !stream.reservations.isEmpty else {
                throw CaptureJournalError.emptyStream(stream.streamId)
            }
            guard stream.reservations.contains(where: { $0.status == .observation }) else {
                throw CaptureJournalError.streamHasNoObservation(stream.streamId)
            }
        }
    }

    private static func snapshot(_ value: PersistedDocument) -> CaptureJournalSnapshot {
        let reservations = value.streams.flatMap(\.reservations)
        return CaptureJournalSnapshot(
            lifecycle: value.lifecycle,
            archiveId: value.archiveId,
            captureId: value.captureId,
            nextSequenceByStream: Dictionary(uniqueKeysWithValues: value.streams.map {
                ($0.streamId, $0.nextSequence)
            }),
            pendingReservationCount: reservations.filter {
                $0.status == .pending || $0.status == .resolvingObservation
            }.count,
            resolvedObservationCount: reservations.filter { $0.status == .observation }.count,
            gapCount: reservations.filter { $0.status == .gap }.count,
            pendingArtifactCount: value.artifacts.filter { $0.status == .pending }.count,
            resolvedArtifactCount: value.artifacts.filter { $0.status == .resolved }.count)
    }

    private static func coalescedGaps(_ value: PersistedDocument) -> [JazzArchiveSequenceGap] {
        let gaps = value.streams.flatMap(\.reservations).compactMap(\.gap).sorted {
            ($0.streamId, $0.firstSequence, $0.lastSequence)
                < ($1.streamId, $1.firstSequence, $1.lastSequence)
        }
        var result: [JazzArchiveSequenceGap] = []
        for gap in gaps {
            if var last = result.last,
                last.streamId == gap.streamId,
                last.lastSequence + 1 == gap.firstSequence,
                last.reason == gap.reason,
                last.detail == gap.detail
            {
                last.lastSequence = gap.lastSequence
                result[result.count - 1] = last
            } else {
                result.append(gap)
            }
        }
        return result
    }

    private static func newWorkingId(prefix: String) -> String {
        "\(prefix)-\(Identifiers.newUUIDv7().uuidString.lowercased())"
    }

    private static func batchId(reservationId: String) -> String {
        let separator = reservationId.firstIndex(of: "-")!
        return "batch-\(reservationId[reservationId.index(after: separator)...])"
    }

    private static func artifactMetadata(
        _ artifact: JazzArchiveArtifact
    ) -> [String: JazzArchiveJSONValue] {
        [
            "kind": .string(artifact.kind),
            "mediaType": .string(artifact.content.mediaType),
            "path": .string(artifact.content.path),
        ]
    }
}
