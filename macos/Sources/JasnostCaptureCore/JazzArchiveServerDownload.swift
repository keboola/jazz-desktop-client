import Foundation

public struct JazzArchiveServerScope: Codable, Equatable, Sendable {
    public var companyId: String
    public var areaId: String
    public var deviceId: String

    public init(companyId: String, areaId: String, deviceId: String) {
        self.companyId = companyId
        self.areaId = areaId
        self.deviceId = deviceId
    }
}

public struct JazzArchiveServerDownloadRequest: Codable, Equatable, Sendable {
    public var ingestId: String
    public var scope: JazzArchiveServerScope

    public init(ingestId: String, scope: JazzArchiveServerScope) {
        self.ingestId = ingestId
        self.scope = scope
    }
}

public struct JazzArchiveServerDownloadPrincipal: Codable, Equatable, Sendable {
    public var principalId: String
    public var tenantId: String
    public var companyId: String
    public var areaId: String
    public var deviceId: String
    public var basis: String
}

/// Exact response mirror of `POST /api/archive-ingests/{ingestId}/download-grants`. `download`
/// remains a lossless opaque JSON object and is memory-only.
public struct JazzArchiveServerDownloadGrant: Codable, Equatable, Sendable {
    public var ingestId: String
    public var archiveId: String
    public var formatVersion: Int
    public var contentDigest: String
    public var rawSha256: String
    public var byteLength: Int64
    public var downloadAuthorizationId: String
    public var grantExpiresAt: String
    public var requestedBy: JazzArchiveServerDownloadPrincipal
    public var download: [String: JazzArchiveJSONValue]

    public init(
        ingestId: String,
        archiveId: String,
        formatVersion: Int,
        contentDigest: String,
        rawSha256: String,
        byteLength: Int64,
        downloadAuthorizationId: String,
        grantExpiresAt: String,
        requestedBy: JazzArchiveServerDownloadPrincipal,
        download: [String: JazzArchiveJSONValue]
    ) {
        self.ingestId = ingestId
        self.archiveId = archiveId
        self.formatVersion = formatVersion
        self.contentDigest = contentDigest
        self.rawSha256 = rawSha256
        self.byteLength = byteLength
        self.downloadAuthorizationId = downloadAuthorizationId
        self.grantExpiresAt = grantExpiresAt
        self.requestedBy = requestedBy
        self.download = download
    }
}

/// Pull-based raw-body stream. The coordinator owns all filesystem writes and byte limits, so a
/// transport implementation cannot make the importer parse a partial response.
public protocol JazzArchiveServerDownloadBody: Sendable {
    func nextChunk() async throws -> Data?
}

public protocol JazzArchiveServerDownloadTransport: Sendable {
    func authorize(
        _ request: JazzArchiveServerDownloadRequest
    ) async throws -> JazzArchiveServerDownloadGrant

    func openBody(
        for grant: JazzArchiveServerDownloadGrant
    ) async throws -> any JazzArchiveServerDownloadBody
}

public enum JazzArchiveServerDownloadError: Error, Equatable, CustomStringConvertible {
    case invalidRequest
    case invalidGrant(String)
    case grantExpired
    case bodyTooLarge
    case bodyFingerprintMismatch
    case writeFailed

    public var description: String {
        switch self {
        case .invalidRequest: return "Jazz server archive download request is invalid"
        case let .invalidGrant(field): return "Jazz server archive download grant is invalid: \(field)"
        case .grantExpired: return "Jazz server archive download grant expired"
        case .bodyTooLarge: return "Jazz server archive download exceeded its declared limit"
        case .bodyFingerprintMismatch:
            return "Jazz server archive download bytes do not match the READY publication"
        case .writeFailed: return "Jazz server archive download could not be sealed locally"
        }
    }
}

