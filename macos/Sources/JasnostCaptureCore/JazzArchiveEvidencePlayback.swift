import Foundation

public struct JazzArchiveEvidencePlaybackArtifact: Equatable, Sendable {
    public let artifactId: String
    public let kind: String
    public let mediaType: String
    public let url: URL
    public let captureStartedAt: String?
    public let captureEndedAt: String?

    public init(artifact: JazzArchiveArtifact, url: URL) {
        self.artifactId = artifact.artifactId
        self.kind = artifact.kind
        self.mediaType = artifact.content.mediaType
        self.url = url
        self.captureStartedAt = artifact.captureInterval?.startedAt
        self.captureEndedAt = artifact.captureInterval?.endedAt
    }
}

/// One immutable, locally verified item in an evidence timeline. There is intentionally no target,
/// input payload, or execution callback: playback can explain an observed process but cannot replay
/// keyboard or pointer input into the operating system.
public struct JazzArchiveEvidencePlaybackEntry: Identifiable, Equatable, Sendable {
    public let item: EvidencePlaybackItem
    /// Inclusive start and optional exclusive end on the one global capture timeline.
    public let endOffsetMillis: Int64?
    public let occurredAt: String?
    public let title: String
    public let detail: String?
    public let artifact: JazzArchiveEvidencePlaybackArtifact?

    public var id: String { item.playbackId }
}

public struct JazzArchiveEvidencePlaybackSnapshot: Equatable, Sendable {
    public let archiveId: String
    public let captureId: String
    public let startedAt: String
    public let durationMillis: Int64
    public let entries: [JazzArchiveEvidencePlaybackEntry]
}

public enum JazzArchiveEvidencePlaybackError: Error, Equatable, CustomStringConvertible {
    case captureNotCommitted(String)
    case missingArtifact(String)
    case artifactIntegrity(String)
    case invalidInterval(String)
    case malformedTimestamp(String)

    public var description: String {
        switch self {
        case let .captureNotCommitted(id):
            return "Capture is not committed and cannot be replayed safely: \(id)"
        case let .missingArtifact(id):
            return "Evidence references a missing local artifact: \(id)"
        case let .artifactIntegrity(id):
            return "Evidence artifact failed digest verification: \(id)"
        case let .invalidInterval(id):
            return "Evidence has an invalid timeline interval: \(id)"
        case let .malformedTimestamp(value):
            return "Evidence has an invalid timestamp: \(value)"
        }
    }
}

