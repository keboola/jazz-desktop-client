import Foundation

public struct JazzArchiveSessionSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let legacySessionId: String
    public let archiveId: String
    public let captureId: String
    public let revision: Int
    public let supersedesArchiveId: String?
    public let startedAt: String
    public let endedAt: String?
    public let kind: String?
    public let user: String?
    public let eventCount: Int
    public let artifactCount: Int
    public let sentCount: Int
    public let pendingCount: Int
    public let hasLiveCompatibilityProjection: Bool
    public let labels: [String]
    public let isCommitted: Bool
    public let isFinalized: Bool
    /// Final-only imports are deliberately read-only. A corrected revision can only be forked
    /// while the locally owned working draft is still present.
    public let hasWorkingDraft: Bool
    public let reviewDecision: JazzArchiveAssertionDecision?
    public let reviewReason: String?
    /// Nil only when matching canonical Coach records could not be decoded into the local,
    /// advisory checklist. An archive session must remain reviewable even in that case.
    public let coachReviewSummary: CaptureCoachReviewSummary?

    public var startedDate: Date? { Timestamps.parse(startedAt) }

    public var startedDisplay: String {
        guard let date = startedDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }

    public var durationDisplay: String {
        guard let start = Timestamps.parse(startedAt), let end = Timestamps.parse(endedAt) else {
            return ""
        }
        return Self.formatDuration(end.timeIntervalSince(start))
    }

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

