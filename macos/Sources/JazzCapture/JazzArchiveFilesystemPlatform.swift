import Darwin
import Foundation
import JazzCaptureCore

/// macOS implementation of the one filesystem-durability boundary used by archive queue,
/// publication, and acquisition journals. Regular files require the macOS full-device flush;
/// directory entries use a native directory sync. Failure is fail-closed—there is deliberately no
/// weaker fallback that could make a network side effect outrun its local authority record.
enum JazzArchiveFilesystemPlatform {
    static let uploadQueueLeaseProvider: any JazzArchiveFilesystemLeaseProvider =
        DarwinArchiveFilesystemLeaseProvider(lockFileName: ".archive-upload.lock")
    static let serverDownloadLeaseProvider: any JazzArchiveFilesystemLeaseProvider =
        DarwinArchiveFilesystemLeaseProvider(lockFileName: ".server-download.lock")

    static let durability = JazzArchiveFilesystemDurability(
        synchronizeRegularFile: { file, permissions in
            try synchronizeRegularFile(file, permissions: permissions)
        },
        synchronizeDirectory: { directory in
            try synchronizeDirectory(directory)
        })

    private static func synchronizeRegularFile(
        _ file: URL,
        permissions: Int16?
    ) throws {
        let descriptor = Darwin.open(
            file.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            permissions.map({
                Darwin.fchmod(descriptor, mode_t($0)) == 0
            }) ?? true
        else {
            throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
        }
        while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            guard errno == EINTR else {
                throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
            }
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR
        else {
            throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
        }
        while Darwin.fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
            }
        }
    }
}

/// Executable-only implementation of the identity registry's cross-process lease.
enum CaptureIdentityStorePlatform {
    static let leaseProvider: any CaptureIdentityStoreLeaseProvider =
        DarwinCaptureIdentityStoreLeaseProvider()
}

/// The lease remains download-specific, but shares the same executable-only native boundary.
enum JazzArchiveServerDownloadPlatform {
    static let leaseProvider: any JazzArchiveFilesystemLeaseProvider =
        JazzArchiveFilesystemPlatform.serverDownloadLeaseProvider
}

private struct DarwinCaptureIdentityStoreLeaseProvider:
    CaptureIdentityStoreLeaseProvider
{
    func acquire(
        root: URL,
        fileManager: FileManager
    ) throws -> any CaptureIdentityStoreLease {
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw CaptureIdentityStoreLeaseError.acquisitionFailed
        }
        let lockURL = root.appendingPathComponent(".capture-identity.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CaptureIdentityStoreLeaseError.acquisitionFailed
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            _ = Darwin.close(descriptor)
            throw CaptureIdentityStoreLeaseError.acquisitionFailed
        }
        let apply: (Int32, Int32) -> Int32 = flock
        while apply(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            _ = Darwin.close(descriptor)
            throw CaptureIdentityStoreLeaseError.acquisitionFailed
        }
        return DarwinArchiveFilesystemLease(descriptor: descriptor)
    }
}

private struct DarwinArchiveFilesystemLeaseProvider:
    JazzArchiveFilesystemLeaseProvider
{
    let lockFileName: String

    func acquire(
        root: URL,
        fileManager: FileManager
    ) throws -> any JazzArchiveFilesystemLease {
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw JazzArchiveFilesystemLeaseError.acquisitionFailed
        }
        let lockURL = root.appendingPathComponent(lockFileName)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw JazzArchiveFilesystemLeaseError.acquisitionFailed
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            _ = Darwin.close(descriptor)
            throw JazzArchiveFilesystemLeaseError.acquisitionFailed
        }
        let apply: (Int32, Int32) -> Int32 = flock
        while apply(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            let lockError = errno
            _ = Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw JazzArchiveFilesystemLeaseError.inProgress
            }
            throw JazzArchiveFilesystemLeaseError.acquisitionFailed
        }
        return DarwinArchiveFilesystemLease(descriptor: descriptor)
    }
}

private final class DarwinArchiveFilesystemLease:
    @unchecked Sendable, JazzArchiveFilesystemLease, CaptureIdentityStoreLease
{
    private var descriptor: Int32
    private let mutex = NSLock()

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        let apply: (Int32, Int32) -> Int32 = flock
        while apply(descriptor, LOCK_UN) != 0, errno == EINTR {}
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
