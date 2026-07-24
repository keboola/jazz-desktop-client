import Foundation

public struct CaptureJournalActivityContext: Equatable, Sendable {
    public let originId: String
    public let captureId: String
    public let streamId: String
    public let sourceId: String
    public let actorId: String
    public let policyVersion: String

    public init(
        originId: String,
        captureId: String,
        streamId: String,
        sourceId: String,
        actorId: String,
        policyVersion: String
    ) {
        self.originId = originId
        self.captureId = captureId
        self.streamId = streamId
        self.sourceId = sourceId
        self.actorId = actorId
        self.policyVersion = policyVersion
    }
}

public enum CaptureJournalArtifactPayload: Equatable, Sendable {
    /// Convenience path for already-small artifacts such as a compressed screenshot.
    case bytes(Data)
    /// Required path for potentially long audio/video. Only a sealed journal-owned claim is
    /// accepted; an arbitrary mutable file URL cannot enter the canonical archive.
    case claimedFile(JazzArchiveClaimedFile)

    func discardClaimIfPresent() {
        if case .claimedFile(let claim) = self { claim.discard() }
    }
}

public struct CaptureJournalArtifactInput: Equatable, Sendable {
    public var artifactId: String
    public var payload: CaptureJournalArtifactPayload
    public var kind: String
    public var mediaType: String
    public var role: String
    /// Semantics of the capture source and human in this artifact are explicit. Artifact kind is
    /// not used to guess identity (for example narration is authored by a narrator, while the
    /// enclosing UI action is still performed by a performer).
    public var sourceRole: String
    public var actorRole: String
    public var captureInterval: JazzArchiveArtifactCaptureInterval?
    public var quality: JazzArchiveQuality
    public var privacy: JazzArchivePrivacy
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        artifactId: String = Identifiers.newArtifactId(),
        bytes: Data,
        kind: String,
        mediaType: String,
        role: String,
        sourceRole: String,
        actorRole: String,
        captureInterval: JazzArchiveArtifactCaptureInterval? = nil,
        quality: JazzArchiveQuality = JazzArchiveQuality(status: .complete),
        privacy: JazzArchivePrivacy,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.artifactId = artifactId
        self.payload = .bytes(bytes)
        self.kind = kind
        self.mediaType = mediaType
        self.role = role
        self.sourceRole = sourceRole
        self.actorRole = actorRole
        self.captureInterval = captureInterval
        self.quality = quality
        self.privacy = privacy
        self.extensions = extensions
    }

    public init(
        artifactId: String,
        claimedFile: JazzArchiveClaimedFile,
        kind: String,
        mediaType: String,
        role: String,
        sourceRole: String,
        actorRole: String,
        captureInterval: JazzArchiveArtifactCaptureInterval? = nil,
        quality: JazzArchiveQuality = JazzArchiveQuality(status: .complete),
        privacy: JazzArchivePrivacy,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.artifactId = artifactId
        self.payload = .claimedFile(claimedFile)
        self.kind = kind
        self.mediaType = mediaType
        self.role = role
        self.sourceRole = sourceRole
        self.actorRole = actorRole
        self.captureInterval = captureInterval
        self.quality = quality
        self.privacy = privacy
        self.extensions = extensions
    }
}

public struct CaptureJournalActivityObservation: Equatable, Sendable {
    public var event: ActivityEvent
    public var artifact: CaptureJournalArtifactInput?
    public var interactionContext: JazzArchiveInteractionContext?
    public var quality: JazzArchiveQuality
    /// Archive-only metadata that must remain attached to the canonical observation without
    /// widening the live ActivityEvent / OTLP contract. Label declaration mode and deterministic
    /// process-binding resolution are recorded here and later materialized into `labels.ndjson`.
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        event: ActivityEvent,
        artifact: CaptureJournalArtifactInput? = nil,
        interactionContext: JazzArchiveInteractionContext? = nil,
        quality: JazzArchiveQuality = JazzArchiveQuality(status: .complete),
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.event = event
        self.artifact = artifact
        self.interactionContext = interactionContext
        self.quality = quality
        self.extensions = extensions
    }
}

public enum CaptureJournalActivityOutcome: Equatable, Sendable {
    case observation(CaptureJournalActivityObservation)
    case gap(reason: JazzArchiveGapReason, detail: String?)
}

