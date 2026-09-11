import Foundation

/// Local recovery context, not a new emitted contract. The timestamp is the recorder admission
/// boundary (persisted immediately before enabling it). Closed receipts separately preserve the
/// recorder's reported-active start and native stop, so setup/fsync latency is not audio duration.
public struct CaptureJournalNarrationContext: Codable, Equatable, Sendable {
    public let archiveId: String
    public let artifactId: String
    public let observationId: String
    public let context: CaptureJournalActivityContext
    public let modality: JazzArchiveModality
    public let privacy: JazzArchivePrivacy
    public let event: ActivityEvent
    public let labelStartEvent: ActivityEvent
    public let labelStartObservationId: String
    public let labelStartExtensions: [String: JazzArchiveJSONValue]?

    public init(
        archiveId: String, artifactId: String,
        observationId: String = Identifiers.newObservationId(),
        context: CaptureJournalActivityContext, event: ActivityEvent,
        labelStartEvent: ActivityEvent, labelStartObservationId: String,
        labelStartExtensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.archiveId = archiveId
        self.artifactId = artifactId
        self.observationId = observationId
        self.context = context
        self.modality = .narration
        self.privacy = JazzArchivePrivacy(status: .captured, policyVersion: context.policyVersion)
        self.event = event
        self.labelStartEvent = labelStartEvent
        self.labelStartObservationId = labelStartObservationId
        self.labelStartExtensions = labelStartExtensions
    }

