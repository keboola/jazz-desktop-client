import Foundation

/// One portable boundary for filesystem durability. Core describes which regular files and
/// directories must be committed, while each native capture agent supplies the implementation
/// appropriate for its operating system.
public struct JazzArchiveFilesystemDurability: Sendable {
    private let synchronizeRegularFileBody:
        @Sendable (URL, Int16?) throws -> Void
    private let synchronizeDirectoryBody: @Sendable (URL) throws -> Void

    public init(
        synchronizeRegularFile:
            @escaping @Sendable (URL, Int16?) throws -> Void,
        synchronizeDirectory: @escaping @Sendable (URL) throws -> Void
    ) {
        self.synchronizeRegularFileBody = synchronizeRegularFile
        self.synchronizeDirectoryBody = synchronizeDirectory
    }

    public func synchronizeRegularFile(
        _ file: URL,
        permissions: Int16? = nil
    ) throws {
        try synchronizeRegularFileBody(file, permissions)
    }

    public func synchronizeDirectory(_ directory: URL) throws {
        try synchronizeDirectoryBody(directory)
    }

    /// Commit every regular file before its containing directories, deepest directory first.
    /// Symlinks and unexpected filesystem objects fail closed instead of being followed.
    public func synchronizeTree(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws {
        let root = directory.standardizedFileURL
        let rootValues: URLResourceValues
        do {
            rootValues = try root.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw JazzArchiveFilesystemDurabilityError.unsafeObject(root.path)
        }
        guard rootValues.isDirectory == true,
            rootValues.isSymbolicLink != true
        else {
            throw JazzArchiveFilesystemDurabilityError.unsafeObject(root.path)
        }

        var regularFiles: [URL] = []
        var directories: [URL] = [root]
        var pendingDirectories: [URL] = [root]
        while let current = pendingDirectories.popLast() {
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: current,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    ],
                    options: [])
            } catch {
                throw JazzArchiveFilesystemDurabilityError.unsafeObject(current.path)
            }
            for url in children {
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(
                        forKeys: [
                            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                        ])
                } catch {
                    throw JazzArchiveFilesystemDurabilityError.unsafeObject(url.path)
                }
                guard values.isSymbolicLink != true else {
                    throw JazzArchiveFilesystemDurabilityError.unsafeObject(url.path)
                }
                if values.isDirectory == true {
                    directories.append(url)
                    pendingDirectories.append(url)
                } else if values.isRegularFile == true {
                    regularFiles.append(url)
                } else {
                    throw JazzArchiveFilesystemDurabilityError.unsafeObject(url.path)
                }
            }
        }

        for file in regularFiles.sorted(by: {
            $0.standardizedFileURL.path < $1.standardizedFileURL.path
        }) {
            try synchronizeRegularFile(file)
        }
        for child in directories.sorted(by: {
            let left = $0.standardizedFileURL.pathComponents.count
            let right = $1.standardizedFileURL.pathComponents.count
            return left == right
                ? $0.standardizedFileURL.path > $1.standardizedFileURL.path
                : left > right
        }) {
            try synchronizeDirectory(child)
        }
    }
}

public enum JazzArchiveFilesystemDurabilityError: Error, Equatable, Sendable {
    case unsafeObject(String)
    case synchronizationFailed
}

/// Cross-process filesystem lease used where an actor protects only one process. Native agents
/// choose a stable lock-file name per durable root; Core never opens or interprets that file.
public protocol JazzArchiveFilesystemLease: Sendable {
    func release()
}

public protocol JazzArchiveFilesystemLeaseProvider: Sendable {
    func acquire(
        root: URL,
        fileManager: FileManager
    ) throws -> any JazzArchiveFilesystemLease
}

public enum JazzArchiveFilesystemLeaseError: Error, Equatable, Sendable {
    case inProgress
    case acquisitionFailed
}
