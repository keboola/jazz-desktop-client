import CryptoKit
import Darwin
import Foundation
import JazzCaptureCore

/// Read-only, bounded bridge from an already sealed artifact and already prepared GCS File grant.
/// Never prepares/deletes a File, creates a spool/temp file, or changes the source artifact.
/// This is not grant issuance/Company authorization; S3 must supply those before any activation.
enum BestEffortFileEncoder {
    enum Failure: Error { case invalidGrant, invalidArtifact, changedArtifact }

    static func preparedGCS(
        file: URL, expectedBytes: Int, sha256: String,
        params: KeboolaAPI.FilesPrepare.GCSUploadParams, contentType: String,
        expiresAt: TimeInterval
    ) throws -> BestEffortTransportDriver.Media {
        guard file.isFileURL, expectedBytes > 0, expectedBytes <= 256 * 1024 * 1024,
            sha256.utf8.count == 64,
            sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            expiresAt.isFinite
        else { throw Failure.invalidArtifact }
        let request = try putRequest(params: params, contentType: contentType)
        return .init(request: request, maximumBytes: expectedBytes, expiresAt: expiresAt) {
            limit, cancelled in
            try read(
                file: file, expectedBytes: expectedBytes, sha256: sha256, limit: limit,
                cancelled: cancelled)
        }
    }

    /// Also used by in-memory encoders; obtaining a GCS request never requires a temporary file.
    static func putRequest(params: KeboolaAPI.FilesPrepare.GCSUploadParams, contentType: String)
        throws -> URLRequest
    {
        guard (3...222).contains(params.bucket.utf8.count),
            params.bucket.utf8.allSatisfy({
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
            }),
            !params.key.isEmpty, params.key.utf8.count <= 4096,
            !params.key.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0 == "." || $0 == ".."
            }),
            !params.accessToken.isEmpty, params.accessToken.utf8.count <= 8192,
            !contentType.isEmpty, contentType.utf8.count <= 128,
            [params.key, params.accessToken, contentType].allSatisfy({
                $0.utf8.allSatisfy { $0 >= 32 && $0 != 127 }
            })
        else { throw Failure.invalidGrant }
        var components = URLComponents(string: "https://storage.googleapis.com")!
        components.path = "/\(params.bucket)/\(params.key)"
        guard let url = components.url else { throw Failure.invalidGrant }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(params.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    static func read(
        file: URL, expectedBytes: Int, sha256: String, limit: Int,
        cancelled: () -> Bool
    ) throws -> Data {
        guard expectedBytes > 0, expectedBytes <= limit, !cancelled() else {
            throw Failure.invalidArtifact
        }
        // Descriptor check, not a path check followed by a raceable open. FIFOs/devices/symlink
        // substitutions cannot become hidden blocking producers. Intermediate links may resolve,
        // but exact expected length+digest still bind bytes; this function only ever reads.
        let descriptor = file.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw Failure.invalidArtifact }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size == expectedBytes
        else { throw Failure.invalidArtifact }
        var data = Data()
        while data.count < expectedBytes {
            guard !cancelled() else { throw CancellationError() }
            guard
                let chunk = try handle.read(upToCount: min(64 * 1024, expectedBytes - data.count)),
                !chunk.isEmpty
            else { throw Failure.changedArtifact }
            data.append(chunk)
        }
        guard !cancelled(), (try handle.read(upToCount: 1))?.isEmpty != false,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256
        else { throw Failure.changedArtifact }
        return data
    }
}
