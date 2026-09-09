import Foundation

public struct CaptureJournalActivityContext: Codable, Equatable, Sendable {
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
    public var observationId: String?
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
        observationId: String? = nil,
        artifact: CaptureJournalArtifactInput? = nil,
        interactionContext: JazzArchiveInteractionContext? = nil,
        quality: JazzArchiveQuality = JazzArchiveQuality(status: .complete),
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.observationId = observationId
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
    case outstandingWorkLimit
    case recoveryRequired(CaptureJournalRecoveryReason)

    public var description: String {
        switch self {
        case .closed: return "Capture journal runtime no longer accepts producer work"
        case .outstandingWorkLimit: return "Capture journal outstanding work limit reached"
        case .recoveryRequired(let reason):
            return "Capture journal requires recovery: \(reason.rawValue)"
        }
    }
}

public enum CaptureJournalRecoveryReason: String, Equatable, Sendable {
    /// Cancellation/deadline does not prove a filesystem operation stopped or a commit failed.
    case deadlineExceededDurabilityUnknown
    case persistenceFailedDurabilityUnknown
}

public enum CaptureJournalCloseOutcome: Equatable, Sendable {
    case committed(JazzArchiveCaptureCommit)
    /// The journal retains its lease until quiescence/release or process exit. Never restart capture
    /// or treat this as a clean close, even if a late filesystem operation eventually succeeds.
    case recoveryRequired(CaptureJournalRecoveryReason)
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
    /// One atomic compatibility projection receives the exact already-persisted canonical
    /// observation and every associated artifact. It may fail/retry independently of capture.
    public typealias LiveCompatibilityProjection =
        @Sendable (JazzArchiveRecord, [JazzArchiveArtifact], ActivityEvent) async throws
        -> Void
    public typealias ResolutionObserver = @Sendable (CaptureJournalActivityResolution) async -> Void

    private enum State: Equatable, Sendable {
        case accepting
        case closing
        case committed
        case recoveryRequired
    }

    private let journal: CaptureJournal
    private let context: CaptureJournalActivityContext
    private let projection: Projection?
    private let canonicalObservationProjection: CanonicalObservationProjection?
    private let artifactProjection: ArtifactProjection?
    private let liveCompatibilityProjection: LiveCompatibilityProjection?
    private let orderedLiveCompatibilityProjection:
        CaptureJournalOrderedProjection?
    private var state: State = .accepting
    private var work: [String: Task<Void, Never>] = [:]
    private var canonicalWork = Set<String>()
    private var projectionErrors: [String] = []
    private let maximumOutstandingWork: Int
    private var admissionsInFlight = 0
    private var persistenceFailed = false
    private var closeTask: Task<Void, Never>?
    private var closeTimer: Task<Void, Never>?
    private var closeResult: CaptureJournalCloseOutcome?
    private var closeWaiters: [CheckedContinuation<CaptureJournalCloseOutcome, Never>] = []

    public init(
        journal: CaptureJournal,
        context: CaptureJournalActivityContext,
        projection: Projection? = nil,
        canonicalObservationProjection: CanonicalObservationProjection? = nil,
        artifactProjection: ArtifactProjection? = nil,
        liveCompatibilityProjection: LiveCompatibilityProjection? = nil,
        orderedLiveCompatibilityProjection:
            CaptureJournalOrderedProjection? = nil,
        maximumOutstandingWork: Int = 128
    ) {
        precondition(maximumOutstandingWork > 0)
        self.maximumOutstandingWork = maximumOutstandingWork
        self.journal = journal
        self.context = context
        self.projection = projection
        self.canonicalObservationProjection = canonicalObservationProjection
        self.artifactProjection = artifactProjection
        self.liveCompatibilityProjection = liveCompatibilityProjection
        self.orderedLiveCompatibilityProjection =
            orderedLiveCompatibilityProjection
    }

