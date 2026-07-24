import AVFoundation
import JasnostCaptureCore

enum NarrationRecorderError: Error {
    case recordingDidNotStart
}

/// Records ONE narration audio blob per session (AAC/m4a) for think-aloud capture.
/// Requires Microphone permission.
final class NarrationRecorder {
    typealias LivePCMHandler = @Sendable (CaptureCoachLivePCMChunk) -> Void

    private var recorder: AVAudioRecorder?
    private var livePCMAdapter: NarrationLivePCMAdapter?
    private(set) var fileURL: URL?
    private(set) var startedAt: String?

    static let mimeType = "audio/mp4"

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Begin recording; returns the ISO-8601 start time (aligns the audio to the timeline).
    @discardableResult
    func start(
        at url: URL,
        livePCMHandler: LivePCMHandler? = nil
    ) throws -> String {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        guard rec.record(), rec.isRecording else {
            try? FileManager.default.removeItem(at: url)
            throw NarrationRecorderError.recordingDidNotStart
        }
        recorder = rec
        fileURL = url
        let started = Timestamps.iso8601()
        startedAt = started
        if let livePCMHandler {
            let adapter = NarrationLivePCMAdapter(handler: livePCMHandler)
            do {
                try adapter.start()
                livePCMAdapter = adapter
            } catch {
                // The canonical m4a remains authoritative. Live PCM is advisory and a device/audio
                // graph failure must not terminate the user's narration recording.
                adapter.stopAndFlush()
                livePCMAdapter = nil
            }
        }
        return started
    }

    /// Stop recording; returns the full wall-clock interval for timeline playback. The end is
    /// sampled at stop, not copied from the narration observation's start anchor.
    func stop() -> (url: URL, startedAt: String, endedAt: String)? {
        // Flush queued PCM before returning. Its callback carries the closed label explicitly, so
        // async spooling remains valid even after CaptureController clears currentLabelId.
        livePCMAdapter?.stopAndFlush()
        livePCMAdapter = nil
        let endedAt = Timestamps.iso8601()
        recorder?.stop()
        recorder = nil
        guard let url = fileURL, let started = startedAt else { return nil }
        fileURL = nil
        startedAt = nil
        return (url, started, endedAt)
    }

    var isRecording: Bool { recorder?.isRecording ?? false }
}

/// Consent-gated adapter owned by NarrationRecorder. It samples the microphone independently of
/// the archival AAC writer, converts every input frame to contiguous 16 kHz mono signed PCM, and
/// emits bounded two-second chunks. No STT or semantic processing occurs on the client.
private final class NarrationLivePCMAdapter: @unchecked Sendable {
    private static let outputRate = 16_000
    private static let maximumChunkBytes = 64_000

    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(
        label: "dev.jasnost.capture-coach-pcm", qos: .utility)
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

    func stopAndFlush() {
        callbackGate.stopAccepting()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if running {
            engine.stop()
            running = false
        }
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
