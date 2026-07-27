import Foundation

/// Raw, bounded linear-PCM segment emitted by a platform capture adapter. It is intentionally not
/// an archive artifact and carries no transcription or semantic inference.
public struct CaptureCoachLivePCMChunk: Equatable, Sendable {
    public var sequence: Int
    public var startMillis: Int
    public var endMillis: Int
    public var recordedAt: String
    public var bytes: Data

    public init(
        sequence: Int,
        startMillis: Int,
        endMillis: Int,
        recordedAt: String,
        bytes: Data
    ) throws {
        self.sequence = sequence
        self.startMillis = startMillis
        self.endMillis = endMillis
        self.recordedAt = recordedAt
        self.bytes = bytes
        guard sequence >= 0,
            startMillis >= 0,
            endMillis > startMillis,
            Timestamps.parse(recordedAt) != nil,
            !bytes.isEmpty,
            bytes.count <= CaptureCoachLiveLimits.maximumAudioBytes
        else {
            throw CaptureCoachLiveContractError.invalidField("pcmChunk")
        }
    }
}

extension CaptureCoachLiveProducer {
    /// Native producer identity is the archive's per-capture source identity. A device may create
    /// many captures, but their provisional assessments must never collapse into one lineage.
    public static func nativeDesktopArchiveSource(
        sourceId: String,
        version: String,
        liveAudioAvailable: Bool
    ) -> CaptureCoachLiveProducer {
        var capabilities = ["accessibility", "canonical_observation"]
        var unavailable = ["screen_preview", "transcript"]
        if liveAudioAvailable {
            capabilities.append("live_audio_chunk")
        } else {
            unavailable.append("live_audio_chunk")
        }
        return CaptureCoachLiveProducer(
            producerId: sourceId,
            kind: .nativeDesktop,
            version: version,
            capabilities: capabilities.sorted(),
            unavailableCapabilities: unavailable.sorted())
    }
}

/// Stable per-label stream identity. `streamId(for:)` is intentionally lazy so a microphone tap
/// racing ahead of UI actor registration still gets sequence zero instead of dropping evidence.
public struct CaptureCoachLiveLabelAudioStreams: Equatable, Sendable {
    private var values: [String: String] = [:]

    public init() {}

    public mutating func streamId(for labelId: String) -> String {
        if let existing = values[labelId] { return existing }
        let created = Identifiers.newStreamId()
        values[labelId] = created
        return created
    }
}

/// Per-label PCM reorder buffer. A later chunk may arrive first because platform callbacks are
/// bridged through async tasks; only a contiguous sequence beginning at zero is released to the
/// durable message projector. Exact duplicates are harmless, conflicting coordinates fail closed.
public struct CaptureCoachLivePCMSequencer: Sendable {
    public static let maximumReorderGap = 64
    public static let maximumPendingChunksPerLabel = 64
    public static let retainedCompletedChunksPerLabel = 128

    private struct LabelState: Sendable {
        var processId: String
        var nextSequence = 0
        var pending: [Int: CaptureCoachLivePCMChunk] = [:]
        var completed: [Int: CaptureCoachLivePCMChunk] = [:]
    }

    private var labels: [String: LabelState] = [:]

    public init() {}

    public var hasPendingChunks: Bool {
        labels.values.contains { !$0.pending.isEmpty }
    }

    public mutating func admit(
        labelId: String,
        processId: String,
        chunk: CaptureCoachLivePCMChunk
    ) throws -> [CaptureCoachLivePCMChunk] {
        var state =
            labels[labelId]
            ?? LabelState(processId: processId)
        guard state.processId == processId else {
            throw CaptureCoachLiveContractError.identityCollision(labelId)
        }
        if let completed = state.completed[chunk.sequence] {
            guard completed == chunk else {
                throw CaptureCoachLiveContractError.identityCollision(
                    "\(labelId):\(chunk.sequence)")
            }
            return []
        }
        if let pending = state.pending[chunk.sequence] {
            guard pending == chunk else {
                throw CaptureCoachLiveContractError.identityCollision(
                    "\(labelId):\(chunk.sequence)")
            }
            return []
        }
        guard chunk.sequence >= state.nextSequence else {
            throw CaptureCoachLiveContractError.invalidField(
                "pcmSequencer.sequence outside retained history")
        }
        guard
            chunk.sequence - state.nextSequence <= Self.maximumReorderGap,
            state.pending.count < Self.maximumPendingChunksPerLabel
                || chunk.sequence == state.nextSequence
        else {
            throw CaptureCoachLiveContractError.invalidField(
                "pcmSequencer.reorderWindow")
        }
        state.pending[chunk.sequence] = chunk
        var released: [CaptureCoachLivePCMChunk] = []
        while let contiguous = state.pending.removeValue(
            forKey: state.nextSequence)
        {
            released.append(contiguous)
            state.completed[state.nextSequence] = contiguous
            state.nextSequence += 1
        }
        let oldestRetained = max(
            0, state.nextSequence - Self.retainedCompletedChunksPerLabel)
        state.completed = state.completed.filter { $0.key >= oldestRetained }
        labels[labelId] = state
        return released
    }
}

