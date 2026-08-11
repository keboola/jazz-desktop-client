import Foundation

public struct JazzArchiveFileFingerprint: Equatable, Sendable {
    public let sha256: String
    public let byteLength: Int64

    public init(sha256: String, byteLength: Int64) {
        self.sha256 = sha256
        self.byteLength = byteLength
    }
}

public struct JazzArchiveVerifiedArtifactFile: Equatable, Sendable {
    public let url: URL
    public let artifact: JazzArchiveArtifact

    public init(url: URL, artifact: JazzArchiveArtifact) {
        self.url = url
        self.artifact = artifact
    }
}

public enum JazzArchiveClaimError: Error, Equatable, CustomStringConvertible {
    case invalidComponent(String)
    case alreadyExists(String)
    case notRegularFile(String)
    case claimChanged(String)
    case fingerprintMismatch(String)

    public var description: String {
        switch self {
        case let .invalidComponent(value): return "Invalid artifact claim component: \(value)"
        case let .alreadyExists(path): return "Artifact claim already exists: \(path)"
        case let .notRegularFile(path): return "Artifact claim is not a regular file: \(path)"
        case let .claimChanged(path): return "Artifact claim changed after it was sealed: \(path)"
        case let .fingerprintMismatch(path): return "Artifact file fingerprint mismatch: \(path)"
        }
    }
}

/// A journal-owned destination prepared before an OS recorder starts writing. Callers never hand
/// an arbitrary mutable temporary URL to ingest: the recorder writes here, then `seal()` atomically
/// renames the file and captures its filesystem identity for the bounded-memory ingest pass.
public struct JazzArchiveWritableFileClaim: Equatable, Sendable {
    public let recordingURL: URL
    private let sealedURL: URL

    public static func prepare(
        root: URL,
        archiveId: String,
        captureId: String,
        artifactId: String,
        fileExtension: String,
        fileManager: FileManager = .default
    ) throws -> Self {
        for component in [archiveId, captureId, artifactId, fileExtension] {
            try validatePathComponent(component)
        }
        let directory = root
            .appendingPathComponent(".artifact-claims", isDirectory: true)
            .appendingPathComponent(archiveId, isDirectory: true)
            .appendingPathComponent(captureId, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let recordingURL = directory.appendingPathComponent(
            "\(artifactId).recording.\(fileExtension)")
        let sealedURL = directory.appendingPathComponent(
            "\(artifactId).\(Identifiers.newUUIDv7().uuidString.lowercased()).sealed.\(fileExtension)")
        guard !fileManager.fileExists(atPath: recordingURL.path),
            !fileManager.fileExists(atPath: sealedURL.path)
        else { throw JazzArchiveClaimError.alreadyExists(recordingURL.path) }
        guard fileManager.createFile(
            atPath: recordingURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        else { throw JazzArchiveClaimError.alreadyExists(recordingURL.path) }
        return Self(recordingURL: recordingURL, sealedURL: sealedURL)
    }

    /// Seal only after the recorder has closed its writer. Rename is within the claim directory,
    /// so the hand-off is atomic; the captured device/inode/size/mtime must remain unchanged until
    /// the archive store has copied and verified the content.
    public func seal(fileManager: FileManager = .default) throws -> JazzArchiveClaimedFile {
        _ = try JazzArchiveFileSnapshot.capture(recordingURL, fileManager: fileManager)
        let handle = try FileHandle(forUpdating: recordingURL)
        try handle.synchronize()
        try handle.close()
        try fileManager.moveItem(at: recordingURL, to: sealedURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o400))],
            ofItemAtPath: sealedURL.path)
        return JazzArchiveClaimedFile(
            url: sealedURL,
            snapshot: try JazzArchiveFileSnapshot.capture(sealedURL, fileManager: fileManager))
    }

    public func abandon(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: recordingURL)
        try? fileManager.removeItem(at: sealedURL)
    }

    private static func validatePathComponent(_ value: String) throws {
        guard !value.isEmpty, value.count <= 160,
            value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        else { throw JazzArchiveClaimError.invalidComponent(value) }
    }
}

