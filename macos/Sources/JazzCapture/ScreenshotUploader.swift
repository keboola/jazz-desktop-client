import Foundation
import JazzCaptureCore

/// Disk-backed background uploader for screenshot PNGs (the prepare-early flow's second
/// half). The capture path only PREPARES the file (3s budget) so the event carries its
/// `screenshot_id` immediately; the bytes land here and upload off the capture path with
/// retry. Blobs are staged under `<spool>/shots/` so they never sit in RAM; the GCS
/// federation credentials stay in memory only — they are short-lived secrets, so persisting
/// them would be both useless after expiry and unsafe.
///
/// A blob whose upload terminally fails is logged + dropped; the event keeps the dangling
/// `screenshot_id` — a failed upload leaves the id referencing no blob, so the processor's
/// discovery logic treats it as a missing screenshot.
actor ScreenshotUploader {
    private struct Item {
        let fileURL: URL
        let params: KeboolaAPI.FilesPrepare.GCSUploadParams
        let contentType: String
    }

    /// Per-blob retry policy: attempts spaced 1s, 2s, 4s, 8s — then drop. A blob is not
    /// worth blocking the queue forever (its federation token expires anyway).
    private static let maxAttempts = 5
    private static let initialDelay: TimeInterval = 1

    private let directory: URL
    private var queue: [Item] = []
    private var working = false

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Blobs orphaned by a previous run are un-uploadable — their federation credentials
        // died with the process — so clean them up rather than leak disk.
        if let leftovers = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        {
            for url in leftovers { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Stage the bytes on disk and queue the upload. Failures to even stage are logged and
    /// dropped — the event already carries the (now dangling) id.
    func enqueue(
        data: Data, fileId: Int, params: KeboolaAPI.FilesPrepare.GCSUploadParams,
        contentType: String
    ) {
        // Local staging filename only (the Keboola object name was set at prepareFile); the
        // extension is cosmetic. Shots are JPEG now — name it so for clarity when inspecting the dir.
        let url = directory.appendingPathComponent("\(fileId).jpg")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("jazz: could not stage screenshot \(fileId): \(error)")
            return
        }
        queue.append(Item(fileURL: url, params: params, contentType: contentType))
        if !working {
            working = true
            Task { await work() }
        }
    }

    /// Blobs still queued or in flight — lets shutdown wait (bounded) for the uploads.
    func pending() -> Int { queue.count + (working ? 1 : 0) }

    private func work() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            await upload(item)
        }
        working = false
    }

    private func upload(_ item: Item) async {
        guard let data = try? Data(contentsOf: item.fileURL) else { return }
        var delay = Self.initialDelay
        for attempt in 1...Self.maxAttempts {
            do {
                try await KeboolaClient.uploadToGCS(
                    data: data, params: item.params, contentType: item.contentType)
                try? FileManager.default.removeItem(at: item.fileURL)
                return
            } catch {
                guard attempt < Self.maxAttempts else {
                    // Terminal: log + drop (the event keeps its dangling screenshot_id).
                    NSLog("jazz: screenshot upload dropped after \(attempt) attempts: \(error)")
                    try? FileManager.default.removeItem(at: item.fileURL)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 2
            }
        }
    }
}