/// Fire-and-forget boundary between local durable work and advisory delivery. Callers invoke
/// `schedule()` only after their exact bytes are durable; the operation may then take forever
/// without joining capture close, label close, or action completion.
public final class CaptureCoachLiveDetachedDeliveryNudge: @unchecked Sendable {
    public typealias Operation = @Sendable () async -> Void

    private let operation: Operation

    public init(operation: @escaping Operation) {
        self.operation = operation
    }

    public func schedule() {
        let operation = self.operation
        Task { await operation() }
    }
}

/// Synchronously admits platform PCM callbacks into one serial local projection tail. The handler
/// may write durable local bytes, but it must not await delivery. Taking the tail snapshot in
/// `drain()` makes an immediate label/session stop wait for every chunk admitted before stop.
public final class CaptureCoachLivePCMAdmissionTail: @unchecked Sendable {
    public typealias Handler =
        @Sendable (
            _ labelId: String,
            _ processId: String,
            _ chunk: CaptureCoachLivePCMChunk
        ) async -> Void

    private let handler: Handler
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func submit(
        labelId: String,
        processId: String,
        chunk: CaptureCoachLivePCMChunk
    ) {
        lock.lock()
        let prior = tail
        let handler = self.handler
        tail = Task {
            await prior?.value
            await handler(labelId, processId, chunk)
        }
        lock.unlock()
    }

    public func drain() async {
        let pending = currentTail()
        await pending?.value
    }

    private func currentTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
  }
}

/// Synchronously orders label-context transitions admitted by the UI actor. The handler must only
/// mutate local runtime context; advisory network delivery is deliberately detached from this tail
/// so label/session close never joins a hanging request.
public final class CaptureCoachLiveLabelContextAdmissionTail: @unchecked Sendable {
  public typealias Handler =
        @Sendable (
            _ labelId: String?,
            _ processId: String?,
            _ presentationContext: CaptureCoachPresentationContext?
        ) async -> Void

  private let handler: Handler
  private let lock = NSLock()
  private var tail: Task<Void, Never>?

  public init(handler: @escaping Handler) {
    self.handler = handler
  }

    public func submit(
        labelId: String?,
        processId: String?,
        presentationContext: CaptureCoachPresentationContext?
    ) {
    lock.lock()
    let prior = tail
    let handler = self.handler
    tail = Task {
      await prior?.value
            await handler(labelId, processId, presentationContext)
    }
    lock.unlock()
  }

  public func drain() async {
    let pending = currentTail()
    await pending?.value
  }

  private func currentTail() -> Task<Void, Never>? {
    lock.lock()
    defer { lock.unlock() }
    return tail
  }
}

/// Atomically closes the callback-vs-stop race. Admission checks `accepting` and enters the drain
/// group under one lock; stop flips the same flag before waiting. A late callback is rejected,
/// while every callback accepted before stop is necessarily visible to `wait()`.
public final class CaptureCoachLiveCallbackDrainGate: @unchecked Sendable {
    public final class Admission: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: (@Sendable () -> Void)?

        fileprivate init(completion: @escaping @Sendable () -> Void) {
            self.completion = completion
        }

        public func complete() {
            lock.lock()
            let action = completion
            completion = nil
            lock.unlock()
            action?()
        }