/// An immutable-by-contract file capability. Its initializer is intentionally not public: only a
/// journal-owned writable claim can become an ingestible file. The archive store consumes the
/// sealed file after a successful canonical write.
public struct JazzArchiveClaimedFile: Equatable, Sendable {
    public let url: URL
    fileprivate let snapshot: JazzArchiveFileSnapshot

    fileprivate init(url: URL, snapshot: JazzArchiveFileSnapshot) {
        self.url = url
        self.snapshot = snapshot
    }

    func validate(fileManager: FileManager = .default) throws {
        guard try JazzArchiveFileSnapshot.capture(url, fileManager: fileManager) == snapshot else {
            throw JazzArchiveClaimError.claimChanged(url.path)
        }
    }

    public func discard(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }
}

fileprivate struct JazzArchiveFileSnapshot: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var byteLength: Int64
    var modifiedAt: Date

    static func capture(
        _ url: URL,
        fileManager: FileManager
    ) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw JazzArchiveClaimError.notRegularFile(url.path)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            let size = (attributes[.size] as? NSNumber)?.int64Value,
            let modifiedAt = attributes[.modificationDate] as? Date
        else { throw JazzArchiveClaimError.notRegularFile(url.path) }
        return Self(device: device, inode: inode, byteLength: size, modifiedAt: modifiedAt)
    }
}

/// Bounded-memory primitives shared by ingestion, crash recovery, inventory verification, and
/// finalization. No operation here maps or materializes a complete artifact in memory.
public enum JazzArchiveFileIO {
    public static let chunkSize = 64 * 1024

    public static func fingerprint(
        _ url: URL,
        chunkSize: Int = chunkSize
    ) throws -> JazzArchiveFileFingerprint {
        guard chunkSize > 0 else { throw JazzArchiveClaimError.invalidComponent("chunkSize") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw JazzArchiveClaimError.notRegularFile(url.path)
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = JazzArchiveSHA256()
        var byteLength: Int64 = 0
        while true {
            let data = try input.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            byteLength = try Math.adding(byteLength, Int64(data.count), path: url.path)
            hasher.update(data)
        }
        return JazzArchiveFileFingerprint(
            sha256: hasher.finalizeHex(), byteLength: byteLength)
    }

    /// Copy into a sibling temporary file, verify while streaming, then publish with one rename.
    /// If the destination already contains the same fingerprint, the operation is idempotent.
    @discardableResult
    public static func copyAtomically(
        _ source: URL,
        to destination: URL,
        expected: JazzArchiveFileFingerprint? = nil,
        fileManager: FileManager = .default,
        chunkSize: Int = chunkSize
    ) throws -> JazzArchiveFileFingerprint {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).copy-\(Identifiers.newUUIDv7().uuidString.lowercased())")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        else { throw JazzArchiveClaimError.alreadyExists(temporary.path) }
        var keepTemporary = true
        defer { if keepTemporary { try? fileManager.removeItem(at: temporary) } }

        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        var hasher = JazzArchiveSHA256()
        var byteLength: Int64 = 0
        do {
            while true {
                let data = try input.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }
                byteLength = try Math.adding(byteLength, Int64(data.count), path: source.path)
                hasher.update(data)
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            try input.close()
            try output.close()
        } catch {
            try? input.close()
            try? output.close()
            throw error
        }
        let actual = JazzArchiveFileFingerprint(
            sha256: hasher.finalizeHex(), byteLength: byteLength)
        if let expected, actual != expected {
            throw JazzArchiveClaimError.fingerprintMismatch(source.path)
        }
        if fileManager.fileExists(atPath: destination.path) {
            guard try fingerprint(destination, chunkSize: chunkSize) == actual else {
                throw JazzArchiveClaimError.fingerprintMismatch(destination.path)
            }
            return actual
        }
        try fileManager.moveItem(at: temporary, to: destination)
        keepTemporary = false
        return actual
    }

