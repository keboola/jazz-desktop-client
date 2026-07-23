import Foundation

/// Versioned prompt control data received from the server. It intentionally contains no transcript,
/// semantic score, or business inference; those remain server-owned assessment concerns.
public struct CaptureCoachPrompt: Codable, Equatable, Sendable {
    public var promptId: String
    public var labelId: String?
    public var assessmentRef: CaptureCoachAssessmentRef?
    public var localBaselineRef: CaptureCoachLocalBaselineRef?
    public var inputWatermark: CaptureCoachInputWatermark
    public var snapshot: CaptureCoachPromptSnapshot

    public init(
        promptId: String,
        labelId: String? = nil,
        assessmentRef: CaptureCoachAssessmentRef? = nil,
        localBaselineRef: CaptureCoachLocalBaselineRef? = nil,
        inputWatermark: CaptureCoachInputWatermark,
        snapshot: CaptureCoachPromptSnapshot
    ) {
        self.promptId = promptId
        self.labelId = labelId
        self.assessmentRef = assessmentRef
        self.localBaselineRef = localBaselineRef
        self.inputWatermark = inputWatermark
        self.snapshot = snapshot
    }

    public func validate(for captureId: String) throws {
        let probe = CaptureCoachInteraction(
            interactionType: .received,
            promptId: promptId,
            labelId: labelId,
            assessmentRef: assessmentRef,
            localBaselineRef: localBaselineRef,
            inputWatermark: inputWatermark,
            promptSnapshot: snapshot)
        do {
            try probe.validate()
        } catch {
            throw CaptureCoachCoordinatorError.invalidPrompt(String(describing: error))
        }
        guard inputWatermark.captureId == captureId else {
            throw CaptureCoachCoordinatorError.wrongCapture(
                expected: captureId, actual: inputWatermark.captureId)
        }
    }
}

/// Desktop delivery policy only. The values control interruption frequency; they do not decide
/// whether a business explanation is semantically complete.
public struct CaptureCoachPolicy: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var cooldownSeconds: TimeInterval
    public var defaultMuteSeconds: TimeInterval

    public init(
        schemaVersion: Int = CaptureCoachPolicy.currentSchemaVersion,
        cooldownSeconds: TimeInterval = 30,
        defaultMuteSeconds: TimeInterval = 300
    ) {
        self.schemaVersion = schemaVersion
        self.cooldownSeconds = cooldownSeconds
        self.defaultMuteSeconds = defaultMuteSeconds
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
            cooldownSeconds.isFinite, cooldownSeconds >= 0,
            defaultMuteSeconds.isFinite, defaultMuteSeconds > 0
        else { throw CaptureCoachCoordinatorError.invalidPolicy }
    }
}

public protocol CaptureCoachInteractionRecorder: Sendable {
    func append(_ interaction: CaptureCoachInteraction) async throws
}

/// Envelope context owned by the local capture. The writer reserves a stream position first, then
/// hands the typed coach record to CaptureJournal's crash-recoverable append path.
public struct CaptureCoachRecordContext: Equatable, Sendable {
    public var originId: String
    public var captureId: String
    public var streamId: String
    public var sourceRefs: [JazzArchiveSourceRef]
    public var actorRefs: [JazzArchiveActorRef]
    public var provenance: JazzArchiveProvenance
    public var quality: JazzArchiveQuality
    public var privacy: JazzArchivePrivacy

    public init(
        originId: String,
        captureId: String,
        streamId: String,
        sourceRefs: [JazzArchiveSourceRef],
        actorRefs: [JazzArchiveActorRef],
        provenance: JazzArchiveProvenance,
        quality: JazzArchiveQuality,
        privacy: JazzArchivePrivacy
    ) {
        self.originId = originId
        self.captureId = captureId
        self.streamId = streamId
        self.sourceRefs = sourceRefs
        self.actorRefs = actorRefs
        self.provenance = provenance
        self.quality = quality
        self.privacy = privacy
    }
}

public enum CaptureCoachJournalWriterError: Error, Equatable {
    case pendingInteraction(String)
}