        deinit { complete() }
    }

    private let lock = NSLock()
    private let group = DispatchGroup()
    private var accepting = false

    public init() {}

    public func startAccepting() {
        lock.lock()
        accepting = true
        lock.unlock()
    }

    public func admit() -> Admission? {
        lock.lock()
        guard accepting else {
            lock.unlock()
            return nil
        }
        group.enter()
        lock.unlock()
        return Admission { [group] in group.leave() }
    }

    public func stopAccepting() {
        lock.lock()
        accepting = false
        lock.unlock()
    }

    public func wait() {
        group.wait()
    }
}

/// Pure-Foundation canonical message builder. It advances a capture watermark only after the exact
/// message bytes are durable, and it accepts an explicit label context so a final PCM buffer can
/// still be projected after the UI has closed that label.
public actor CaptureCoachLiveMessageProjector {
    private let captureId: String
    private let producer: CaptureCoachLiveProducer
    private let messages: CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>
    private let stateRoot: URL
    private let stateURL: URL
    private let durability: JazzArchiveFilesystemDurability
    private let fileManager: FileManager

    private struct LabelHead: Sendable {
        var scope: CaptureCoachLiveScope? = nil
        var streamSequences: [String: Int] = [:]
        var transcriptWatermarks: [String: CaptureCoachTranscriptWatermark] = [:]
    }

    private struct PersistedLabelHead: Codable, Sendable {
        var labelId: String
        var scope: CaptureCoachLiveScope
        var streams: [CaptureCoachStreamWatermark]
        var transcripts: [CaptureCoachTranscriptWatermark]
    }

    private struct PersistedState: Codable, Sendable {
        var schemaVersion: Int
        var captureId: String
        var producer: CaptureCoachLiveProducer
        var heads: [PersistedLabelHead]
        var contentDigest: String

        init(
            captureId: String,
            producer: CaptureCoachLiveProducer,
            heads: [PersistedLabelHead]
        ) throws {
            schemaVersion = 1
            self.captureId = captureId
            self.producer = producer
            self.heads = heads
            contentDigest = ""
            contentDigest = JazzArchiveDigest.sha256Hex(
                try JazzArchiveCanonicalJSON.encode(digestMaterial))
            try validate()
        }

        func validate() throws {
            guard schemaVersion == 1 else {
                throw CaptureCoachLiveContractError.invalidField(
                    "messageHead.schemaVersion")
            }
            try CaptureCoachLiveValidation.uuidV7(captureId, prefix: "cap")
            try producer.validate()
            guard heads.map(\.labelId) == heads.map(\.labelId).sorted(),
                Set(heads.map(\.labelId)).count == heads.count
            else {
                throw CaptureCoachLiveContractError.invalidField(
                    "messageHead.labels")
            }
            for head in heads {
                try CaptureCoachLiveValidation.uuidV7(
                    head.labelId, prefix: "l")
                try head.scope.validate()
                let watermark = CaptureCoachInputWatermark(
                    schemaVersion: 2,
                    captureId: captureId,
                    streams: head.streams,
                    transcripts: head.transcripts)
                try watermark.validate()
            }
            try CaptureCoachLiveValidation.digest(
                declared: contentDigest, material: digestMaterial)
        }

        private struct DigestMaterial: Codable {
            var schemaVersion: Int
            var captureId: String
            var producer: CaptureCoachLiveProducer
            var heads: [PersistedLabelHead]
        }

        private var digestMaterial: DigestMaterial {
            DigestMaterial(
                schemaVersion: schemaVersion,
                captureId: captureId,
                producer: producer,
                heads: heads)
        }
    }

    private var heads: [String: LabelHead] = [:]

    public init(
        captureId: String,
        producer: CaptureCoachLiveProducer,
        messages: CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>,
        stateRoot: URL,
        durability: JazzArchiveFilesystemDurability,
        fileManager: FileManager = .default
    ) throws {
        try CaptureCoachLiveValidation.uuidV7(captureId, prefix: "cap")
        try producer.validate()
        guard stateRoot.isFileURL else {
            throw CaptureCoachLiveSpoolError.invalidRoot
        }
        self.captureId = captureId
        self.producer = producer
        self.messages = messages
        self.stateRoot = stateRoot
        stateURL = stateRoot.appendingPathComponent("head.json")
        self.durability = durability
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: stateRoot, withIntermediateDirectories: true)
        try durability.synchronizeDirectory(stateRoot)
        try durability.synchronizeDirectory(
            stateRoot.deletingLastPathComponent())
    }

    /// Rebuilds monotonic progress from one compact capture-scoped head plus exact pending bytes.
    /// It never scans or decodes another capture's acknowledged history.
    public func recoverPendingProgress() async throws {
        try loadPersistedState()
        let legacyAcknowledged =
            try await messages
            .legacyAcknowledgedDocuments()
        let pending = try await messages.pendingItems()
        let matchingLegacy = legacyAcknowledged.filter {
            $0.document.captureId == captureId
        }
        for item in matchingLegacy + pending
        where item.document.captureId == captureId {
            guard item.document.producer == producer else {
                throw CaptureCoachLiveContractError.identityCollision(captureId)
            }
            try merge(
                item.document.inputWatermark,
                labelId: item.document.labelId,
                scope: item.document.scope)
        }
        try persistState()
        try await messages.compactLegacyAcknowledgedDocuments(
            identifiers: Set(
                matchingLegacy.map(\.document.spoolIdentifier)))
    }

    @discardableResult
    public func enqueue(
        scope: CaptureCoachLiveScope,
        labelId: String,
        createdAt: String,
        streamProgress: [CaptureCoachStreamWatermark],
        transcriptProgress: [CaptureCoachTranscriptWatermark] = [],
        evidence: [CaptureCoachLiveEvidence]
    ) async throws -> CaptureCoachLivePendingItem<CaptureCoachLiveMessage> {
        let prior = heads[labelId] ?? LabelHead()
        if let existingScope = prior.scope, existingScope != scope {
            throw CaptureCoachLiveContractError.identityCollision(labelId)
        }
        var nextStreams = prior.streamSequences
        for progress in streamProgress {
            nextStreams[progress.streamId] = max(
                nextStreams[progress.streamId] ?? -1, progress.throughSequence)
        }
        var nextTranscripts = prior.transcriptWatermarks
        for progress in transcriptProgress {
            if let existing = nextTranscripts[progress.transcriptId] {
                if progress.revision == existing.revision,
                    progress.throughMillis == existing.throughMillis
                {
                    guard progress == existing else {
                        throw CaptureCoachLiveContractError.identityCollision(
                            progress.transcriptId)
                    }
                } else {
                    guard progress.revision >= existing.revision,
                        progress.throughMillis >= existing.throughMillis
                    else {
                        throw CaptureCoachLiveContractError.invalidField(
                            "messageProjector.transcriptProgress")
                    }
                }
            }
            nextTranscripts[progress.transcriptId] = progress
        }
        let watermark = CaptureCoachInputWatermark(
            schemaVersion: 2,
            captureId: captureId,
            streams: nextStreams.map {
                CaptureCoachStreamWatermark(
                    streamId: $0.key, throughSequence: $0.value)
            }.sorted { $0.streamId < $1.streamId },
            transcripts: nextTranscripts.values.sorted {
                $0.transcriptId < $1.transcriptId
            })
        let message = try CaptureCoachLiveMessage(
            scope: scope,
            producer: producer,
            captureId: captureId,
            labelId: labelId,
            createdAt: createdAt,
            inputWatermark: watermark,
            evidence: evidence)
        let pending = try await messages.enqueue(message)
        heads[labelId] = LabelHead(
            scope: scope,
            streamSequences: nextStreams,
            transcriptWatermarks: nextTranscripts)
        try persistState()
        return pending
    }

    /// A cleanly stopped capture is never resumed. Pending exact messages remain independently
    /// deliverable, so its small active-recovery head can be removed without touching queue bytes.
    public func retireRecoveryState() throws {
        guard fileManager.fileExists(atPath: stateURL.path) else { return }
        try fileManager.removeItem(at: stateURL)
        try durability.synchronizeDirectory(stateRoot)
        try durability.synchronizeDirectory(
            stateRoot.deletingLastPathComponent())
    }

    private func loadPersistedState() throws {
        guard fileManager.fileExists(atPath: stateURL.path) else { return }
        let data = try Data(contentsOf: stateURL)
        let state: PersistedState
        do {
            state = try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            throw CaptureCoachLiveSpoolError.corruptEntry(stateURL.path)
        }
        try state.validate()
        guard try JazzArchiveCanonicalJSON.encode(state) == data,
            state.captureId == captureId,
            state.producer == producer
        else {
            throw CaptureCoachLiveSpoolError.corruptEntry(stateURL.path)
        }
        heads = Dictionary(
            uniqueKeysWithValues: state.heads.map {
                (
                    $0.labelId,
                    LabelHead(
                        scope: $0.scope,
                        streamSequences: Dictionary(
                            uniqueKeysWithValues: $0.streams.map {
                                ($0.streamId, $0.throughSequence)
                            }),
                        transcriptWatermarks: Dictionary(
                            uniqueKeysWithValues: $0.transcripts.map {
                                ($0.transcriptId, $0)
                            })
                    )
                )
            })
    }

    private func persistState() throws {
        let persistedHeads = try heads.map { labelId, head in
            guard let scope = head.scope, !head.streamSequences.isEmpty else {
                throw CaptureCoachLiveContractError.invalidField(
                    "messageHead.label")
            }
            return PersistedLabelHead(
                labelId: labelId,
                scope: scope,
                streams: head.streamSequences.map {
                    CaptureCoachStreamWatermark(
                        streamId: $0.key, throughSequence: $0.value)
                }.sorted { $0.streamId < $1.streamId },
                transcripts: head.transcriptWatermarks.values.sorted {
                    $0.transcriptId < $1.transcriptId
                })
        }.sorted { $0.labelId < $1.labelId }
        let state = try PersistedState(
            captureId: captureId,
            producer: producer,
            heads: persistedHeads)
        let data = try JazzArchiveCanonicalJSON.encode(state)
        let temporary = stateRoot.appendingPathComponent(
            ".head-\(Identifiers.newUUIDv7().uuidString.lowercased())")
        var keepTemporary = true
        defer {
            if keepTemporary { try? fileManager.removeItem(at: temporary) }
        }
        guard
            fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        else { throw CaptureCoachLiveSpoolError.invalidRoot }
        try durability.synchronizeRegularFile(
            temporary, permissions: Int16(0o600))
        if fileManager.fileExists(atPath: stateURL.path) {
            _ = try fileManager.replaceItemAt(
                stateURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: stateURL)
        }
        keepTemporary = false
        try durability.synchronizeRegularFile(
            stateURL, permissions: Int16(0o600))
        try durability.synchronizeDirectory(stateRoot)
    }

    public func currentWatermark(
        labelId: String
    ) -> CaptureCoachInputWatermark? {
        guard let head = heads[labelId], !head.streamSequences.isEmpty else {
            return nil
        }
        return CaptureCoachInputWatermark(
            schemaVersion: 2,
            captureId: captureId,
            streams: head.streamSequences.map {
                CaptureCoachStreamWatermark(
                    streamId: $0.key, throughSequence: $0.value)
            }.sorted { $0.streamId < $1.streamId },
            transcripts: head.transcriptWatermarks.values.sorted {
                $0.transcriptId < $1.transcriptId
            })
    }

    private func merge(
        _ watermark: CaptureCoachInputWatermark,
        labelId: String,
        scope: CaptureCoachLiveScope
    ) throws {
        var head = heads[labelId] ?? LabelHead()
        if let existingScope = head.scope, existingScope != scope {
            throw CaptureCoachLiveContractError.identityCollision(labelId)
        }
        head.scope = scope
        for stream in watermark.streams {
            head.streamSequences[stream.streamId] = max(
                head.streamSequences[stream.streamId] ?? -1, stream.throughSequence)
        }
        for transcript in watermark.transcripts ?? [] {
            if let existing = head.transcriptWatermarks[transcript.transcriptId] {
                if transcript.revision == existing.revision,
                    transcript.throughMillis == existing.throughMillis
                {
                    guard transcript == existing else {
                        throw CaptureCoachLiveContractError.identityCollision(
                            transcript.transcriptId)
                    }
                } else if transcript.revision < existing.revision,
                    transcript.throughMillis <= existing.throughMillis
                {
                    continue
                } else {
                    guard transcript.revision >= existing.revision,
                        transcript.throughMillis >= existing.throughMillis
                    else {
                        throw CaptureCoachLiveContractError.invalidField(
                            "messageProjector.recoveredTranscriptFork")
                    }
                }
            }
            head.transcriptWatermarks[transcript.transcriptId] = transcript
        }
        heads[labelId] = head
    }
}
