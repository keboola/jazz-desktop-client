import AVFoundation
import JazzCaptureCore

enum NarrationRecorderError: Error {
    case recordingDidNotStart
    case unreadableClosedRecording
}

/// Records ONE narration audio blob per session (AAC/m4a) for think-aloud capture.
/// Requires Microphone permission.
@MainActor
final class NarrationRecorder {
    typealias LivePCMHandler = @Sendable (CaptureCoachLivePCMChunk) -> Void
    struct Recording: Sendable {
        let url: URL
        let startedAt: String
        let endedAt: String
    }
    /// Closure-backed native handles let tests drive the actual stop/drain boundary without a mic.
    struct NativeSources {
        let isRecording: () -> Bool
        let stopRecording: () -> Void
        let stopPCM: () -> Void
        let drainPCM: @Sendable () -> Void
    }
    private var sources: NativeSources?
    private var fileURL: URL?
    private var startedAt: String?
    private var persistStop: ((String, String) throws -> Void)?
    private var pending: [Task<Void, Never>] = []
    private var pendingCount = 0
    private(set) var closeError: Error?
    private let canAdmit: () -> Bool
    private let makeSources: (URL, LivePCMHandler?) throws -> NativeSources
    private let probe: @Sendable (URL) throws -> Void
    var onStateChange: (() -> Void)?

    nonisolated static let mimeType = "audio/mp4"

    init(
        canAdmit: @escaping () -> Bool,
        makeSources: ((URL, LivePCMHandler?) throws -> NativeSources)? = nil,
        probe: @escaping @Sendable (URL) throws -> Void = { url in
            guard try AVAudioFile(forReading: url).length > 0 else {
                throw NarrationRecorderError.unreadableClosedRecording
            }
        }
    ) {
        self.canAdmit = canAdmit
        self.makeSources = makeSources ?? Self.nativeSources
        self.probe = probe
    }

    @discardableResult
    func start(
        at url: URL,
        persistStart: (String) throws -> Void,
        persistStop: @escaping (String, String) throws -> Void,
        livePCMHandler: LivePCMHandler? = nil
    ) throws -> String {
        guard isQuiescent, closeError == nil, canAdmit() else { throw NarrationRecorderError.recordingDidNotStart }
        try persistStart(Timestamps.iso8601())
        // The durable callback may have revoked eligibility; never construct native sources then.
        guard canAdmit() else { throw NarrationRecorderError.recordingDidNotStart }
        let native = try makeSources(url, livePCMHandler)
        sources = native
        fileURL = url
        let started = Timestamps.iso8601()
        startedAt = started
        self.persistStop = persistStop
        onStateChange?()
        return started
    }

    /// BOTH producers stop synchronously. Container probe/receipt persistence and advisory callback
    /// drain are separate retained tasks: a blocked advisory handler cannot extend the AAC interval.
    /// The caller owns the returned canonical result; no timeout deletes its sole-source file.
    func stop() -> Task<Result<Recording, Error>, Never>? {
        guard let native = sources else { return nil }
        native.stopPCM()
        let wasRecording = native.isRecording()
        native.stopRecording()
        sources = nil // Neither producer is considered off until BOTH synchronous stops return.
        let ended = Timestamps.iso8601()
        let url = fileURL
        let started = startedAt
        let persist = persistStop
        fileURL = nil
        startedAt = nil
        persistStop = nil
        let probe = probe
        let finalization = Task.detached {
            Result { () throws -> Recording in
                guard wasRecording, let url, let started, let persist else {
                    throw NarrationRecorderError.unreadableClosedRecording
                }
                try probe(url)
                try persist(started, ended)
                return Recording(url: url, startedAt: started, endedAt: ended)
            }
        }
        let drain = Task.detached { native.drainPCM() }
        pendingCount += 1
        let settled = Task {
            if case .failure(let error) = await finalization.value {
                self.closeError = error
                self.onStateChange?()
            }
            await drain.value
            self.pendingCount -= 1
            if self.pendingCount == 0 { self.pending.removeAll() }
            self.onStateChange?()
        }
        pending.append(settled)
        onStateChange?()
        return finalization
    }

    func waitForQuiescence() async {
        for task in pending { await task.value }
        pending.removeAll()
    }