/// Authorized server import path. It downloads opaque bytes into a private claim, seals and
/// fingerprints the complete file, then hands that exact file plus all expected identities to the
/// normal strict importer. ZIP/manifest parsing never occurs while the network body is arriving.
public actor JazzArchiveServerImportCoordinator {
    private let root: URL
    private let importer: JazzArchiveImporter
    private let transport: any JazzArchiveServerDownloadTransport
    private let maximumBytes: Int64
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    public init(
        root: URL,
        importer: JazzArchiveImporter,
        transport: any JazzArchiveServerDownloadTransport,
        maximumBytes: Int64 = 2 * 1024 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.importer = importer
        self.transport = transport
        self.maximumBytes = maximumBytes
        self.now = now
        self.fileManager = fileManager
    }

    public func importReadyArchive(
        _ request: JazzArchiveServerDownloadRequest,
        importedAt: String = Timestamps.iso8601(),
        context: JazzArchiveImportContext
    ) async throws -> JazzArchiveImportResult {
        try validate(request)
        let grant = try await transport.authorize(request)
        try validate(grant, request: request)

        let claimDirectory = root.appendingPathComponent(
            ".server-download-\(Identifiers.newUUIDv7().uuidString.lowercased())",
            isDirectory: true)
        try fileManager.createDirectory(
            at: claimDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        var keepClaim = true
        defer {
            if keepClaim {
                try? fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o700))],
                    ofItemAtPath: claimDirectory.path)
                try? fileManager.removeItem(at: claimDirectory)
            }
        }
        let packageURL = claimDirectory.appendingPathComponent(
            "\(grant.archiveId).jazz-archive")
        guard fileManager.createFile(
            atPath: packageURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        else { throw JazzArchiveServerDownloadError.writeFailed }

        let body = try await transport.openBody(for: grant)
        let output = try FileHandle(forWritingTo: packageURL)
        var written: Int64 = 0
        do {
            while let chunk = try await body.nextChunk() {
                if chunk.isEmpty { continue }
                let (next, overflow) = written.addingReportingOverflow(Int64(chunk.count))
                guard !overflow, next <= grant.byteLength, next <= maximumBytes else {
                    throw JazzArchiveServerDownloadError.bodyTooLarge
                }
                try output.write(contentsOf: chunk)
                written = next
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
        guard written == grant.byteLength else {
            throw JazzArchiveServerDownloadError.bodyFingerprintMismatch
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o400))],
            ofItemAtPath: packageURL.path)
        let fingerprint = try JazzArchiveFileIO.fingerprint(packageURL)
        guard fingerprint.sha256 == grant.rawSha256,
            fingerprint.byteLength == grant.byteLength
        else { throw JazzArchiveServerDownloadError.bodyFingerprintMismatch }

        let serverContext = JazzArchiveImportContext(
            importedBy: JazzArchiveExternalIdentity(
                namespace: "jazz.authenticated-principal-id",
                value: grant.requestedBy.principalId),
            importingOriginId: context.importingOriginId,
            importingSourceId: context.importingSourceId,
            importingDevice: JazzArchiveExternalIdentity(
                namespace: "jazz.enrolled-device-id",
                value: grant.requestedBy.deviceId),
            acquisition: .jazzServerDownload)
        let result = try await importer.importArchive(
            at: packageURL,
            importedAt: importedAt,
            context: serverContext,
            expectedPackageFingerprint: fingerprint,
            expectedArchiveId: grant.archiveId,
            expectedContentDigest: grant.contentDigest)
        keepClaim = false
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: claimDirectory.path)
        try? fileManager.removeItem(at: claimDirectory)
        return result
    }

    private func validate(_ request: JazzArchiveServerDownloadRequest) throws {
        guard !request.ingestId.isEmpty,
            !request.scope.companyId.isEmpty,
            !request.scope.areaId.isEmpty,
            !request.scope.deviceId.isEmpty,
            maximumBytes > 0
        else { throw JazzArchiveServerDownloadError.invalidRequest }
    }

    private func validate(
        _ grant: JazzArchiveServerDownloadGrant,
        request: JazzArchiveServerDownloadRequest
    ) throws {
        guard grant.formatVersion == 1 else {
            throw JazzArchiveServerDownloadError.invalidGrant("formatVersion")
        }
        guard !grant.downloadAuthorizationId.isEmpty,
            !grant.requestedBy.principalId.isEmpty,
            !grant.requestedBy.tenantId.isEmpty
        else {
            throw JazzArchiveServerDownloadError.invalidGrant("authorization")
        }
        guard grant.ingestId == request.ingestId,
            grant.requestedBy.companyId == request.scope.companyId,
            grant.requestedBy.areaId == request.scope.areaId,
            grant.requestedBy.deviceId == request.scope.deviceId,
            grant.requestedBy.basis == "authenticated_control_plane",
            isArchiveId(grant.archiveId)
        else { throw JazzArchiveServerDownloadError.invalidGrant("binding") }
        guard case let .string(transport)? = grant.download["transport"],
            !transport.isEmpty,
            !containsInternalLocatorKey(.object(grant.download))
        else { throw JazzArchiveServerDownloadError.invalidGrant("download") }
        guard grant.byteLength > 0, grant.byteLength <= maximumBytes else {
            throw JazzArchiveServerDownloadError.invalidGrant("byteLength")
        }
        for (digest, field) in [
            (grant.contentDigest, "contentDigest"),
            (grant.rawSha256, "rawSha256"),
        ] where digest.count != 64
            || !digest.allSatisfy({ "0123456789abcdef".contains($0) })
        {
            throw JazzArchiveServerDownloadError.invalidGrant(field)
        }
        guard let expires = Timestamps.parse(grant.grantExpiresAt) else {
            throw JazzArchiveServerDownloadError.invalidGrant("grantExpiresAt")
        }
        guard expires > now() else { throw JazzArchiveServerDownloadError.grantExpired }
    }

    private func isArchiveId(_ value: String) -> Bool {
        guard value.hasPrefix("ar-") else { return false }
        let raw = String(value.dropFirst(3))
        guard let uuid = UUID(uuidString: raw),
            uuid.uuidString.lowercased() == raw
        else { return false }
        let characters = Array(raw)
        return characters.count == 36
            && characters[14] == "7"
            && "89ab".contains(characters[19])
    }

    private func containsInternalLocatorKey(_ value: JazzArchiveJSONValue) -> Bool {
        switch value {
        case let .object(object):
            let forbidden = Set(["objectkey", "internalobjectkey", "versionid", "etag"])
            return object.contains {
                forbidden.contains(
                    $0.key.lowercased().filter { $0.isLetter || $0.isNumber }
                )
                    || containsInternalLocatorKey($0.value)
            }
        case let .array(values):
            return values.contains(where: containsInternalLocatorKey)
        default:
            return false
        }
    }
}