/// Archive-primary read model for the native review UI. EventSpool contributes delivery counters
/// only; a missing or failed projection can never make a canonical capture disappear.
public actor JazzArchiveLocalIndex {
    private let store: JazzArchiveDraftStore
    private let finalizedStore: JazzArchiveFinalizedStore
    private let reviewStore: JazzArchiveReviewStore
    private let eventSpool: EventSpool

    public init(
        root: URL,
        eventSpool: EventSpool,
        fileManager: FileManager = .default
    ) {
        self.store = JazzArchiveDraftStore(root: root, fileManager: fileManager)
        self.finalizedStore = JazzArchiveFinalizedStore(
            root: root, fileManager: fileManager)
        self.reviewStore = JazzArchiveReviewStore(root: root, fileManager: fileManager)
        self.eventSpool = eventSpool
    }

    public func sessions() async -> [JazzArchiveSessionSummary] {
        let deliveryBySession = Dictionary(
            uniqueKeysWithValues: eventSpool.sessions().map { ($0.id, $0) })
        let draftIds = Set(await store.draftArchiveIds())
        let finalizedIds = Set(await finalizedStore.archiveIds())
        var result: [JazzArchiveSessionSummary] = []

        for archiveId in draftIds.union(finalizedIds).sorted() {
            if finalizedIds.contains(archiveId),
                let snapshot = try? await finalizedStore.snapshot(archiveId: archiveId)
            {
                let latestReview = try? JazzArchiveReviewStore.archiveHead(
                    in: snapshot.assertions, archiveId: archiveId)
                for session in snapshot.sessions {
                    guard let allRecords = snapshot.recordsByCapture[session.captureId],
                        let artifacts = snapshot.artifactsByCapture[session.captureId],
                        let archiveLabels = snapshot.labelsByCapture[session.captureId]
                    else { continue }
                    result.append(makeSummary(
                        manifest: snapshot.manifest,
                        session: session,
                        allRecords: allRecords,
                        artifacts: artifacts,
                        archiveLabels: archiveLabels,
                        latestReview: latestReview,
                        isFinalized: true,
                        hasWorkingDraft: draftIds.contains(archiveId),
                        deliveryBySession: deliveryBySession))
                }
                continue
            }

            guard draftIds.contains(archiveId),
                let manifest = try? await store.manifest(archiveId: archiveId)
            else { continue }
            let latestReview = try? await reviewStore.latestArchiveAssertion(archiveId: archiveId)
            for ref in manifest.sessions {
                guard let session = try? await store.session(
                    archiveId: archiveId, captureId: ref.captureId),
                    let allRecords = try? await store.allRecords(
                        archiveId: archiveId, captureId: ref.captureId),
                    let artifacts = try? await store.artifacts(
                        archiveId: archiveId, captureId: ref.captureId)
                else { continue }
                result.append(makeSummary(
                    manifest: manifest,
                    session: session,
                    allRecords: allRecords,
                    artifacts: artifacts,
                    archiveLabels: [],
                    latestReview: latestReview,
                    isFinalized: false,
                    hasWorkingDraft: true,
                    deliveryBySession: deliveryBySession))
            }
        }
        return result.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return ($0.archiveId, $0.captureId) < ($1.archiveId, $1.captureId)
        }
    }

    public func events(archiveId: String, captureId: String) async -> [ActivityEvent] {
        if await finalizedStore.contains(archiveId: archiveId),
            let snapshot = try? await finalizedStore.snapshot(archiveId: archiveId),
            let records = snapshot.recordsByCapture[captureId]
        {
            return records.compactMap { try? $0.activityRecord().payload }
        }
        return (try? await store.records(
            archiveId: archiveId, captureId: captureId).map(\.payload)) ?? []
    }

    private func makeSummary(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession,
        allRecords: [JazzArchiveRecord],
        artifacts: [JazzArchiveArtifact],
        archiveLabels: [JazzArchiveLabel],
        latestReview: JazzArchiveAssertion?,
        isFinalized: Bool,
        hasWorkingDraft: Bool,
        deliveryBySession: [String: EventSpool.SessionSummary]
    ) -> JazzArchiveSessionSummary {
        let activityEvents = allRecords.compactMap {
            try? $0.activityRecord().payload
        }
        let legacyId = session.legacySessionId ?? activityEvents.first?.sessionId
            ?? session.captureId
        // Legacy delivery counters are keyed only by the old session id. Applying them to a
        // cross-user import could accidentally merge unrelated devices, so final-only imports
        // never consult this projection.
        let delivery = hasWorkingDraft ? deliveryBySession[legacyId] : nil
        var seenLabels = Set<String>()
        var labels: [String] = []
        for label in archiveLabels {
            let text = label.declaration.text
            if seenLabels.insert(text).inserted {
                labels.append(text)
            }
        }
        for event in activityEvents {
            let label = event.eventType == EventType.annotation.rawValue
                ? event.value : event.label
            if let label, !label.isEmpty, seenLabels.insert(label).inserted {
                labels.append(label)
            }
        }
        let actor = manifest.actors.first {
            $0.actorId == session.recorderActorId
        }
        let coachReviewSummary = try? CaptureCoachReviewSummary(
            canonicalRecords: allRecords,
            canonicalLabelRegistry: coachLabelRegistry(
                archiveLabels: archiveLabels,
                records: allRecords,
                manifest: manifest,
                session: session),
            humanActorIds: Set(
                manifest.actors.filter { $0.kind == .human }.map(\.actorId)))
        return JazzArchiveSessionSummary(
            id: "\(manifest.archiveId):\(session.captureId)",
            legacySessionId: legacyId,
            archiveId: manifest.archiveId,
            captureId: session.captureId,
            revision: manifest.revision,
            supersedesArchiveId: manifest.supersedesArchiveId,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            kind: session.sessionKind,
            user: actor?.externalIdentities?.first?.value ?? actor?.displayName,
            eventCount: allRecords.count,
            artifactCount: artifacts.count,
            sentCount: delivery?.sentCount ?? 0,
            pendingCount: delivery?.pendingCount ?? 0,
            hasLiveCompatibilityProjection:
                delivery?.hasLiveCompatibilityProjection ?? false,
            labels: labels,
            isCommitted: session.captureCommit != nil,
            isFinalized: isFinalized,
            hasWorkingDraft: hasWorkingDraft,
            reviewDecision: latestReview?.decision,
            reviewReason: latestReview?.reason,
            coachReviewSummary: coachReviewSummary)
    }

    /// Finalized archives carry first-class canonical labels. A committed working draft has not
    /// been compacted into `labels.ndjson` yet, so use the same canonical `label_start` evidence
    /// from which finalization deterministically materializes those documents.
    private func coachLabelRegistry(
        archiveLabels: [JazzArchiveLabel],
        records: [JazzArchiveRecord],
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws -> [CaptureCoachReviewCanonicalLabel] {
        if !archiveLabels.isEmpty {
            return archiveLabels.map {
                CaptureCoachReviewCanonicalLabel(
                    labelId: $0.labelId,
                    captureId: $0.captureId,
                    declarationText: $0.declaration.text,
                    processName: $0.processBinding?.nameSnapshot,
                    startStreamSequence:
                        $0.interval.startStreamSequence)
            }
        }

        var result: [CaptureCoachReviewCanonicalLabel] = []
        var seen = Set<String>()
        for record in records
        where record.recordType
            == ArchiveRecord<ActivityEvent>.activityRecordType
        {
            let typed = try record.activityRecord()
            guard typed.payload.eventType == EventType.labelStart.rawValue
            else { continue }
            try typed.validate(manifest: manifest, session: session)
            guard let labelId = typed.payload.labelId,
                record.labelRefs == [labelId],
                seen.insert(labelId).inserted
            else {
                throw CaptureCoachReviewSummaryError
                    .missingCanonicalLabel(
                        typed.payload.labelId ?? record.observationId)
            }
            let extensionText: String?
            if case let .string(value)? =
                record.extensions?[
                    "dev.jazz.label.declarationText"]
            {
                extensionText = value
            } else {
                extensionText = nil
            }
            guard let declarationText = (
                extensionText ?? typed.payload.label
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
                !declarationText.isEmpty
            else {
                throw CaptureCoachReviewSummaryError
                    .missingCanonicalLabel(labelId)
            }
            result.append(CaptureCoachReviewCanonicalLabel(
                labelId: labelId,
                captureId: record.captureId,
                declarationText: declarationText,
                processName: typed.payload.process,
                startStreamSequence: record.streamSequence))
        }
        return result
    }
}