    func record(sequence: Int, labelStart: Bool = false, startedAt: String? = nil) -> ArchiveRecord<ActivityEvent> {
        var capturedEvent = event
        if let startedAt { capturedEvent.timestamp = startedAt }
        return ArchiveRecord(
            event: labelStart ? labelStartEvent : capturedEvent,
            observationId: labelStart ? labelStartObservationId : observationId,
            originId: context.originId,
            captureId: context.captureId, streamId: context.streamId, streamSequence: sequence,
            sourceRefs: [JazzArchiveSourceRef(sourceId: context.sourceId, role: "trigger")],
            actorRefs: [JazzArchiveActorRef(
                actorId: context.actorId, role: "performer", basis: .declared,
                method: "session_recorder")],
            artifactRefs: labelStart ? [] : [JazzArchiveArtifactRef(artifactId: artifactId, role: "narration_audio")],
            provenance: JazzArchiveProvenance(factClass: .observed, sources: [context.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: privacy,
            extensions: labelStart ? labelStartExtensions : nil)
    }

    func artifact(claim: JazzArchiveClaimedFile, startedAt: String, endedAt: String) -> JazzArchiveArtifact {
        let fingerprint = claim.fingerprint
        return JazzArchiveArtifact(
            artifactId: artifactId, captureId: context.captureId, origin: .captured,
            kind: "narration_audio",
            content: JazzArchiveArtifactContent(
                path: "blobs/sha256/\(fingerprint.sha256.prefix(2))/\(fingerprint.sha256)",
                mediaType: "audio/mp4", byteLength: fingerprint.byteLength,
                sha256: fingerprint.sha256),
            sourceRefs: [JazzArchiveSourceRef(sourceId: context.sourceId, role: "microphone_capture")],
            actorRefs: [JazzArchiveActorRef(
                actorId: context.actorId, role: "narrator", basis: .declared,
                method: "session_recorder")],
            labelRefs: event.labelId.map { [$0] } ?? [], observationRefs: [observationId],
            captureInterval: JazzArchiveArtifactCaptureInterval(
                startedAt: startedAt, endedAt: endedAt),
            provenance: JazzArchiveProvenance(factClass: .observed, sources: [context.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: privacy)
    }

    func validate(manifest: JazzArchiveManifest, session: JazzArchiveSession) throws {
        guard archiveId == manifest.archiveId, context.captureId == session.captureId,
            context.originId == manifest.originId, session.streamIds.contains(context.streamId),
            session.sourceIds.contains(context.sourceId), session.recorderActorId == context.actorId,
            context.policyVersion == session.capturePolicy.policyVersion,
            modality == .narration, session.capturePolicy.modalities.contains(modality),
            privacy == JazzArchivePrivacy(status: .captured, policyVersion: context.policyVersion),
            event.sessionId == session.legacySessionId, event.eventType == EventType.narration.rawValue,
            event.labelId != nil, event.label != nil,
            labelStartEvent.eventType == EventType.labelStart.rawValue,
            labelStartEvent.sessionId == event.sessionId,
            labelStartEvent.labelId == event.labelId, labelStartEvent.label == event.label,
            labelStartEvent.processId == event.processId, labelStartEvent.process == event.process,
            labelStartObservationId != observationId, labelStartEvent.eventId != event.eventId,
            let labelStart = Timestamps.parse(labelStartEvent.timestamp),
            let start = Timestamps.parse(event.timestamp), labelStart <= start,
            let sessionStart = Timestamps.parse(session.startedAt), start >= sessionStart
        else { throw CaptureJournalError.corruptState("narration admission context") }
        try record(sequence: 0).validate(manifest: manifest, session: session)
        try record(sequence: 0, labelStart: true).validate(manifest: manifest, session: session)
    }
}

/// Immutable admission and close receipts live outside the media directory. They remain after
/// publication as independent bindings for WAL/checkpoint replay; neither receipt grants ownership.
struct CaptureJournalNarrationReceipt: Codable, Equatable {
    var schemaVersion = 1
    var metadata: CaptureJournalNarrationContext
    var sealedURL: URL

    struct Closed: Codable, Equatable {
        var admissionDigest: String
        var startedAt: String
        var endedAt: String
        var claim: JazzArchiveClaimedFile
        var contentSHA256: String?

        var digest: String {
            get throws {
                var content = self
                content.contentSHA256 = nil
                return JazzArchiveDigest.sha256Hex(try JazzArchiveCanonicalJSON.encode(content))
            }
        }
    }

    static func directory(root: URL, archiveId: String, captureId: String) throws -> URL {
        for component in [archiveId, captureId] {
            try JazzArchiveWritableFileClaim.validatePathComponent(component)
        }
        return root.standardizedFileURL.appendingPathComponent(".artifact-contexts")
            .appendingPathComponent(archiveId).appendingPathComponent(captureId)
    }

    static func url(directory: URL, artifactId: String, closed: Bool = false) throws -> URL {
        try JazzArchiveWritableFileClaim.validatePathComponent(artifactId)
        return directory.appendingPathComponent(artifactId + (closed ? ".closed.json" : ".start.json"))
    }

    static func read<T: Decodable>(_ type: T.Type, at url: URL, root: URL) throws -> T {
        try validateDirectories(url.deletingLastPathComponent(), root: root)
        _ = try JazzArchiveFileSnapshot.capture(url, fileManager: .default)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func validateDirectories(_ directory: URL, root: URL) throws {
        var current = directory
        while current.pathComponents.count >= root.standardizedFileURL.pathComponents.count {
            let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw JazzArchiveClaimError.notRegularFile(current.path)
            }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
    }

    static func write<T: Encodable>(
        _ value: T, at url: URL, root: URL, durability: JazzArchiveFilesystemDurability
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try validateDirectories(directory, root: root)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw JazzArchiveClaimError.alreadyExists(url.path)
        }
        try JazzArchiveCanonicalJSON.encode(value).write(to: url, options: .withoutOverwriting)
        try durability.synchronizeRegularFile(url, permissions: Int16(0o400))
        var current = directory
        while current.pathComponents.count >= root.standardizedFileURL.pathComponents.count {
            try durability.synchronizeDirectory(current)
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
        try durability.synchronizeDirectory(root.deletingLastPathComponent())
    }

    var digest: String {
        get throws { JazzArchiveDigest.sha256Hex(try JazzArchiveCanonicalJSON.encode(self)) }
    }

    func validate(root: URL, manifest: JazzArchiveManifest, session: JazzArchiveSession) throws {
        guard schemaVersion == 1, sealedURL.pathExtension == "m4a" else {
            throw CaptureJournalError.corruptState("narration receipt version/container")
        }
        try metadata.validate(manifest: manifest, session: session)
        try JazzArchiveClaimedFile.validateOwnership(
            url: sealedURL, root: root, archiveId: manifest.archiveId,
            captureId: session.captureId, artifactId: metadata.artifactId)
    }

    func validate(_ closed: Closed) throws {
        guard closed.contentSHA256 == (try closed.digest),
            closed.admissionDigest == (try digest), closed.claim.url == sealedURL,
            closed.claim.fingerprint.byteLength > 0
        else { throw CaptureJournalError.corruptState("narration close receipt binding") }
        try JazzArchiveArtifactCaptureInterval(
            startedAt: metadata.event.timestamp, endedAt: closed.startedAt).validate()
        try JazzArchiveArtifactCaptureInterval(
            startedAt: closed.startedAt, endedAt: closed.endedAt).validate()
    }

    /// A close receipt proves the native writer stopped and its container was readable. Never
    /// promote an open crash recording based on mtime, recovery time, or a guessed duration.
    func recoverSealedFile(_ closed: Closed, durability: JazzArchiveFilesystemDurability) throws {
        try validate(closed)
        if !FileManager.default.fileExists(atPath: sealedURL.path) {
            let recordingURL = sealedURL.deletingLastPathComponent().appendingPathComponent(
                metadata.artifactId + ".recording.m4a")
            let recording = JazzArchiveClaimedFile(
                url: recordingURL, snapshot: closed.claim.snapshot,
                fingerprint: closed.claim.fingerprint)
            try recording.validate()
            try FileManager.default.moveItem(at: recordingURL, to: sealedURL)
        }
        try closed.claim.validate()
        try durability.synchronizeRegularFile(sealedURL, permissions: Int16(0o400))
        try durability.synchronizeDirectory(sealedURL.deletingLastPathComponent())
    }
}

extension JazzArchiveWritableFileClaim {
    private var narrationRoot: URL {
        recordingURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Must succeed before the recorder is admitted. The writable capability is not Codable and
    /// the journal independently validates all receipt identities before ingest or recovery.
    public func recordNarrationStart(
        _ metadata: CaptureJournalNarrationContext,
        durability: JazzArchiveFilesystemDurability
    ) throws -> String {
        let root = narrationRoot
        try JazzArchiveClaimedFile.validateOwnership(
            url: sealedURL, root: root, archiveId: metadata.archiveId,
            captureId: metadata.context.captureId, artifactId: metadata.artifactId)
        guard recordingURL.lastPathComponent == metadata.artifactId + ".recording.m4a" else {
            throw JazzArchiveClaimError.invalidComponent("narration recording name")
        }
        _ = try JazzArchiveFileSnapshot.capture(recordingURL, fileManager: .default)
        try durability.synchronizeRegularFile(recordingURL, permissions: Int16(0o600))
        var claimDirectory = recordingURL.deletingLastPathComponent()
        for _ in 0..<5 {
            try durability.synchronizeDirectory(claimDirectory)
            claimDirectory.deleteLastPathComponent()
        }
        let directory = try CaptureJournalNarrationReceipt.directory(
            root: root, archiveId: metadata.archiveId, captureId: metadata.context.captureId)
        let receipt = CaptureJournalNarrationReceipt(metadata: metadata, sealedURL: sealedURL)
        try CaptureJournalNarrationReceipt.write(
            receipt,
            at: CaptureJournalNarrationReceipt.url(directory: directory, artifactId: metadata.artifactId),
            root: root, durability: durability)
        return try receipt.digest
    }

    /// Called after native stop/container verification, before seal or asynchronous admission.
    /// Failed persistence retains both names and never permits a fabricated closed interval.
    public func recordNarrationStop(
        startedAt: String, endedAt: String, admissionDigest: String, durability: JazzArchiveFilesystemDurability
    ) throws {
        let root = narrationRoot
        let captureDirectory = recordingURL.deletingLastPathComponent()
        let artifactId = String(recordingURL.lastPathComponent.dropLast(".recording.m4a".count))
        let directory = try CaptureJournalNarrationReceipt.directory(
            root: root, archiveId: captureDirectory.deletingLastPathComponent().lastPathComponent,
            captureId: captureDirectory.lastPathComponent)
        let receipt = try CaptureJournalNarrationReceipt.read(
            CaptureJournalNarrationReceipt.self,
            at: CaptureJournalNarrationReceipt.url(directory: directory, artifactId: artifactId), root: root)
        guard receipt.sealedURL == sealedURL, receipt.metadata.artifactId == artifactId,
            try receipt.digest == admissionDigest else {
            throw CaptureJournalError.corruptState("narration writable claim binding")
        }
        try durability.synchronizeRegularFile(recordingURL, permissions: Int16(0o600))
        let snapshot = try JazzArchiveFileSnapshot.capture(recordingURL, fileManager: .default)
        let fingerprint = try JazzArchiveFileIO.fingerprint(recordingURL)
        let recording = JazzArchiveClaimedFile(url: recordingURL, snapshot: snapshot, fingerprint: fingerprint)
        try recording.validate()
        var closed = CaptureJournalNarrationReceipt.Closed(
            admissionDigest: admissionDigest, startedAt: startedAt, endedAt: endedAt,
            claim: JazzArchiveClaimedFile(url: sealedURL, snapshot: snapshot, fingerprint: fingerprint))
        closed.contentSHA256 = try closed.digest
        try receipt.validate(closed)
        // The file's directory chain must survive a crash before the later seal rename too.
        var directoryToSync = captureDirectory
        for _ in 0..<5 {
            try durability.synchronizeDirectory(directoryToSync)
            directoryToSync.deleteLastPathComponent()
        }
        try CaptureJournalNarrationReceipt.write(
            closed,
            at: CaptureJournalNarrationReceipt.url(directory: directory, artifactId: artifactId, closed: true),
            root: root, durability: durability)
    }
}