/// Builds a timeline exclusively from canonical local archive state. `artifactFile` fingerprints
/// every referenced blob before its URL reaches the UI; any missing or corrupt byte fails the
/// complete load instead of presenting a deceptively partial replay.
public actor JazzArchiveEvidencePlaybackBuilder {
    private let draftStore: JazzArchiveDraftStore
    private let finalizedStore: JazzArchiveFinalizedStore

    public init(root: URL, fileManager: FileManager = .default) {
        self.draftStore = JazzArchiveDraftStore(root: root, fileManager: fileManager)
        self.finalizedStore = JazzArchiveFinalizedStore(root: root, fileManager: fileManager)
    }

    public func build(
        archiveId: String,
        captureId: String
    ) async throws -> JazzArchiveEvidencePlaybackSnapshot {
        let manifest: JazzArchiveManifest
        let session: JazzArchiveSession
        let commit: JazzArchiveCaptureCommit
        let records: [JazzArchiveRecord]
        let labels: [JazzArchiveLabel]
        let artifacts: [JazzArchiveArtifact]
        let finalized = await finalizedStore.contains(archiveId: archiveId)
        if finalized {
            let snapshot = try await finalizedStore.snapshot(archiveId: archiveId)
            manifest = snapshot.manifest
            session = try snapshot.session(captureId: captureId)
            commit = try snapshot.captureCommit(captureId: captureId)
            records = try snapshot.records(captureId: captureId)
            labels = try snapshot.labels(captureId: captureId)
            artifacts = try snapshot.artifacts(captureId: captureId)
        } else {
            manifest = try await draftStore.manifest(archiveId: archiveId)
            session = try await draftStore.session(
                archiveId: archiveId, captureId: captureId)
            commit = try await draftStore.captureCommit(
                archiveId: archiveId, captureId: captureId)
            records = try await draftStore.allRecords(
                archiveId: archiveId, captureId: captureId)
            // Draft label declarations still exist as canonical boundary observations. The
            // finalized portable snapshot materializes those boundaries into labels.ndjson.
            labels = []
            artifacts = try await draftStore.artifacts(
                archiveId: archiveId, captureId: captureId)
        }
        guard session.captureCommit != nil else {
            throw JazzArchiveEvidencePlaybackError.captureNotCommitted(captureId)
        }
        let startedAt = try parsed(session.startedAt)

        var verified: [String: JazzArchiveEvidencePlaybackArtifact] = [:]
        var artifactIntervals: [String: PlaybackInterval] = [:]
        for artifact in artifacts {
            let file = if finalized {
                try await finalizedStore.artifactFile(
                    archiveId: archiveId,
                    captureId: captureId,
                    artifactId: artifact.artifactId)
            } else {
                try await draftStore.artifactFile(
                    archiveId: archiveId,
                    captureId: captureId,
                    artifactId: artifact.artifactId)
            }
            let fingerprint = try JazzArchiveFileIO.fingerprint(file.url)
            guard fingerprint == JazzArchiveFileFingerprint(
                sha256: artifact.content.sha256,
                byteLength: artifact.content.byteLength)
            else {
                throw JazzArchiveEvidencePlaybackError.artifactIntegrity(
                    artifact.artifactId)
            }
            verified[artifact.artifactId] = JazzArchiveEvidencePlaybackArtifact(
                artifact: artifact, url: file.url)
            if let interval = artifact.captureInterval {
                let start = try offsetMillis(interval.startedAt, relativeTo: startedAt)
                let end = try interval.endedAt.map {
                    try offsetMillis($0, relativeTo: startedAt)
                }
                guard end == nil || end! >= start else {
                    throw JazzArchiveEvidencePlaybackError.invalidInterval(
                        artifact.artifactId)
                }
                artifactIntervals[artifact.artifactId] = PlaybackInterval(
                    start: start, end: end)
            }
        }

        var entries: [JazzArchiveEvidencePlaybackEntry] = []
        var referencedArtifacts = Set<String>()
        var offsetsByStream: [String: [(sequence: Int, offset: Int64)]] = [:]
        var offsetsByObservation: [String: Int64] = [:]
        var timestampsByObservation: [String: String] = [:]
        let canonicalLabelIds = Set(labels.map(\.labelId))
        var observedLabelStarts: [String: ObservedLabelBoundary] = [:]
        var observedLabelEnds: [String: ObservedLabelBoundary] = [:]
        for record in records {
            guard let activity = try? record.activityRecord().payload,
                let labelId = activity.labelId,
                activity.eventType == EventType.labelStart.rawValue
                    || activity.eventType == EventType.labelEnd.rawValue
            else { continue }
            let boundary = ObservedLabelBoundary(
                observationId: record.observationId,
                title: activity.label ?? activity.value ?? "Process label",
                detail: activity.process)
            if activity.eventType == EventType.labelStart.rawValue {
                guard observedLabelStarts.updateValue(boundary, forKey: labelId) == nil else {
                    throw JazzArchiveEvidencePlaybackError.invalidInterval(labelId)
                }
            } else {
                guard observedLabelEnds.updateValue(boundary, forKey: labelId) == nil else {
                    throw JazzArchiveEvidencePlaybackError.invalidInterval(labelId)
                }
            }
        }
        guard Set(observedLabelEnds.keys).isSubset(of: Set(observedLabelStarts.keys)) else {
            throw JazzArchiveEvidencePlaybackError.invalidInterval(
                Set(observedLabelEnds.keys)
                    .subtracting(observedLabelStarts.keys)
                    .sorted().first!)
        }
        let renderedLabelIds = canonicalLabelIds.union(Set(observedLabelStarts.keys))
        for record in records {
            let timestamp = record.occurredAt ?? record.capturedAt
            let offset = try offsetMillis(timestamp, relativeTo: startedAt)
            offsetsByStream[record.streamId, default: []].append(
                (record.streamSequence, offset))
            offsetsByObservation[record.observationId] = offset
            timestampsByObservation[record.observationId] = timestamp
            let recordEntries = try playbackEntries(
                record,
                offsetMillis: offset,
                verifiedArtifacts: verified,
                renderedLabelIds: renderedLabelIds,
                referencedArtifacts: &referencedArtifacts)
            entries.append(contentsOf: recordEntries)
        }

        // A finalized label is one interval on the same global playhead. Boundary observations
        // remain its evidence anchors, but are not rendered as duplicate start/end rows.
        for label in labels {
            guard let start = offsetsByObservation[label.interval.startObservationId] else {
                throw JazzArchiveEvidencePlaybackError.invalidInterval(label.labelId)
            }
            let end: Int64?
            if let endObservationId = label.interval.endObservationId {
                guard let resolved = offsetsByObservation[endObservationId],
                    resolved >= start
                else {
                    throw JazzArchiveEvidencePlaybackError.invalidInterval(label.labelId)
                }
                end = resolved
            } else {
                end = nil
            }
            entries.append(JazzArchiveEvidencePlaybackEntry(
                item: EvidencePlaybackItem(
                    playbackId: "label:\(label.labelId)",
                    offsetMillis: start,
                    kind: .label,
                    evidenceRef: "label:\(label.labelId)",
                    gapReason: nil,
                    label: label.declaration.text),
                endOffsetMillis: end,
                occurredAt: timestampsByObservation[label.interval.startObservationId]
                    ?? label.declaration.declaredAt,
                title: label.declaration.text,
                detail: label.processBinding?.nameSnapshot,
                artifact: nil))
        }
        for labelId in observedLabelStarts.keys.sorted()
            where !canonicalLabelIds.contains(labelId)
        {
            let boundary = observedLabelStarts[labelId]!
            guard let start = offsetsByObservation[boundary.observationId] else {
                throw JazzArchiveEvidencePlaybackError.invalidInterval(labelId)
            }
            let end: Int64?
            if let endBoundary = observedLabelEnds[labelId] {
                guard let resolved = offsetsByObservation[endBoundary.observationId],
                    resolved >= start
                else {
                    throw JazzArchiveEvidencePlaybackError.invalidInterval(labelId)
                }
                end = resolved
            } else {
                end = nil
            }
            entries.append(JazzArchiveEvidencePlaybackEntry(
                item: EvidencePlaybackItem(
                    playbackId: "label:\(labelId)",
                    offsetMillis: start,
                    kind: .label,
                    evidenceRef: "label:\(labelId)",
                    gapReason: nil,
                    label: boundary.title),
                endOffsetMillis: end,
                occurredAt: timestampsByObservation[boundary.observationId],
                title: boundary.title,
                detail: boundary.detail,
                artifact: nil))
        }

        // Preserve independently captured artifacts even when a producer did not attach them to a
        // record. Their own capture interval remains evidence; it is not inferred from a neighbour.
        for artifact in artifacts where artifactIntervals[artifact.artifactId]?.end != nil
            || !referencedArtifacts.contains(artifact.artifactId)
        {
            guard let file = verified[artifact.artifactId] else {
                throw JazzArchiveEvidencePlaybackError.missingArtifact(artifact.artifactId)
            }
            let timestamp = artifact.captureInterval?.startedAt
            let interval = artifactIntervals[artifact.artifactId]
            let offset: Int64
            if let interval {
                offset = interval.start
            } else if let timestamp {
                offset = try offsetMillis(timestamp, relativeTo: startedAt)
            } else {
                offset = 0
            }
            entries.append(JazzArchiveEvidencePlaybackEntry(
                item: EvidencePlaybackItem(
                    playbackId: "artifact:\(artifact.artifactId)",
                    offsetMillis: offset,
                    kind: playbackKind(artifact),
                    evidenceRef: "artifact:\(artifact.artifactId)",
                    gapReason: nil,
                    label: artifact.kind),
                endOffsetMillis: interval?.end,
                occurredAt: timestamp,
                title: artifactTitle(artifact),
                detail: artifact.content.mediaType,
                artifact: file))
        }

        for gap in commit.gaps {
            let offset = gapOffset(gap, positions: offsetsByStream[gap.streamId] ?? [])
            let reason = gap.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = reason?.isEmpty == false ? reason! : gap.reason.rawValue
            entries.append(JazzArchiveEvidencePlaybackEntry(
                item: EvidencePlaybackItem(
                    playbackId: "gap:\(gap.streamId):\(gap.firstSequence)-\(gap.lastSequence)",
                    offsetMillis: offset,
                    kind: .gap,
                    evidenceRef: nil,
                    gapReason: detail,
                    label: "Evidence gap"),
                endOffsetMillis: nil,
                occurredAt: nil,
                title: "Evidence gap",
                detail: "\(detail) · sequence \(gap.firstSequence)–\(gap.lastSequence)",
                artifact: nil))
        }

        entries.sort {
            ($0.item.offsetMillis, $0.item.playbackId)
                < ($1.item.offsetMillis, $1.item.playbackId)
        }
        try EvidencePlaybackValidator.validate(entries.map(\.item))
        var durationMillis = entries.reduce(Int64(0)) {
            max($0, $1.endOffsetMillis ?? $1.item.offsetMillis)
        }
        if let endedAt = session.endedAt {
            durationMillis = max(
                durationMillis,
                try offsetMillis(endedAt, relativeTo: startedAt))
        }
        _ = manifest  // the strict store read already verifies manifest/inventory linkage
        return JazzArchiveEvidencePlaybackSnapshot(
            archiveId: archiveId,
            captureId: captureId,
            startedAt: session.startedAt,
            durationMillis: durationMillis,
            entries: entries)
    }

    private struct PlaybackInterval {
        let start: Int64
        let end: Int64?
    }

    private struct ObservedLabelBoundary {
        let observationId: String
        let title: String
        let detail: String?
    }

    private func playbackEntries(
        _ record: JazzArchiveRecord,
        offsetMillis: Int64,
        verifiedArtifacts: [String: JazzArchiveEvidencePlaybackArtifact],
        renderedLabelIds: Set<String>,
        referencedArtifacts: inout Set<String>
    ) throws -> [JazzArchiveEvidencePlaybackEntry] {
        var recordKind: EvidencePlaybackKind = .event
        var title = record.recordType
        var detail: String?

        if let activity = try? record.activityRecord().payload {
            switch activity.eventType {
            case EventType.annotation.rawValue, EventType.labelStart.rawValue,
                EventType.labelEnd.rawValue:
                if let labelId = activity.labelId, renderedLabelIds.contains(labelId) {
                    return []
                }
                recordKind = .label
                title = activity.label ?? activity.value ?? "Process label"
            case EventType.narration.rawValue:
                recordKind = .narration
                title = activity.label.map { "Narration · \($0)" } ?? "Narration"
            default:
                title = activityTitle(activity)
            }
            detail = activityDetail(activity)
        } else if let coach = try? record.coachInteractionRecord().payload {
            recordKind = .coachInteraction
            title = "Capture Coach · \(coach.interactionType.rawValue)"
            detail = coach.promptSnapshot?.text ?? coach.answer?.text
        } else if let media = try? record.mediaObservationRecord().payload {
            switch media.mediaKind {
            case .transcript:
                recordKind = .transcript
                title = "Transcript"
                detail = media.transcript?.text
            case .meetingAudio:
                recordKind = .narration
                title = "Meeting audio"
            case .screenShareVideo:
                recordKind = .screenshot
                title = "Screen-share video"
            }
        }

        if record.artifactRefs.isEmpty {
            return [JazzArchiveEvidencePlaybackEntry(
                item: EvidencePlaybackItem(
                    playbackId: "observation:\(record.observationId)",
                    offsetMillis: offsetMillis,
                    kind: recordKind,
                    evidenceRef: "observation:\(record.observationId)",
                    gapReason: nil,
                    label: title),
                endOffsetMillis: nil,
                occurredAt: record.occurredAt ?? record.capturedAt,
                title: title,
                detail: detail,
                artifact: nil)]
        }

        return try record.artifactRefs.enumerated().map { index, ref in
            guard let artifact = verifiedArtifacts[ref.artifactId] else {
                throw JazzArchiveEvidencePlaybackError.missingArtifact(ref.artifactId)
            }
            referencedArtifacts.insert(ref.artifactId)
            let kind = recordKind == .event ? playbackKind(artifact: artifact) : recordKind
            return JazzArchiveEvidencePlaybackEntry(
                item: EvidencePlaybackItem(
                    playbackId: "observation:\(record.observationId):artifact:\(index)",
                    offsetMillis: offsetMillis,
                    kind: kind,
                    evidenceRef: "artifact:\(ref.artifactId)",
                    gapReason: nil,
                    label: title),
                endOffsetMillis: nil,
                occurredAt: record.occurredAt ?? record.capturedAt,
                title: title,
                detail: detail ?? artifact.mediaType,
                artifact: artifact)
        }
    }

    private func activityTitle(_ event: ActivityEvent) -> String {
        let target = event.target?.accessibleName ?? event.target?.text
        let action = event.eventType.replacingOccurrences(of: "_", with: " ")
        return target.map { "\(action.capitalized) · \($0)" } ?? action.capitalized
    }

    private func activityDetail(_ event: ActivityEvent) -> String? {
        if event.inputMasked == true || event.isSensitive == true { return "Sensitive input masked" }
        let values = [
            event.application?.name,
            event.pageTitle,
            event.documentURL,
            event.value,
            event.selectedText,
            event.clipboardText,
        ].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func artifactTitle(_ artifact: JazzArchiveArtifact) -> String {
        switch playbackKind(artifact) {
        case .screenshot: return "Visual evidence"
        case .narration: return "Audio or video evidence"
        case .transcript: return "Transcript"
        default: return artifact.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func playbackKind(_ artifact: JazzArchiveArtifact) -> EvidencePlaybackKind {
        playbackKind(artifact: JazzArchiveEvidencePlaybackArtifact(
            artifact: artifact, url: URL(fileURLWithPath: "/")))
    }

    private func playbackKind(
        artifact: JazzArchiveEvidencePlaybackArtifact
    ) -> EvidencePlaybackKind {
        if artifact.mediaType.hasPrefix("image/") || artifact.kind == "screenshot"
            || artifact.kind == JazzMediaKind.screenShareVideo.rawValue
        {
            return .screenshot
        }
        if artifact.mediaType.hasPrefix("audio/") || artifact.mediaType.hasPrefix("video/") {
            return .narration
        }
        if artifact.kind.contains("transcript") || artifact.mediaType.contains("text") {
            return .transcript
        }
        return .event
    }

    private func parsed(_ value: String) throws -> Date {
        guard let date = Timestamps.parse(value) else {
            throw JazzArchiveEvidencePlaybackError.malformedTimestamp(value)
        }
        return date
    }

    private func offsetMillis(_ value: String, relativeTo start: Date) throws -> Int64 {
        let seconds = try parsed(value).timeIntervalSince(start)
        return max(0, Int64((seconds * 1_000).rounded()))
    }

    private func gapOffset(
        _ gap: JazzArchiveSequenceGap,
        positions: [(sequence: Int, offset: Int64)]
    ) -> Int64 {
        let sorted = positions.sorted { $0.sequence < $1.sequence }
        let before = sorted.last { $0.sequence < gap.firstSequence }?.offset
        let after = sorted.first { $0.sequence > gap.lastSequence }?.offset
        switch (before, after) {
        case let (.some(left), .some(right)): return left + max(1, (right - left) / 2)
        case let (.some(left), .none): return left + 1
        case let (.none, .some(right)): return max(0, right - 1)
        case (.none, .none): return 0
        }
    }
}