    /// Returns only after the reservation is durable. The producer itself then runs concurrently.
    @discardableResult
    public func submit(
        _ producer: @escaping Producer,
        onResolved: ResolutionObserver? = nil
    ) async throws -> String {
        guard state == .accepting else { throw CaptureJournalRuntimeError.closed }
        guard work.count + admissionsInFlight < maximumOutstandingWork else {
            throw CaptureJournalRuntimeError.outstandingWorkLimit
        }
        admissionsInFlight += 1
        defer { admissionsInFlight -= 1 }
        try await journal.beginProducerWork()
        let token: CaptureJournalReservationToken
        do { token = try await journal.reserve(streamId: context.streamId) } catch {
            await journal.endProducerWork()
            persistenceFailed = true
            throw error
        }
        guard state != .recoveryRequired else {
            await journal.endProducerWork()
            throw CaptureJournalRuntimeError.closed
        }
        let workId = token.reservationId
        let journal = self.journal
        let context = self.context
        let projection = self.projection
        let canonicalObservationProjection = self.canonicalObservationProjection
        let artifactProjection = self.artifactProjection
        let liveCompatibilityProjection = self.liveCompatibilityProjection
        let orderedLiveCompatibilityProjection =
            self.orderedLiveCompatibilityProjection
        canonicalWork.insert(workId)
        work[workId] = Task {
            defer {
                self.work.removeValue(forKey: workId)
                self.canonicalWork.remove(workId)
            }
            let outcome = await producer(token)
            // Charge known pending media before any journal/advisory await. Keep the charge even
            // on failure: the sole-source claim/outcome still belongs to local recovery.
            if case .observation(let input) = outcome, let artifact = input.artifact {
                switch artifact.payload {
                case .bytes(let data): journal.chunkBytes.add(Int64(data.count))
                case .claimedFile(let claim): journal.chunkBytes.add(claim.byteLength)
                }
            }
            await journal.endProducerWork()
            guard self.state != .recoveryRequired else {
                await onResolved?(
                    .failed(
                        reason: .captureLoss, detail: "writer revoked; media retained for recovery")
                )
                return
            }
            switch outcome {
            case .gap(let reason, let detail):
                do { try await journal.resolveGap(token, reason: reason, detail: detail) } catch {
                    self.persistenceFailed = true
                }
                self.canonicalWork.remove(workId)
                _ = await orderedLiveCompatibilityProjection?.resolveGap(
                    streamId: token.streamId,
                    streamSequence: token.streamSequence)
                await onResolved?(.failed(reason: reason, detail: detail))
            case .observation(let input):
                let observationId = input.observationId ?? Identifiers.newObservationId()
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
                    artifactRefs: input.artifact.map {
                        [JazzArchiveArtifactRef(artifactId: $0.artifactId, role: $0.role)]
                    } ?? [],
                    interactionContext: input.interactionContext,
                    provenance: JazzArchiveProvenance(
                        factClass: .observed, sources: [context.sourceId]),
                    quality: input.quality,
                    privacy: privacy,
                    extensions: input.extensions)
                var persistedArtifact: JazzArchiveArtifact?
                if let inputArtifact = input.artifact {
                    do {
                        let artifactToken = try await journal.reserveArtifact(
                            artifactId: inputArtifact.artifactId)
                        try await journal.stageObservation(token, record: record)
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
                        persistedArtifact = artifact
                    } catch {
                        self.persistenceFailed = true
                        // The observation/media WAL intent is unresolved, not a proven loss gap.
                        // Sealed and recording claims stay discoverable under .artifact-claims.
                        await onResolved?(
                            .failed(
                                reason: .captureLoss,
                                detail: "artifact persistence failed"))
                        return
                    }
                }
                do {
                    if input.artifact != nil {
                        try await journal.finishObservation(token)
                    } else {
                        try await journal.resolveObservation(token, record: record)
                    }
                } catch {
                    self.persistenceFailed = true
                    await onResolved?(
                        .failed(
                            reason: .captureLoss,
                            detail: "observation persistence failed"))
                    return
                }
                self.canonicalWork.remove(workId)
                await onResolved?(
                    .persisted(
                        observationId: observationId,
                        artifactId: persistedArtifact?.artifactId))
                if let orderedLiveCompatibilityProjection {
                    do {
                        let projected =
                            await orderedLiveCompatibilityProjection
                            .resolveObservation(
                                try JazzArchiveRecord(erasing: record),
                                artifacts: persistedArtifact.map { [$0] } ?? [],
                                event: input.event)
                        if !projected {
                            self.noteProjectionError(observationId)
                        }
                    } catch {
                        self.noteProjectionError(observationId)
                    }
                }
                if let canonicalObservationProjection {
                    do {
                        try await canonicalObservationProjection(
                            JazzArchiveRecord(erasing: record), input.event)
                    } catch {
                        self.noteProjectionError(observationId)
                    }
                }
                if orderedLiveCompatibilityProjection == nil,
                    let liveCompatibilityProjection
                {
                    do {
                        try await liveCompatibilityProjection(
                            JazzArchiveRecord(erasing: record),
                            persistedArtifact.map { [$0] } ?? [],
                            input.event)
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
        case .committed, .recoveryRequired:
            throw CaptureJournalRuntimeError.closed
        }
    }

    @discardableResult
    public func close(endedAt: String, timeout: Duration = .seconds(30)) async throws
        -> JazzArchiveCaptureCommit
    {
        switch await closeOutcome(endedAt: endedAt, timeout: timeout) {
        case .committed(let commit): return commit
        case .recoveryRequired(let reason):
            throw CaptureJournalRuntimeError.recoveryRequired(reason)
        }
    }

    /// An unstructured deadline is intentional: a task group would await a non-cooperative child
    /// on scope exit. We retain the writer and its lease, fence late producer results, and report
    /// unknown durability instead of claiming cancellation stopped a filesystem operation.
    public func closeOutcome(endedAt: String, timeout: Duration = .seconds(30)) async
        -> CaptureJournalCloseOutcome
    {
        if let closeResult { return closeResult }
        if closeTask == nil {
            state = .closing
            closeTask = Task { await self.performClose(endedAt: endedAt) }
            closeTimer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                self.completeClose(.recoveryRequired(.deadlineExceededDurabilityUnknown))
            }
        }
        return await withCheckedContinuation { closeWaiters.append($0) }
    }

    private func performClose(endedAt: String) async {
        while !canonicalWork.isEmpty || admissionsInFlight > 0 {
            guard state == .closing else { return }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
        guard state == .closing else { return }
        guard !persistenceFailed else {
            completeClose(.recoveryRequired(.persistenceFailedDurabilityUnknown))
            return
        }
        do {
            let snapshot = await journal.snapshot()
            if snapshot.lifecycle == .recording { _ = try await journal.closeInput() }
            if (await journal.snapshot()).lifecycle == .closingInput {
                _ = try await journal.beginDraining()
            }
            guard state == .closing else { return }
            let commit = try await journal.commit(endedAt: endedAt)
            completeClose(.committed(commit))
        } catch {
            completeClose(.recoveryRequired(.persistenceFailedDurabilityUnknown))
        }
    }

    /// Controller-wide close can expire before it reaches runtime.close (for example a blocked
    /// Coach admission tail). Reuse the same late-writer fence and retain the exclusive lease.
    public func requireRecovery() {
        completeClose(.recoveryRequired(.deadlineExceededDurabilityUnknown))
    }

    private func completeClose(_ result: CaptureJournalCloseOutcome) {
        guard closeResult == nil else { return }
        closeResult = result
        closeTimer?.cancel()
        closeTimer = nil
        closeTask?.cancel()
        closeTask = nil
        switch result {
        case .committed: state = .committed
        case .recoveryRequired:
            state = .recoveryRequired
            for task in work.values { task.cancel() }
            // Awaiting revoke here would make the deadline depend on a blocked journal actor.
            // Lease release is deliberately NOT tied to timeout or cancellation.
            Task { await journal.revoke() }
        }
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    public func pendingProducerCount() -> Int { work.count + admissionsInFlight }

    public func waitForAdmittedWork() async {
        let admitted = Array(work.values)
        for task in admitted { await task.value }
    }

    public func recordedProjectionErrors() -> [String] { projectionErrors }

    private func noteProjectionError(_ observationId: String) {
        if projectionErrors.count < maximumOutstandingWork {
            projectionErrors.append(observationId)
        }
    }
}
