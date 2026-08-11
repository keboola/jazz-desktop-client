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

public enum JazzArchiveProjectionReconciliationError: Error, Equatable, Sendable {
    case liveCompatibilityNotAuthorized(String)
}

/// Rebuilds mutable transport outboxes from canonical archive evidence. It is safe to run after
/// every launch and close: both sinks key writes by stable observation/artifact identity and reject
/// conflicting bytes instead of silently duplicating them.
public actor JazzArchiveProjectionReconciler {
    public static let deliveryPolicyExtension =
        "dev.jazz.desktop.deliveryPolicy"

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
            do {
                let manifest = try await store.manifest(archiveId: id)
                guard try await isLiveCompatibilityAuthorized(manifest) else {
                    continue
                }
                results.append(
                    .success(
                        try await reconcile(
                            archiveId: id,
                            authorizedManifest: manifest)))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }

    @discardableResult
    public func reconcile(archiveId: String) async throws
        -> JazzArchiveProjectionReconciliation
    {
        let manifest = try await store.manifest(archiveId: archiveId)
        guard try await isLiveCompatibilityAuthorized(manifest) else {
            throw JazzArchiveProjectionReconciliationError
                .liveCompatibilityNotAuthorized(archiveId)
        }
        return try await reconcile(
            archiveId: archiveId,
            authorizedManifest: manifest)
    }

    private func reconcile(
        archiveId: String,
        authorizedManifest manifest: JazzArchiveManifest
    ) async throws -> JazzArchiveProjectionReconciliation {
        var observationCount = 0
        var artifactCount = 0
        for sessionRef in manifest.sessions {
            let session = try await store.session(
                archiveId: archiveId, captureId: sessionRef.captureId)
            let records = try await store.allRecords(
                archiveId: archiveId, captureId: session.captureId)
            let activitySessionId = records.lazy.compactMap { record -> String? in
                guard let activity = try? record.activityRecord() else { return nil }
                return activity.payload.sessionId
            }.first
            guard let legacySessionId = session.legacySessionId ?? activitySessionId else {
                continue
            }

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
            // Artifacts are first-class transport items. Project the complete canonical set before
            // observations so standalone artifacts are included and a shared artifact is installed
            // once under its own stable identity rather than inheriting a referring record's time.
            for artifact in artifacts {
                _ = try eventSpool.appendCanonicalArtifactProjection(
                    sessionId: legacySessionId,
                    binding: binding,
                    artifact: artifact)
            }
            for record in records {
                let associatedArtifacts = record.artifactRefs.compactMap {
                    artifactsById[$0.artifactId]
                }
                if record.recordType == ArchiveRecord<ActivityEvent>.activityRecordType {
                    _ = try eventSpool.appendCanonicalProjection(
                        sessionId: legacySessionId,
                        binding: binding,
                        record: record,
                        artifacts: associatedArtifacts,
                        event: try record.activityRecord().payload)
                } else {
                    _ = try eventSpool.appendCanonicalProjection(
                        sessionId: legacySessionId,
                        binding: binding,
                        record: record,
                        artifacts: associatedArtifacts)
                }
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
                guard
                    record.recordType == ArchiveRecord<ActivityEvent>.activityRecordType,
                    let event = try? record.activityRecord().payload
                else { continue }
                for ref in record.artifactRefs where eventByArtifact[ref.artifactId] == nil {
                    eventByArtifact[ref.artifactId] = event
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

    private func isLiveCompatibilityAuthorized(
        _ manifest: JazzArchiveManifest
    ) async throws -> Bool {
        if case .string(let policy)? =
            manifest.extensions?[Self.deliveryPolicyExtension],
            policy == JazzCaptureDeliveryPolicy.liveCompatibility.rawValue
        {
            return true
        }
        // Migration safety for captures created by an older client: an already-pinned spool
        // session proves that this exact capture previously opted into liveCompatibility.
        // A current global preference is deliberately not authority to export an older draft.
        for sessionRef in manifest.sessions {
            let session = try await store.session(
                archiveId: manifest.archiveId,
                captureId: sessionRef.captureId)
            guard let legacySessionId = session.legacySessionId,
                let meta = eventSpool.sessionMeta(sessionId: legacySessionId),
                meta.liveCanonicalBinding?.archiveId == manifest.archiveId,
                meta.liveCanonicalBinding?.captureId == session.captureId
            else { continue }
            return true
        }
        return false
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
            "jazz", "session:\(legacySessionId)", "jazz-artifact",
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
