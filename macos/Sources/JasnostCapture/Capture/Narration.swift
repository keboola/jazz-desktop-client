import AVFoundation
import JasnostCaptureCore

/// Records ONE narration audio blob per session (AAC/m4a) for think-aloud capture.
/// Requires Microphone permission.
final class NarrationRecorder {
    private var recorder: AVAudioRecorder?
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
    func start() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jasnost-narration-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.record()
        recorder = rec
        fileURL = url
        let started = Timestamps.iso8601()
        startedAt = started
        return started
    }

    /// Stop recording; returns the file + its start time for upload (nil if not recording).
    func stop() -> (url: URL, startedAt: String)? {
        recorder?.stop()
        recorder = nil
        guard let url = fileURL, let started = startedAt else { return nil }
        fileURL = nil
        startedAt = nil
        return (url, started)
    }

    var isRecording: Bool { recorder?.isRecording ?? false }
}