    var isRecording: Bool { sources?.isRecording() == true }
    // AAC state says nothing about the independent PCM engine. Retain conservative physical
    // ownership until stop() has stopped both, even if AAC unexpectedly reports inactive.
    var hasPotentiallyActiveProducers: Bool { sources != nil }

    func microphonePermissionSatisfied(_ granted: @autoclosure () -> Bool) -> Bool {
        !hasPotentiallyActiveProducers || granted()
    }
    var isQuiescent: Bool { sources == nil && pendingCount == 0 }
    var stateDescription: String {
        if isRecording { return "Microphone recording" }
        if hasPotentiallyActiveProducers { return "Microphone state unknown — sources may be active" }
        if closeError != nil { return "Microphone off — recording retained for recovery" }
        if !isQuiescent { return "Microphone off — finalizing/blocked" }
        return "Microphone off"
    }

    private static func nativeSources(at url: URL, handler: LivePCMHandler?) throws -> NativeSources {
        let rec = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ])
        guard rec.record(), rec.isRecording else {
            rec.stop()
            throw NarrationRecorderError.recordingDidNotStart
        }
        let adapter = handler.map { NarrationLivePCMAdapter(handler: $0) }
        do { try adapter?.start() }
        catch { adapter?.stopProducing() } // AAC remains canonical even if advisory setup fails.
        return NativeSources(
            isRecording: { rec.isRecording }, stopRecording: { rec.stop() },
            stopPCM: { adapter?.stopProducing() }, drainPCM: { adapter?.drain() })
    }
}

/// Consent-gated adapter owned by NarrationRecorder. It samples the microphone independently of
/// the archival AAC writer, converts every input frame to contiguous 16 kHz mono signed PCM, and
/// emits bounded two-second chunks. No STT or semantic processing occurs on the client.
private final class NarrationLivePCMAdapter: @unchecked Sendable {
    private static let outputRate = 16_000
    private static let maximumChunkBytes = 64_000

    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(
        label: "dev.jazz.capture-coach-pcm", qos: .utility)
    private let callbackGate = CaptureCoachLiveCallbackDrainGate()
    private let handler: NarrationRecorder.LivePCMHandler
    private var pending = Data()
    private var sequence = 0
    private var emittedFrames = 0
    private var resampleAccumulator = 0.0
    private var running = false
    private var tapInstalled = false

    init(handler: @escaping NarrationRecorder.LivePCMHandler) {
        self.handler = handler
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NarrationRecorderError.recordingDidNotStart
        }
        callbackGate.startAccepting()
        input.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: format
        ) { [weak self] buffer, _ in
            guard let self,
                let admission = self.callbackGate.admit(),
                let channels = buffer.floatChannelData,
                buffer.frameLength > 0
            else { return }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            let sampleRate = buffer.format.sampleRate
            var mono = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channels[channel][frame]
                }
                mono[frame] = sum / Float(channelCount)
            }
            self.processingQueue.async {
                self.consume(mono, inputRate: sampleRate)
                admission.complete()
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        running = true
    }

    func stopProducing() {
        callbackGate.stopAccepting()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if running {
            engine.stop()
            running = false
        }
    }

    func drain() {
        callbackGate.wait()
        processingQueue.sync { flush() }
    }

    private func consume(_ samples: [Float], inputRate: Double) {
        guard inputRate > 0 else { return }
        for value in samples {
            resampleAccumulator += Double(Self.outputRate)
            while resampleAccumulator >= inputRate {
                resampleAccumulator -= inputRate
                let clamped = min(max(value, -1), 1)
                var sample = Int16(
                    (clamped * Float(Int16.max)).rounded()
                ).littleEndian
                withUnsafeBytes(of: &sample) { pending.append(contentsOf: $0) }
                if pending.count == Self.maximumChunkBytes {
                    flush()
                }
            }
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        // Every sample is Int16; a partial trailing byte can never be produced.
        let frameCount = pending.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else {
            pending.removeAll(keepingCapacity: true)
            return
        }
        let start = emittedFrames
        let end = emittedFrames + frameCount
        let bytes = pending
        pending.removeAll(keepingCapacity: true)
        guard
            let chunk = try? CaptureCoachLivePCMChunk(
                sequence: sequence,
                startMillis: start * 1_000 / Self.outputRate,
                endMillis: end * 1_000 / Self.outputRate,
                recordedAt: Timestamps.iso8601(),
                bytes: bytes)
        else { return }
        emittedFrames = end
        sequence += 1
        handler(chunk)
    }
}