/// Thin durable sink for the coordinator. A failed append keeps the exact token and record in
/// memory for retry; after process death CaptureJournal's persisted intent provides the same repair.
public actor CaptureCoachJournalWriter: CaptureCoachInteractionRecorder {
    private struct Pending: Sendable {
        var interaction: CaptureCoachInteraction
        var token: CaptureJournalReservationToken
        var record: ArchiveRecord<CaptureCoachInteraction>
    }

    private let journal: CaptureJournal
    private let context: CaptureCoachRecordContext
    private var pending: Pending?

    public init(journal: CaptureJournal, context: CaptureCoachRecordContext) {
        self.journal = journal
        self.context = context
    }

    public func append(_ interaction: CaptureCoachInteraction) async throws {
        try interaction.validate()
        if let pending {
            guard pending.interaction == interaction else {
                throw CaptureCoachJournalWriterError.pendingInteraction(
                    pending.interaction.interactionId)
            }
            try await journal.resolveObservation(pending.token, record: pending.record)
            self.pending = nil
            return
        }

        let token = try await journal.reserve(streamId: context.streamId)
        let isHumanAction: Bool
        switch interaction.interactionType {
        case .answered, .dismissed, .muted, .resumed, .finishAnyway:
            isHumanAction = true
        case .received, .shown, .suppressed, .unavailable:
            isHumanAction = false
        }
        let provenance = JazzArchiveProvenance(
            factClass: interaction.interactionType == .answered
                ? .declared : context.provenance.factClass,
            sources: context.provenance.sources,
            transformations: context.provenance.transformations)
        let record = ArchiveRecord(
            interaction: interaction,
            originId: context.originId,
            captureId: context.captureId,
            streamId: context.streamId,
            streamSequence: token.streamSequence,
            sourceRefs: context.sourceRefs,
            actorRefs: isHumanAction ? context.actorRefs : [],
            provenance: provenance,
            quality: context.quality,
            privacy: context.privacy)
        pending = Pending(interaction: interaction, token: token, record: record)
        do {
            try await journal.resolveObservation(token, record: record)
            pending = nil
        } catch {
            throw error
        }
    }
}

public enum CaptureCoachPromptDisposition: Equatable, Sendable {
    case shown
    case suppressed(CaptureCoachDispositionReason)
}

public struct CaptureCoachPromptDecision: Equatable, Sendable {
    public var promptId: String
    public var disposition: CaptureCoachPromptDisposition
    /// Newly persisted audit records. An idempotent redelivery can legitimately return an empty list.
    public var recordedInteractions: [CaptureCoachInteraction]

    public init(
        promptId: String,
        disposition: CaptureCoachPromptDisposition,
        recordedInteractions: [CaptureCoachInteraction]
    ) {
        self.promptId = promptId
        self.disposition = disposition
        self.recordedInteractions = recordedInteractions
    }
}

public struct CaptureCoachCoordinatorSnapshot: Equatable, Sendable {
    public var outstandingPrompt: CaptureCoachPrompt?
    public var pendingReceivedPrompt: CaptureCoachPrompt?
    public var mutedUntil: String?
    public var cooldownUntil: String?
    public var finishedAnyway: Bool
    public var captureCommitted: Bool
    public var closedLabelIds: [String]
    public var knownPromptCount: Int
}

public enum CaptureCoachCoordinatorError: Error, Equatable, CustomStringConvertible {
    case invalidPolicy
    case invalidPrompt(String)
    case wrongCapture(expected: String, actual: String)
    case noOutstandingPrompt
    case promptMismatch(expected: String, actual: String)
    case invalidMuteDeadline
    case invalidUnavailableReason(CaptureCoachDispositionReason)
    case corruptHistory(String)

    public var description: String {
        switch self {
        case .invalidPolicy: return "Invalid Capture Coach delivery policy"
        case let .invalidPrompt(detail): return "Invalid Capture Coach prompt: \(detail)"
        case let .wrongCapture(expected, actual):
            return "Capture Coach prompt targets \(actual), expected \(expected)"
        case .noOutstandingPrompt: return "Capture Coach has no outstanding prompt"
        case let .promptMismatch(expected, actual):
            return "Capture Coach prompt mismatch: expected \(expected), got \(actual)"
        case .invalidMuteDeadline: return "Capture Coach mute deadline must be in the future"
        case let .invalidUnavailableReason(reason):
            return "Invalid Capture Coach unavailable reason: \(reason.rawValue)"
        case let .corruptHistory(detail): return "Corrupt Capture Coach history: \(detail)"
        }
    }
}

