import Foundation

@testable import JasnostCaptureCore

// Core's production API requires an explicit durability implementation. These conveniences live
// only in the test target so legacy fixture setup stays concise without creating a silent
// production fallback for directory fsync.
extension CaptureJournal {
    init(root: URL, fileManager: FileManager = .default) {
        self.init(
            root: root,
            durability: foundationTestFilesystemDurability(),
            fileManager: fileManager)
    }
}

extension JazzArchiveDraftStore {
    init(root: URL, fileManager: FileManager = .default) {
        self.init(
            root: root,
            durability: foundationTestFilesystemDurability(),
            fileManager: fileManager)
    }

    init(
        root: URL,
        fileManager: FileManager = .default,
        simulatedCrashAfter: JazzArchiveDraftStoreWriteBoundary
    ) {
        self.init(
            root: root,
            fileManager: fileManager,
            durability: foundationTestFilesystemDurability(),
            simulatedCrashAfter: simulatedCrashAfter)
    }
}

extension JazzArchiveReviewStore {
    init(root: URL, fileManager: FileManager = .default) {
        self.init(
            root: root,
            durability: foundationTestFilesystemDurability(),
            fileManager: fileManager)
    }
}

extension JazzArchiveFinalizer {
    init(root: URL, fileManager: FileManager = .default) {
        self.init(
            root: root,
            durability: foundationTestFilesystemDurability(),
            fileManager: fileManager)
    }
}

extension JazzArchiveRevisionForker {
    init(root: URL, fileManager: FileManager = .default) {
        self.init(
            root: root,
            durability: foundationTestFilesystemDurability(),
            fileManager: fileManager)
    }
}

extension JazzArchiveLocalIndex {
    init(
        root: URL,
        eventSpool: EventSpool,
        fileManager: FileManager = .default
    ) {
        self.init(
            root: root,
            eventSpool: eventSpool,
            durability: foundationTestFilesystemDurability(),
            fileManager: fileManager)
    }
}

extension JazzArchiveEvidencePlaybackBuilder {
    init(root: URL, fileManager: FileManager = .default) {
        self.init(
            root: root,
            durability: foundationTestFilesystemDurability(),
            fileManager: fileManager)
    }
}

extension JazzArchiveProjectionReconciler {
    init(
        archiveRoot: URL,
        eventSpool: EventSpool,
        artifactQueue: JazzArchiveDeliveryQueue
    ) {
        self.init(
            archiveRoot: archiveRoot,
            eventSpool: eventSpool,
            artifactQueue: artifactQueue,
            durability: foundationTestFilesystemDurability())
    }
}

extension JazzArchiveConfirmedDelivery {
    init(
        archiveRoot: URL,
        queue: JazzArchiveUploadQueue,
        fileManager: FileManager = .default
    ) {
        self.init(
            archiveRoot: archiveRoot,
            queue: queue,
            durability: foundationTestFilesystemDurability(),
            fileManager: fileManager)
    }
}

final class CanonicalDurabilityRecorder: @unchecked Sendable {
    enum Event: Equatable {
        case file(String)
        case directory(String)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private var failure: (event: Event, matchesToSkip: Int)?

    func failOnce(on event: Event, afterMatches matchesToSkip: Int = 0) {
        precondition(matchesToSkip >= 0)
        lock.lock()
        failure = (event, matchesToSkip)
        lock.unlock()
    }

    func events() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func value() -> JazzArchiveFilesystemDurability {
        let foundation = foundationTestFilesystemDurability()
        return JazzArchiveFilesystemDurability(
            synchronizeRegularFile: { [self] file, permissions in
                try record(.file(Self.path(file)))
                try foundation.synchronizeRegularFile(
                    file, permissions: permissions)
            },
            synchronizeDirectory: { [self] directory in
                try record(.directory(Self.path(directory)))
                try foundation.synchronizeDirectory(directory)
            })
    }

    static func path(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func record(_ event: Event) throws {
        lock.lock()
        recorded.append(event)
        var shouldFail = false
        if let pending = failure, pending.event == event {
            if pending.matchesToSkip == 0 {
                shouldFail = true
                failure = nil
            } else {
                failure = (pending.event, pending.matchesToSkip - 1)
            }
        }
        lock.unlock()
        if shouldFail {
            throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
        }
    }
}
