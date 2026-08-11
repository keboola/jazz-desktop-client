import Foundation
import XCTest

@testable import JazzCaptureCore

extension JazzArchiveUploadQueue {
    init(
        root: URL,
        fileManager: FileManager = .default
    ) {
        self.init(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: TestArchiveFilesystemLeaseProvider.shared,
            fileManager: fileManager)
    }
}

extension JazzArchiveImporter {
    init(
        root: URL,
        fileManager: FileManager = .default,
        limits: JazzArchiveImportLimits = JazzArchiveImportLimits()
    ) {
        self.init(
            root: root,
            durability: foundationTestFilesystemDurability(),
            fileManager: fileManager,
            limits: limits)
    }
}

extension JazzArchiveServerImportCoordinator {
    init(
        root: URL,
        importer: JazzArchiveImporter,
        transport: any JazzArchiveServerDownloadTransport,
        maximumBytes: Int64 = 2 * 1024 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default,
        durability: JazzArchiveFilesystemDurability =
            foundationTestFilesystemDurability()
    ) {
        self.init(
            root: root,
            importer: importer,
            transport: transport,
            leaseProvider: TestArchiveFilesystemLeaseProvider.shared,
            durability: durability,
            maximumBytes: maximumBytes,
            now: now,
            fileManager: fileManager)
    }
}

extension JazzArchiveServerDownloadRecovery {
    init(
        root: URL,
        importTargetRoot: URL,
        fileManager: FileManager = .default,
        durability: JazzArchiveFilesystemDurability =
            foundationTestFilesystemDurability()
    ) {
        self.init(
            root: root,
            importTargetRoot: importTargetRoot,
            leaseProvider: TestArchiveFilesystemLeaseProvider.shared,
            durability: durability,
            fileManager: fileManager)
    }
}

func foundationTestFilesystemDurability()
    -> JazzArchiveFilesystemDurability
{
    JazzArchiveFilesystemDurability(
        synchronizeRegularFile: { file, permissions in
            let values = try file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw JazzArchiveFilesystemDurabilityError.unsafeObject(file.path)
            }
            if let permissions {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: permissions)],
                    ofItemAtPath: file.path)
            }
        },
        synchronizeDirectory: { directory in
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw JazzArchiveFilesystemDurabilityError.unsafeObject(
                    directory.path)
            }
        })
}

final class ControllableFilesystemDurability: @unchecked Sendable {
    private enum Target: Equatable {
        case file(String)
        case directory(String)
    }

    private let lock = NSLock()
    private var target: Target?

    func armFile(_ file: URL) {
        lock.lock()
        target = .file(canonicalPath(file))
        lock.unlock()
    }

    func armDirectory(_ directory: URL) {
        lock.lock()
        target = .directory(canonicalPath(directory))
        lock.unlock()
    }

    func value() -> JazzArchiveFilesystemDurability {
        let foundation = foundationTestFilesystemDurability()
        return JazzArchiveFilesystemDurability(
            synchronizeRegularFile: { [self] file, permissions in
                try failIfArmed(.file(canonicalPath(file)))
                try foundation.synchronizeRegularFile(
                    file,
                    permissions: permissions)
            },
            synchronizeDirectory: { [self] directory in
                try failIfArmed(
                    .directory(canonicalPath(directory)))
                try foundation.synchronizeDirectory(directory)
            })
    }

    private func failIfArmed(_ candidate: Target) throws {
        lock.lock()
        let shouldFail = target == candidate
        if shouldFail { target = nil }
        lock.unlock()
        if shouldFail {
            throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

final class JazzArchiveFilesystemDurabilityTests: XCTestCase {
    func testCanonicalMutationAPIsCannotCompileWithAnImplicitDurabilityAdapter()
        throws
    {
        let macOSRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = macOSRoot.appendingPathComponent(
            "Sources/JazzCaptureCore", isDirectory: true)
        let files = [
            "CaptureIdentityStore.swift",
            "CaptureJournal.swift",
            "JazzArchive.swift",
            "JazzArchiveReviewStore.swift",
            "JazzArchiveFinalizer.swift",
            "JazzArchiveRevisionForker.swift",
            "JazzArchiveLocalIndex.swift",
            "JazzArchiveEvidencePlayback.swift",
            "JazzArchiveProjectionReconciler.swift",
            "JazzArchiveUpload.swift",
        ]

        for name in files {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(name),
                encoding: .utf8)
            XCTAssertFalse(
                source.contains(
                    "durability: JazzArchiveFilesystemDurability ="),
                "\(name) must require explicit production durability")
        }
    }

    func testSynchronizeTreeCommitsFilesBeforeDeepestDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-filesystem-durability-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.json")
        let second = nested.appendingPathComponent("second.json")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let recorder = FilesystemDurabilityEventRecorder()
        let durability = JazzArchiveFilesystemDurability(
            synchronizeRegularFile: { file, _ in
                recorder.append(.file(file.standardizedFileURL.path))
            },
            synchronizeDirectory: { directory in
                recorder.append(.directory(directory.standardizedFileURL.path))
            })

        try durability.synchronizeTree(root)

        let events = recorder.values()
        XCTAssertEqual(
            Set(events.prefix(2)),
            Set([
                .file(first.standardizedFileURL.path),
                .file(second.standardizedFileURL.path),
            ]))
        XCTAssertEqual(events.dropFirst(2).first, .directory(nested.path))
        XCTAssertEqual(events.last, .directory(root.path))
    }

    func testSynchronizeTreeFailsClosedWhenDirectoryEnumerationFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-filesystem-enumeration-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(
            at: denied,
            withIntermediateDirectories: true)
        let fileManager = FailingDirectoryContentsFileManager(
            deniedPath: denied.standardizedFileURL.path)
        let durability = JazzArchiveFilesystemDurability(
            synchronizeRegularFile: { _, _ in },
            synchronizeDirectory: { _ in })

        XCTAssertThrowsError(
            try durability.synchronizeTree(root, fileManager: fileManager)
        ) { error in
            guard case let .unsafeObject(path)? =
                error as? JazzArchiveFilesystemDurabilityError
            else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "denied")
        }
    }
}

private final class FilesystemDurabilityEventRecorder: @unchecked Sendable {
    enum Event: Hashable {
        case file(String)
        case directory(String)
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func append(_ event: Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func values() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class FailingDirectoryContentsFileManager: FileManager {
    private let deniedPath: String

    init(deniedPath: String) {
        self.deniedPath = deniedPath
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if url.standardizedFileURL.path == deniedPath {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask)
    }
}
