import Foundation

public struct JazzArchiveProjectionReconciliation: Equatable, Sendable {
    public var archiveId: String
    public var observationCount: Int
    public var artifactCount: Int

    public init(archiveId: String, observationCount: Int, artifactCount: Int) {
        self.archiveId = archiveId
        self.observationCount = observationCount
        self.artifactCount = artifactCount
    }
}

/// Rebuilds mutable transport outboxes from canonical archive evidence. It is safe to run after
/// every launch and close: both sinks key writes by stable observation/artifact identity and reject
/// conflicting bytes instead of silently duplicating them.
public actor JazzArchiveProjectionReconciler {
    private let store: JazzArchiveDraftStore
    private let eventSpool: EventSpool
    private let artifactQueue: JazzArchiveDeliveryQueue

    public init(
        archiveRoot: URL,
        eventSpool: EventSpool,
        artifactQueue: JazzArchiveDeliveryQueue,
        durability: JazzArchiveFilesystemDurability
    ) {
        self.store = JazzArchiveDraftStore(
            root: archiveRoot, durability: durability)
        self.eventSpool = eventSpool
        self.artifactQueue = artifactQueue
    }

    public func reconcileAll() async -> [Result<JazzArchiveProjectionReconciliation, Error>] {
        let ids = await store.draftArchiveIds()
        var results: [Result<JazzArchiveProjectionReconciliation, Error>] = []
        for id in ids {
            do { results.append(.success(try await reconcile(archiveId: id))) }
            catch { results.append(.failure(error)) }
        }
        return results
    }

    @discardableResult
    public func reconcile(archiveId: String) async throws
        -> JazzArchiveProjectionReconciliation
    {
        let manifest = try await store.manifest(archiveId: archiveId)
        var observationCount = 0
        var artifactCount = 0
        for sessionRef in manifest.sessions {
            let session = try await store.session(
                archiveId: archiveId, captureId: sessionRef.captureId)
            let records = try await store.records(
                archiveId: archiveId, captureId: session.captureId)
            guard let legacySessionId = session.legacySessionId
                ?? records.first?.payload.sessionId
            else { continue }

            try ensureProjectionSession(
                manifest: manifest, session: session, legacySessionId: legacySessionId)
            let binding = try JazzLiveCanonicalBinding(
                archiveId: manifest.archiveId,
                originId: manifest.originId,
                captureId: session.captureId)
            try eventSpool.bindLiveCanonicalSession(
                sessionId: legacySessionId,
                binding: binding)
            let artifacts = try await store.artifacts(
                archiveId: archiveId, captureId: session.captureId)
            let artifactsById = Dictionary(
                uniqueKeysWithValues: artifacts.map { ($0.artifactId, $0) })
            for record in records {
                let associatedArtifacts = record.artifactRefs.compactMap {
                    artifactsById[$0.artifactId]
                }
                _ = try eventSpool.appendCanonicalProjection(
                    sessionId: legacySessionId,
                    binding: binding,
                    record: try JazzArchiveRecord(erasing: record),
                    artifacts: associatedArtifacts,
                    event: record.payload)
                observationCount += 1
            }
            if let endedAt = session.endedAt {
                let commit = try await store.captureCommit(
                    archiveId: archiveId, captureId: session.captureId)
                try eventSpool.endSession(
                    sessionId: legacySessionId,
                    endedAt: endedAt,
                    captureCommit: commit)
            }

            var eventByArtifact: [String: ActivityEvent] = [:]
            for record in records {
                for ref in record.artifactRefs where eventByArtifact[ref.artifactId] == nil {
                    eventByArtifact[ref.artifactId] = record.payload
                }
            }
            for artifact in artifacts {
                let event = eventByArtifact[artifact.artifactId]
                _ = try await artifactQueue.enqueue(Self.deliveryEntry(
                    archiveId: archiveId,
                    session: session,
                    legacySessionId: legacySessionId,
                    artifact: artifact,
                    event: event))
                artifactCount += 1
            }
        }
        return JazzArchiveProjectionReconciliation(
            archiveId: archiveId,
            observationCount: observationCount,
            artifactCount: artifactCount)
    }

    private func ensureProjectionSession(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession,
        legacySessionId: String
    ) throws {
        guard eventSpool.sessionMeta(sessionId: legacySessionId) == nil else { return }
        let actor = manifest.actors.first { $0.actorId == session.recorderActorId }
        let source = manifest.sources.first { session.sourceIds.contains($0.sourceId) }
        let user = actor?.externalIdentities?.first?.value ?? actor?.displayName ?? "unknown"
        let host = source?.externalIdentities?.first(where: { $0.namespace == "macos.host" })?.value
            ?? "unknown"
        let binding = try JazzLiveCanonicalBinding(
            archiveId: manifest.archiveId,
            originId: manifest.originId,
            captureId: session.captureId)
        try eventSpool.createSession(EventSpool.SessionMeta(
            sessionId: legacySessionId,
            traceId: OtlpIds.traceId(),
            spanId: OtlpIds.spanId(),
            startedAt: session.startedAt,
            kind: session.sessionKind,
            user: user,
            instanceName: host,
            areaId: session.area?.areaId,
            areaName: session.area?.nameSnapshot,
            liveCanonicalBinding: binding,
            endedAt: nil))
    }

    public static func deliveryEntry(
        archiveId: String,
        session: JazzArchiveSession,
        legacySessionId: String,
        artifact: JazzArchiveArtifact,
        event: ActivityEvent?
    ) -> JazzArchiveDeliveryEntry {
        var tags = [
            "jasnost", "session:\(legacySessionId)", "jazz-artifact",
            "artifact:\(artifact.artifactId)", "kind:\(artifact.kind)",
        ]
        if let labelId = event?.labelId ?? artifact.labelRefs.first {
            tags.append("label:\(labelId)")
        }
        let ext = fileExtension(
            mediaType: artifact.content.mediaType, kind: artifact.kind)
        return JazzArchiveDeliveryEntry(
            archiveId: archiveId,
            captureId: session.captureId,
            artifactId: artifact.artifactId,
            legacySessionId: legacySessionId,
            kind: artifact.kind,
            mediaType: artifact.content.mediaType,
            fileName: "jazz-\(legacySessionId)-\(artifact.artifactId).\(ext)",
            tags: tags,
            labelId: event?.labelId ?? artifact.labelRefs.first,
            label: event?.label,
            queuedAt: artifact.captureInterval?.startedAt ?? event?.timestamp ?? session.startedAt)
    }

    private static func fileExtension(mediaType: String, kind: String) -> String {
        switch mediaType {
        case "audio/mp4": return "m4a"
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        default: return kind == "narration_audio" ? "m4a" : "bin"
        }
    }
}
