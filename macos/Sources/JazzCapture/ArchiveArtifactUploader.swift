import Foundation
import JazzCaptureCore

/// Retryable Keboola Files projection over canonical archive artifacts. The queue contains only
/// pointers/metadata; bytes are always re-read and digest-verified from the Jazz archive.
actor ArchiveArtifactUploader {
    struct Status: Equatable, Sendable {
        var pendingCount = 0
        var lastError: String?
        var isUploading = false
    }

    private enum Backoff {
        static let initial: TimeInterval = 2
        static let max: TimeInterval = 60
    }

    private let queue: JazzArchiveDeliveryQueue
    private let archiveStore: JazzArchiveDraftStore
    private var stackURL: String
    private var status = Status()
    private var onStatus: (@Sendable (Status) -> Void)?
    private var onDelivered: (@MainActor @Sendable (JazzArchiveDeliveryEntry, String) -> Void)?
    private var loopTask: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var nudged = false
    private var backoff = Backoff.initial

    init(queue: JazzArchiveDeliveryQueue, archiveRoot: URL, stackURL: String) {
        self.queue = queue
        self.archiveStore = JazzArchiveDraftStore(
            root: archiveRoot,
            durability: JazzArchiveFilesystemPlatform.durability)
        self.stackURL = stackURL
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) async {
        onStatus = handler
        status.pendingCount = await queue.pending().count
        handler(status)
    }

    func setDeliveredHandler(
        _ handler: @escaping @MainActor @Sendable (JazzArchiveDeliveryEntry, String) -> Void
    ) {
        onDelivered = handler
    }

    func setStackURL(_ value: String) { stackURL = value }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await run() }
    }

    func enqueue(_ entry: JazzArchiveDeliveryEntry) async throws {
        _ = try await queue.enqueue(entry)
        status.pendingCount = await queue.pending().count
        onStatus?(status)
        nudge()
    }

    func pending() async -> Int { await queue.pending().count }

    func nudge() {
        nudged = true
        wake?.resume()
        wake = nil
    }

    private func run() async {
        while !Task.isCancelled {
            let complete = await drainOnce()
            if complete {
                backoff = Backoff.initial
                if await queue.pending().isEmpty { await waitForNudge() }
            } else {
                let deadline = backoff + Double.random(in: 0...(backoff * 0.25))
                var elapsed: TimeInterval = 0
                while elapsed < deadline, !nudged, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    elapsed += 0.25
                }
                if nudged {
                    nudged = false
                    backoff = Backoff.initial
                } else {
                    backoff = min(backoff * 2, Backoff.max)
                }
            }
        }
    }

    private func waitForNudge() async {
        if nudged { nudged = false; return }
        await withCheckedContinuation { wake = $0 }
        nudged = false
    }

    private func drainOnce() async -> Bool {
        let items = await queue.pending()
        publish {
            $0.pendingCount = items.count
            $0.isUploading = !items.isEmpty
        }
        guard !items.isEmpty else { return true }
        let client = KeboolaClient(stackURL: stackURL)
        for item in items {
            if let remoteId = await existingRemoteId(client: client, entry: item) {
                guard await finish(item, remoteId: String(remoteId)) else { return false }
                continue
            }
            let localFile: JazzArchiveVerifiedArtifactFile
            do {
                localFile = try await archiveStore.artifactFile(
                    archiveId: item.archiveId,
                    captureId: item.captureId,
                    artifactId: item.artifactId)
            } catch {
                publish {
                    $0.lastError = "Artifact projection waiting for local archive recovery"
                    $0.isUploading = false
                }
                return false
            }
            let prepared: KeboolaAPI.FilesPrepare
            do {
                prepared = try await client.prepareFile(
                    name: item.fileName, tags: item.tags, isPermanent: true)
            } catch {
                markRetrying()
                return false
            }
            guard let params = prepared.gcsUploadParams else {
                try? await client.deleteFile(id: prepared.id)
                publish {
                    $0.lastError = "Artifact projection: stack returned no upload params"
                    $0.isUploading = false
                }
                return false
            }
            do {
                if item.kind != "screenshot" {
                    try await KeboolaClient.uploadLargeBlobToGCS(
                        fileURL: localFile.url, params: params, contentType: item.mediaType)
                } else {
                    try await KeboolaClient.uploadToGCS(
                        data: try Data(contentsOf: localFile.url),
                        params: params,
                        contentType: item.mediaType)
                }
                guard await finish(item, remoteId: String(prepared.id)) else { return false }
            } catch {
                try? await client.deleteFile(id: prepared.id)
                markRetrying()
                return false
            }
        }
        publish { $0.isUploading = false }
        return true
    }

    private func existingRemoteId(
        client: KeboolaClient,
        entry: JazzArchiveDeliveryEntry
    ) async -> Int? {
        let listed = await client.listFiles(tags: ["artifact:\(entry.artifactId)"])
            .sorted { ($0.created ?? "") < ($1.created ?? "") }
        var candidates: [NarrationDedup.Candidate] = []
        for file in listed {
            let present = file.url.map { url in
                Task { await KeboolaClient.gcsObjectExists(signedURL: url) }
            }
            candidates.append(NarrationDedup.Candidate(
                fileId: file.id, present: await present?.value))
        }
        let decision = NarrationDedup.decide(candidates)
        for id in decision.danglingToDelete { try? await client.deleteFile(id: id) }
        return decision.reuseFileId
    }

    private func finish(_ item: JazzArchiveDeliveryEntry, remoteId: String) async -> Bool {
        do {
            _ = try await queue.markDelivered(
                artifactId: item.artifactId, remoteFileId: remoteId)
            await onDelivered?(item, remoteId)
            publish {
                $0.pendingCount = max(0, $0.pendingCount - 1)
                $0.lastError = nil
            }
            return true
        } catch {
            publish {
                $0.lastError = "Artifact delivery receipt could not be saved"
                $0.isUploading = false
            }
            return false
        }
    }

    private func markRetrying() {
        publish {
            $0.lastError = "Artifact upload waiting to retry (offline?) — evidence safe in archive"
            $0.isUploading = false
        }
    }

    private func publish(_ mutation: (inout Status) -> Void) {
        mutation(&status)
        onStatus?(status)
    }
}