/// Foundation-only state machine for the advisory coach surface. Its state is a projection of the
/// canonical interactions, so relaunch recovery replays audit evidence instead of trusting a second
/// mutable state file.
public actor CaptureCoachCoordinator {
    private struct State: Sendable {
        var prompts: [String: CaptureCoachPrompt] = [:]
        var suppressed: [String: CaptureCoachDispositionReason] = [:]
        var outstanding: CaptureCoachPrompt?
        var pendingReceived: CaptureCoachPrompt?
        var watermarkByStream: [String: Int] = [:]
        var mutedUntil: Date?
        var cooldownUntil: Date?
        var finishedAnyway = false
        var captureCommitted = false
        var closedLabelIds: Set<String> = []
        var interactionIds: Set<String> = []
    }

    public nonisolated let captureId: String
    public nonisolated let policy: CaptureCoachPolicy

    private let recorder: any CaptureCoachInteractionRecorder
    private var state: State
    private var pendingWrite: CaptureCoachInteraction?

    public init(
        captureId: String,
        policy: CaptureCoachPolicy = CaptureCoachPolicy(),
        recorder: any CaptureCoachInteractionRecorder,
        recoveredInteractions: [CaptureCoachInteraction] = [],
        closedLabelIds: Set<String> = [],
        captureCommitted: Bool = false
    ) throws {
        try policy.validate()
        self.captureId = captureId
        self.policy = policy
        self.recorder = recorder
        var recovered = State()
        recovered.closedLabelIds = closedLabelIds
        recovered.captureCommitted = captureCommitted
        for interaction in recoveredInteractions {
            try Self.apply(interaction, policy: policy, captureId: captureId, to: &recovered)
        }
        if captureCommitted { recovered.outstanding = nil }
        self.state = recovered
    }

    /// Rebuild state from mixed archive records after CaptureJournal itself has been reopened.
    public static func recovering(
        archiveId: String,
        captureId: String,
        store: JazzArchiveDraftStore,
        policy: CaptureCoachPolicy = CaptureCoachPolicy(),
        recorder: any CaptureCoachInteractionRecorder,
        closedLabelIds: Set<String> = [],
        captureCommitted: Bool = false
    ) async throws -> CaptureCoachCoordinator {
        let records = try await store.allRecords(archiveId: archiveId, captureId: captureId)
        let interactions = try records.compactMap { record -> CaptureCoachInteraction? in
            guard record.recordType == ArchiveRecord<CaptureCoachInteraction>.coachRecordType else {
                return nil
            }
            return try record.coachInteractionRecord().payload
        }
        return try CaptureCoachCoordinator(
            captureId: captureId,
            policy: policy,
            recorder: recorder,
            recoveredInteractions: interactions,
            closedLabelIds: closedLabelIds,
            captureCommitted: captureCommitted)
    }

    public func snapshot() -> CaptureCoachCoordinatorSnapshot {
        CaptureCoachCoordinatorSnapshot(
            outstandingPrompt: state.outstanding,
            pendingReceivedPrompt: state.pendingReceived,
            mutedUntil: state.mutedUntil.map(Timestamps.iso8601),
            cooldownUntil: state.cooldownUntil.map(Timestamps.iso8601),
            finishedAnyway: state.finishedAnyway,
            captureCommitted: state.captureCommitted,
            closedLabelIds: state.closedLabelIds.sorted(),
            knownPromptCount: state.prompts.count + state.suppressed.keys.filter {
                state.prompts[$0] == nil
            }.count)
    }

    public func updateClosedLabelIds(_ labelIds: Set<String>) {
        state.closedLabelIds = labelIds
        if let labelId = state.outstanding?.labelId, labelIds.contains(labelId) {
            state.outstanding = nil
        }
    }

    public func markCaptureCommitted() {
        state.captureCommitted = true
        state.outstanding = nil
        state.pendingReceived = nil
    }

    @discardableResult
    public func receive(
        _ prompt: CaptureCoachPrompt,
        at date: Date = Date()
    ) async throws -> CaptureCoachPromptDecision {
        let flushed = try await flushPendingWrite()
        try prompt.validate(for: captureId)
        if let flushed, flushed.promptId == prompt.promptId,
            flushed.interactionType == .shown
        {
            return CaptureCoachPromptDecision(
                promptId: prompt.promptId,
                disposition: .shown,
                recordedInteractions: [flushed])
        }

        if let pending = state.pendingReceived {
            if pending.promptId == prompt.promptId {
                guard pending == prompt else {
                    throw CaptureCoachCoordinatorError.invalidPrompt(
                        "prompt identity was reused with different content")
                }
                let shown = Self.interaction(type: .shown, prompt: prompt, at: date)
                try await persist(shown)
                return CaptureCoachPromptDecision(
                    promptId: prompt.promptId,
                    disposition: .shown,
                    recordedInteractions: [shown])
            }
            return try await suppress(prompt, reason: .rateLimited, at: date)
        }

        if let priorSuppression = state.suppressed[prompt.promptId] {
            return CaptureCoachPromptDecision(
                promptId: prompt.promptId,
                disposition: .suppressed(priorSuppression),
                recordedInteractions: [])
        }
        if state.prompts[prompt.promptId] != nil {
            return try await suppress(prompt, reason: .duplicate, at: date)
        }
        if state.captureCommitted || prompt.inputWatermark.captureCommitId != nil {
            return try await suppress(prompt, reason: .committedCapture, at: date)
        }
        if let labelId = prompt.labelId, state.closedLabelIds.contains(labelId) {
            return try await suppress(prompt, reason: .closedLabel, at: date)
        }
        if Self.isStale(prompt.inputWatermark, comparedWith: state.watermarkByStream) {
            return try await suppress(prompt, reason: .staleWatermark, at: date)
        }
        if state.finishedAnyway || state.mutedUntil.map({ date < $0 }) == true {
            return try await suppress(prompt, reason: .userAction, at: date)
        }
        if state.outstanding != nil || state.cooldownUntil.map({ date < $0 }) == true {
            return try await suppress(prompt, reason: .rateLimited, at: date)
        }

        let received = Self.interaction(type: .received, prompt: prompt, at: date)
        try await persist(received)
        let shown = Self.interaction(type: .shown, prompt: prompt, at: date)
        do {
            try await persist(shown)
        } catch {
            throw error
        }
        return CaptureCoachPromptDecision(
            promptId: prompt.promptId,
            disposition: .shown,
            recordedInteractions: [received, shown])
    }

    @discardableResult
    public func answer(
        promptId: String,
        answer: CaptureCoachAnswer,
        at date: Date = Date()
    ) async throws -> CaptureCoachInteraction {
        if let flushed = try await flushPendingWrite(),
            flushed.interactionType == .answered, flushed.promptId == promptId
        {
            return flushed
        }
        let prompt = try requireOutstanding(promptId)
        let interaction = Self.interaction(
            type: .answered, prompt: prompt, at: date, answer: answer)
        try await persist(interaction)
        return interaction
    }

    @discardableResult
    public func dismiss(
        promptId: String,
        at date: Date = Date()
    ) async throws -> CaptureCoachInteraction {
        if let flushed = try await flushPendingWrite(),
            flushed.interactionType == .dismissed, flushed.promptId == promptId
        {
            return flushed
        }
        let prompt = try requireOutstanding(promptId)
        let interaction = Self.interaction(type: .dismissed, prompt: prompt, at: date)
        try await persist(interaction)
        return interaction
    }

    @discardableResult
    public func mute(
        until deadline: Date? = nil,
        at date: Date = Date()
    ) async throws -> CaptureCoachInteraction {
        if let flushed = try await flushPendingWrite(), flushed.interactionType == .muted {
            return flushed
        }
        let deadline = deadline ?? date.addingTimeInterval(policy.defaultMuteSeconds)
        guard deadline > date else { throw CaptureCoachCoordinatorError.invalidMuteDeadline }
        let interaction = CaptureCoachInteraction(
            interactionType: .muted,
            occurredAt: Timestamps.iso8601(date),
            labelId: state.outstanding?.labelId,
            mutedUntil: Timestamps.iso8601(deadline))
        try await persist(interaction)
        return interaction
    }

    @discardableResult
    public func resume(at date: Date = Date()) async throws -> CaptureCoachInteraction? {
        if let flushed = try await flushPendingWrite(), flushed.interactionType == .resumed {
            return flushed
        }
        guard state.mutedUntil != nil else { return nil }
        let interaction = CaptureCoachInteraction(
            interactionType: .resumed,
            occurredAt: Timestamps.iso8601(date))
        try await persist(interaction)
        return interaction
    }

    @discardableResult
    public func finishAnyway(at date: Date = Date()) async throws -> CaptureCoachInteraction? {
        if let flushed = try await flushPendingWrite(), flushed.interactionType == .finishAnyway {
            return flushed
        }
        guard !state.finishedAnyway else { return nil }
        let interaction = CaptureCoachInteraction(
            interactionType: .finishAnyway,
            occurredAt: Timestamps.iso8601(date),
            labelId: state.outstanding?.labelId)
        try await persist(interaction)
        return interaction
    }

    /// Record that the optional server path was absent. This never creates a prompt and never acts
    /// as a quality gate for capture completion.
    @discardableResult
    public func reportUnavailable(
        _ reason: CaptureCoachDispositionReason,
        at date: Date = Date()
    ) async throws -> CaptureCoachInteraction {
        if let flushed = try await flushPendingWrite(),
            flushed.interactionType == .unavailable,
            flushed.dispositionReason == reason
        {
            return flushed
        }
        guard [.offline, .coachUnavailable, .unsupportedVersion].contains(reason) else {
            throw CaptureCoachCoordinatorError.invalidUnavailableReason(reason)
        }
        let interaction = CaptureCoachInteraction(
            interactionType: .unavailable,
            occurredAt: Timestamps.iso8601(date),
            dispositionReason: reason)
        try await persist(interaction)
        return interaction
    }

    private func requireOutstanding(_ promptId: String) throws -> CaptureCoachPrompt {
        guard let prompt = state.outstanding else {
            throw CaptureCoachCoordinatorError.noOutstandingPrompt
        }
        guard prompt.promptId == promptId else {
            throw CaptureCoachCoordinatorError.promptMismatch(
                expected: prompt.promptId, actual: promptId)
        }
        return prompt
    }

    private func suppress(
        _ prompt: CaptureCoachPrompt,
        reason: CaptureCoachDispositionReason,
        at date: Date
    ) async throws -> CaptureCoachPromptDecision {
        let interaction = Self.interaction(
            type: .suppressed, prompt: prompt, at: date, dispositionReason: reason)
        try await persist(interaction)
        return CaptureCoachPromptDecision(
            promptId: prompt.promptId,
            disposition: .suppressed(reason),
            recordedInteractions: [interaction])
    }

    private func persist(_ interaction: CaptureCoachInteraction) async throws {
        var projected = state
        try Self.apply(interaction, policy: policy, captureId: captureId, to: &projected)
        pendingWrite = interaction
        try await recorder.append(interaction)
        state = projected
        pendingWrite = nil
    }

    @discardableResult
    private func flushPendingWrite() async throws -> CaptureCoachInteraction? {
        guard let pendingWrite else { return nil }
        var projected = state
        try Self.apply(pendingWrite, policy: policy, captureId: captureId, to: &projected)
        try await recorder.append(pendingWrite)
        state = projected
        self.pendingWrite = nil
        return pendingWrite
    }

    private static func interaction(
        type: CaptureCoachInteractionType,
        prompt: CaptureCoachPrompt,
        at date: Date,
        answer: CaptureCoachAnswer? = nil,
        dispositionReason: CaptureCoachDispositionReason? = nil
    ) -> CaptureCoachInteraction {
        CaptureCoachInteraction(
            interactionType: type,
            occurredAt: Timestamps.iso8601(date),
            promptId: prompt.promptId,
            labelId: prompt.labelId,
            assessmentRef: prompt.assessmentRef,
            localBaselineRef: prompt.localBaselineRef,
            inputWatermark: prompt.inputWatermark,
            promptSnapshot: [.received, .shown, .suppressed].contains(type)
                ? prompt.snapshot : nil,
            answer: answer,
            dispositionReason: dispositionReason)
    }

    private static func isStale(
        _ watermark: CaptureCoachInputWatermark,
        comparedWith accepted: [String: Int]
    ) -> Bool {
        guard !accepted.isEmpty else { return false }
        let incoming = Dictionary(uniqueKeysWithValues: watermark.streams.map {
            ($0.streamId, $0.throughSequence)
        })
        var advances = false
        for (streamId, previous) in accepted {
            guard let current = incoming[streamId], current >= previous else { return true }
            if current > previous { advances = true }
        }
        if incoming.keys.contains(where: { accepted[$0] == nil }) { advances = true }
        return !advances
    }

    private static func apply(
        _ interaction: CaptureCoachInteraction,
        policy: CaptureCoachPolicy,
        captureId: String,
        to state: inout State
    ) throws {
        try interaction.validate()
        guard state.interactionIds.insert(interaction.interactionId).inserted else {
            throw CaptureCoachCoordinatorError.corruptHistory(
                "duplicate interaction \(interaction.interactionId)")
        }
        if let watermarkCaptureId = interaction.inputWatermark?.captureId,
            watermarkCaptureId != captureId
        {
            throw CaptureCoachCoordinatorError.wrongCapture(
                expected: captureId, actual: watermarkCaptureId)
        }

        let prompt: CaptureCoachPrompt? = try {
            guard let promptId = interaction.promptId,
                let inputWatermark = interaction.inputWatermark
            else { return nil }
            if let existing = state.prompts[promptId] {
                if let snapshot = interaction.promptSnapshot, snapshot != existing.snapshot {
                    throw CaptureCoachCoordinatorError.corruptHistory(
                        "prompt \(promptId) changed snapshot")
                }
                guard interaction.assessmentRef == existing.assessmentRef,
                    interaction.localBaselineRef == existing.localBaselineRef,
                    inputWatermark == existing.inputWatermark,
                    interaction.labelId == existing.labelId
                else {
                    throw CaptureCoachCoordinatorError.corruptHistory(
                        "prompt \(promptId) changed context")
                }
                return existing
            }
            guard let snapshot = interaction.promptSnapshot else { return nil }
            return CaptureCoachPrompt(
                promptId: promptId,
                labelId: interaction.labelId,
                assessmentRef: interaction.assessmentRef,
                localBaselineRef: interaction.localBaselineRef,
                inputWatermark: inputWatermark,
                snapshot: snapshot)
        }()

        switch interaction.interactionType {
        case .received:
            guard let prompt else {
                throw CaptureCoachCoordinatorError.corruptHistory("received lacks prompt")
            }
            if let existing = state.prompts[prompt.promptId], existing != prompt {
                throw CaptureCoachCoordinatorError.corruptHistory(
                    "prompt \(prompt.promptId) identity collision")
            }
            state.prompts[prompt.promptId] = prompt
            state.pendingReceived = prompt
        case .shown:
            guard let prompt else {
                throw CaptureCoachCoordinatorError.corruptHistory("shown lacks prompt")
            }
            state.prompts[prompt.promptId] = prompt
            state.pendingReceived = nil
            state.outstanding = prompt
            for watermark in prompt.inputWatermark.streams {
                state.watermarkByStream[watermark.streamId] = max(
                    state.watermarkByStream[watermark.streamId] ?? -1,
                    watermark.throughSequence)
            }
        case .answered, .dismissed:
            guard let promptId = interaction.promptId,
                let known = state.prompts[promptId]
            else {
                throw CaptureCoachCoordinatorError.corruptHistory(
                    "\(interaction.interactionType.rawValue) references unknown prompt")
            }
            if state.outstanding?.promptId == known.promptId { state.outstanding = nil }
            guard let occurredAt = Timestamps.parse(interaction.occurredAt) else {
                throw CaptureCoachCoordinatorError.corruptHistory("invalid action timestamp")
            }
            state.cooldownUntil = occurredAt.addingTimeInterval(policy.cooldownSeconds)
        case .suppressed:
            guard let promptId = interaction.promptId,
                let reason = interaction.dispositionReason
            else {
                throw CaptureCoachCoordinatorError.corruptHistory("suppression lacks context")
            }
            if let prompt { state.prompts[promptId] = prompt }
            state.suppressed[promptId] = reason
            if state.pendingReceived?.promptId == promptId { state.pendingReceived = nil }
            if [.closedLabel, .committedCapture, .userAction].contains(reason),
                state.outstanding?.promptId == promptId
            {
                state.outstanding = nil
            }
        case .muted:
            guard let mutedUntil = Timestamps.parse(interaction.mutedUntil) else {
                throw CaptureCoachCoordinatorError.corruptHistory("mute lacks deadline")
            }
            state.mutedUntil = mutedUntil
            state.outstanding = nil
            state.pendingReceived = nil
        case .resumed:
            state.mutedUntil = nil
        case .finishAnyway:
            state.finishedAnyway = true
            state.outstanding = nil
            state.pendingReceived = nil
        case .unavailable:
            break
        }
    }
}