    private enum Math {
        static func adding(_ left: Int64, _ right: Int64, path: String) throws -> Int64 {
            let (value, overflow) = left.addingReportingOverflow(right)
            guard !overflow else { throw JazzArchiveClaimError.fingerprintMismatch(path) }
            return value
        }
    }
}

/// Incremental SHA-256 implementation kept Foundation-only so the portable capture core has no
/// platform crypto dependency. The pending buffer is exactly one 64-byte compression block.
struct JazzArchiveSHA256 {
    private var hash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var pending: [UInt8] = []
    private var words = [UInt32](repeating: 0, count: 64)
    private var totalBytes: UInt64 = 0

    init() { pending.reserveCapacity(64) }

    @_optimize(speed)
    mutating func update(_ data: Data) {
        totalBytes &+= UInt64(data.count)
        var offset = 0
        while offset < data.count {
            let end = min(offset + JazzArchiveFileIO.chunkSize, data.count)
            let startIndex = data.index(data.startIndex, offsetBy: offset)
            let endIndex = data.index(data.startIndex, offsetBy: end)
            let bytes = Array(data[startIndex..<endIndex])
            var byteIndex = 0
            if !pending.isEmpty {
                let needed = min(64 - pending.count, bytes.count)
                pending.append(contentsOf: bytes[0..<needed])
                byteIndex = needed
                if pending.count == 64 {
                    compress(pending, offset: 0)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            while byteIndex + 64 <= bytes.count {
                compress(bytes, offset: byteIndex)
                byteIndex += 64
            }
            if byteIndex < bytes.count { pending.append(contentsOf: bytes[byteIndex...]) }
            offset = end
        }
    }

    @_optimize(speed)
    mutating func finalizeHex() -> String {
        let bitLength = totalBytes &* 8
        pending.append(0x80)
        if pending.count > 56 {
            while pending.count < 64 { pending.append(0) }
            compress(pending, offset: 0)
            pending.removeAll(keepingCapacity: true)
        }
        while pending.count < 56 { pending.append(0) }
        var shift = 56
        while shift >= 0 {
            pending.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
            shift -= 8
        }
        compress(pending, offset: 0)
        pending.removeAll(keepingCapacity: true)
        return hash.map { String(format: "%08x", $0) }.joined()
    }

    @_optimize(speed)
    private mutating func compress(_ block: [UInt8], offset: Int) {
        precondition(offset >= 0 && offset + 64 <= block.count)
        var index = 0
        while index < 16 {
            let start = offset + index * 4
            words[index] = UInt32(block[start]) << 24
                | UInt32(block[start + 1]) << 16
                | UInt32(block[start + 2]) << 8
                | UInt32(block[start + 3])
            index += 1
        }
        index = 16
        while index < 64 {
            let s0 = Self.rotateRight(words[index - 15], by: 7)
                ^ Self.rotateRight(words[index - 15], by: 18) ^ (words[index - 15] >> 3)
            let s1 = Self.rotateRight(words[index - 2], by: 17)
                ^ Self.rotateRight(words[index - 2], by: 19) ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            index += 1
        }
        var a = hash[0]
        var b = hash[1]
        var c = hash[2]
        var d = hash[3]
        var e = hash[4]
        var f = hash[5]
        var g = hash[6]
        var h = hash[7]
        index = 0
        while index < 64 {
            let sum1 = Self.rotateRight(e, by: 6) ^ Self.rotateRight(e, by: 11)
                ^ Self.rotateRight(e, by: 25)
            let choose = (e & f) ^ ((~e) & g)
            let temp1 = h &+ sum1 &+ choose &+ Self.constants[index] &+ words[index]
            let sum0 = Self.rotateRight(a, by: 2) ^ Self.rotateRight(a, by: 13)
                ^ Self.rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = sum0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
            index += 1
        }
        hash[0] &+= a
        hash[1] &+= b
        hash[2] &+= c
        hash[3] &+= d
        hash[4] &+= e
        hash[5] &+= f
        hash[6] &+= g
        hash[7] &+= h
    }

    @inline(__always)
    private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
}