public enum CaptureJournalActivityResolution: Equatable, Sendable {
    case persisted(observationId: String, artifactId: String?)
    case failed(reason: JazzArchiveGapReason, detail: String?)
}

public enum CaptureJournalRuntimeError: Error, Equatable, CustomStringConvertible {
    case closed

    public var description: String { "Capture journal runtime no longer accepts producer work" }
}

/// Production-facing lifecycle around ``CaptureJournal``. Each producer is durably reserved before
/// its asynchronous work starts. Closing rejects new producers, waits only for admitted local work,
/// commits the archive, and treats OTLP compatibility writes as downstream projections.
public actor CaptureJournalRuntime {
    public typealias Producer =
        @Sendable (CaptureJournalReservationToken) async
        -> CaptureJournalActivityOutcome
    public typealias Projection = @Sendable (String, ActivityEvent) async throws -> Void
    /// Runs only after the exact record is durably canonical. Failure is downstream and cannot
    /// roll capture back.
    public typealias CanonicalObservationProjection =
        @Sendable (JazzArchiveRecord, ActivityEvent) async throws -> Void
    public typealias ArtifactProjection =
        @Sendable (JazzArchiveArtifact, ActivityEvent) async throws
        -> Void
    public typealias ResolutionObserver = @Sendable (CaptureJournalActivityResolution) async -> Void

    private enum State: Equatable, Sendable {
        case accepting
        case closing
        case committed
    }

    private let journal: CaptureJournal
    private let context: CaptureJournalActivityContext
    private let projection: Projection?
    private let canonicalObservationProjection: CanonicalObservationProjection?
    private let artifactProjection: ArtifactProjection?
    private var state: State = .accepting
    private var work: [String: Task<Void, Never>] = [:]
    private var projectionErrors: [String] = []

    public init(
        journal: CaptureJournal,
        context: CaptureJournalActivityContext,
        projection: Projection? = nil,
        canonicalObservationProjection: CanonicalObservationProjection? = nil,
        artifactProjection: ArtifactProjection? = nil
    ) {
        self.journal = journal
        self.context = context
        self.projection = projection
        self.canonicalObservationProjection = canonicalObservationProjection
        self.artifactProjection = artifactProjection
    }

    /// Returns only after the reservation is durable. The producer itself then runs concurrently.
    @discardableResult
    public func submit(
        _ producer: @escaping Producer,
        onResolved: ResolutionObserver? = nil
    ) async throws -> String {
        guard state == .accepting else { throw CaptureJournalRuntimeError.closed }
        let token = try await journal.reserve(streamId: context.streamId)
        let workId = token.reservationId
        let journal = self.journal
        let context = self.context
        let projection = self.projection
        let canonicalObservationProjection = self.canonicalObservationProjection
        let artifactProjection = self.artifactProjection
        work[workId] = Task {
            let outcome = await producer(token)
            switch outcome {
            case .gap(let reason, let detail):
                try? await journal.resolveGap(token, reason: reason, detail: detail)
                await onResolved?(.failed(reason: reason, detail: detail))
            case .observation(let input):
                let observationId = Identifiers.newObservationId()
                var artifactRefs: [JazzArchiveArtifactRef] = []
                var persistedArtifact: JazzArchiveArtifact?
                if let inputArtifact = input.artifact {
                    do {
                        let artifactToken = try await journal.reserveArtifact(
                            artifactId: inputArtifact.artifactId)
                        let artifact = try await journal.ingestArtifact(
                            artifactToken,
                            payload: inputArtifact.payload,
                            kind: inputArtifact.kind,
                            mediaType: inputArtifact.mediaType,
                            sourceRefs: [
                                JazzArchiveSourceRef(
                                    sourceId: context.sourceId, role: inputArtifact.sourceRole)
                            ],
                            actorRefs: [
                                JazzArchiveActorRef(
                                    actorId: context.actorId,
                                    role: inputArtifact.actorRole,
                                    basis: .declared,
                                    method: "session_recorder")
                            ],
                            labelRefs: input.event.labelId.map { [$0] } ?? [],
                            observationRefs: [observationId],
                            captureInterval: inputArtifact.captureInterval,
                            provenance: JazzArchiveProvenance(
                                factClass: .observed, sources: [context.sourceId]),
                            quality: inputArtifact.quality,
                            privacy: inputArtifact.privacy,
                            extensions: inputArtifact.extensions)
                        artifactRefs = [
                            JazzArchiveArtifactRef(
                                artifactId: artifact.artifactId, role: inputArtifact.role)
                        ]
                        persistedArtifact = artifact
                    } catch {
                        inputArtifact.payload.discardClaimIfPresent()
                        try? await journal.resolveGap(
                            token,
                            reason: .captureLoss,
                            detail: "artifact persistence failed")
                        await onResolved?(
                            .failed(
                                reason: .captureLoss,
                                detail: "artifact persistence failed"))
                        return
                    }
                }
                let privacy = JazzArchivePrivacy(
                    status: input.event.inputMasked == true ? .masked : .captured,
                    policyVersion: context.policyVersion)
                let record = ArchiveRecord(
                    event: input.event,
                    observationId: observationId,
                    originId: context.originId,
                    captureId: context.captureId,
                    streamId: token.streamId,
                    streamSequence: token.streamSequence,
                    enrichedAt: Timestamps.iso8601(),
                    sourceRefs: [
                        JazzArchiveSourceRef(
                            sourceId: context.sourceId, role: "trigger")
                    ],
                    actorRefs: [
                        JazzArchiveActorRef(
                            actorId: context.actorId,
                            role: "performer",
                            basis: .declared,
                            method: "session_recorder")
                    ],
                    artifactRefs: artifactRefs,
                    interactionContext: input.interactionContext,
                    provenance: JazzArchiveProvenance(
                        factClass: .observed, sources: [context.sourceId]),
                    quality: input.quality,
                    privacy: privacy,
                    extensions: input.extensions)
                do {
                    try await journal.resolveObservation(token, record: record)
                } catch {
                    try? await journal.resolveGap(
                        token, reason: .captureLoss, detail: "observation persistence failed")
                    await onResolved?(
                        .failed(
                            reason: .captureLoss,
                            detail: "observation persistence failed"))
                    return
                }
                await onResolved?(
                    .persisted(
                        observationId: observationId,
                        artifactId: persistedArtifact?.artifactId))
                if let canonicalObservationProjection {
                    do {
                        try await canonicalObservationProjection(
                            JazzArchiveRecord(erasing: record), input.event)
                    } catch {
                        self.noteProjectionError(observationId)
                    }
                }
                if let projection {
                    do {
                        try await projection(observationId, input.event)
                    } catch {
                        self.noteProjectionError(observationId)
                    }
                }
                if let artifactProjection, let persistedArtifact {
                    do {
                        try await artifactProjection(persistedArtifact, input.event)
                    } catch {
                        self.noteProjectionError(persistedArtifact.artifactId)
                    }
                }
            }
        }
        return workId
    }

    /// `submit` calls must have returned before close starts, which means every producer already
    /// owns a durable sequence position. The runtime gate closes immediately; after admitted work
    /// has persisted any artifact bytes it advances the underlying journal through close/drain.
    /// Network delivery is deliberately outside this barrier.
    public func sealAdmissions() throws {
        switch state {
        case .accepting:
            state = .closing
        case .closing:
            return
        case .committed:
            throw CaptureJournalRuntimeError.closed
        }
    }

    @discardableResult
    public func close(endedAt: String) async throws -> JazzArchiveCaptureCommit {
        guard state != .committed else { throw CaptureJournalRuntimeError.closed }
        try sealAdmissions()
        let admitted = Array(work.values)
        for task in admitted { await task.value }
        let snapshot = await journal.snapshot()
        if snapshot.lifecycle == .recording {
            _ = try await journal.closeInput()
        }
        if (await journal.snapshot()).lifecycle == .closingInput {
            _ = try await journal.beginDraining()
        }
        let commit = try await journal.commit(endedAt: endedAt)
        state = .committed
        work.removeAll()
        return commit
    }

    public func pendingProducerCount() -> Int { work.values.filter { !$0.isCancelled }.count }

    public func waitForAdmittedWork() async {
        let admitted = Array(work.values)
        for task in admitted { await task.value }
    }

    public func recordedProjectionErrors() -> [String] { projectionErrors }

    private func noteProjectionError(_ observationId: String) {
        projectionErrors.append(observationId)
    }
}
