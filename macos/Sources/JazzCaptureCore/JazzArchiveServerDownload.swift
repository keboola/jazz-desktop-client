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
    public var downloadOperationId: String

    public init(
        ingestId: String,
        scope: JazzArchiveServerScope,
        downloadOperationId: String
    ) {
        self.ingestId = ingestId
        self.scope = scope
        self.downloadOperationId = downloadOperationId
    }

    /// Exact flat control-plane body. `ingestId` remains exclusively in the route.
    public func canonicalAuthorizationBody() throws -> Data {
        let body: JazzArchiveJSONValue = .object([
            "companyId": .string(scope.companyId),
            "areaId": .string(scope.areaId),
            "deviceId": .string(scope.deviceId),
            "downloadOperationId": .string(downloadOperationId),
        ])
        return try JazzArchiveCanonicalJSON.encode(body)
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
/// decodes losslessly but must match the strict memory-only `http-get/v1` profile before use.
public struct JazzArchiveServerDownloadGrant: Codable, Equatable, Sendable {
    public var ingestId: String
    public var archiveId: String
    public var formatVersion: Int
    public var contentDigest: String
    public var rawSha256: String
    public var byteLength: Int64
    public var downloadOperationId: String
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
        downloadOperationId: String,
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
        self.downloadOperationId = downloadOperationId
        self.downloadAuthorizationId = downloadAuthorizationId
        self.grantExpiresAt = grantExpiresAt
        self.requestedBy = requestedBy
        self.download = download
    }
}

/// Strict, provider-neutral `http-get/v1` profile. Provider request headers are deliberately not
/// supported: possession of the bounded signed HTTPS URL is the complete data-plane authority.
public struct JazzArchiveServerDownloadInstructions: Equatable, Sendable {
    public static let transport = "http-get/v1"
    public static let maximumURLBytes = 16_384

    public let url: URL

    public init(download: [String: JazzArchiveJSONValue]) throws {
        guard Set(download.keys) == Set(["transport", "method", "url"]),
            download["transport"] == .string(Self.transport),
            download["method"] == .string("GET"),
            case let .string(rawURL)? = download["url"],
            !rawURL.isEmpty,
            rawURL.utf8.count <= Self.maximumURLBytes,
            rawURL == rawURL.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.contains("\\"),
            !rawURL.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            }),
            let components = URLComponents(string: rawURL),
            components.scheme?.lowercased() == "https",
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            components.fragment == nil,
            components.port.map({ (1...65_535).contains($0) }) ?? true,
            let url = components.url
        else {
            throw JazzArchiveServerDownloadError.invalidGrant("download")
        }
        self.url = url
    }
}

/// Recognizes only the mixed-rollout response produced when an older FastAPI replica treats the
/// durable `downloadOperationId` field as forbidden. This classification never authorizes a
/// legacy retry without the field; it only tells the caller that the exact journaled operation can
/// be retried after the server fleet is upgraded.
public enum JazzArchiveServerDownloadCompatibility {
    public static func isLegacyOperationIdRejection(
        statusCode: Int,
        responseBody: Data,
        expectedOperationId: String
    ) -> Bool {
        guard statusCode == 422,
            !responseBody.isEmpty,
            responseBody.count <= 64 * 1_024,
            let envelope = try? JSONSerialization.jsonObject(with: responseBody),
            let object = envelope as? [String: Any],
            Set(object.keys) == Set(["detail"]),
            let details = object["detail"] as? [Any],
            details.count == 1,
            let detail = details[0] as? [String: Any],
            detail["type"] as? String == "extra_forbidden",
            let location = detail["loc"] as? [String],
            location == ["body", "downloadOperationId"],
            detail["input"] as? String == expectedOperationId
        else { return false }
        return true
    }
}

/// Pull-based raw-body stream. The coordinator owns all filesystem writes and byte limits, so a
/// transport implementation cannot make the importer parse a partial response.
public protocol JazzArchiveServerDownloadBody: Sendable {
    func nextChunk() async throws -> Data?
}

public protocol JazzArchiveServerDownloadTransport: Sendable {
    /// Authenticated, non-secret route authority bound into the local operation journal before a
    /// credential read. Token/bundle rotation may preserve this authority; issuer, audience,
    /// endpoint, stack, project, or scope changes may not.
    var routeBinding: JazzArchiveUploadRouteBinding { get }

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
    case operationJournalCorrupt
    case operationJournalBindingConflict
    case operationJournalWriteFailed
    case operationInProgress
    case operationAbandoned
    case noPendingOperation
    case staleClaimUnsafe
    case serverUpgradeRequired

    public var description: String {
        switch self {
        case .invalidRequest: return "Jazz server archive download request is invalid"
        case let .invalidGrant(field): return "Jazz server archive download grant is invalid: \(field)"
        case .grantExpired: return "Jazz server archive download grant expired"
        case .bodyTooLarge: return "Jazz server archive download exceeded its declared limit"
        case .bodyFingerprintMismatch:
            return "Jazz server archive download bytes do not match the READY publication"
        case .writeFailed: return "Jazz server archive download could not be sealed locally"
        case .operationJournalCorrupt:
            return "Jazz server archive download operation journal is corrupt"
        case .operationJournalBindingConflict:
            return "Jazz server archive download operation journal belongs to another import"
        case .operationJournalWriteFailed:
            return "Jazz server archive download operation journal could not be persisted"
        case .operationInProgress:
            return "Another Jazz server archive download operation is already running"
        case .operationAbandoned:
            return "This Jazz server archive download operation was deliberately abandoned"
        case .noPendingOperation:
            return "No pending Jazz server archive download operation exists"
        case .staleClaimUnsafe:
            return "A stale Jazz server download claim has an unsafe filesystem shape"
        case .serverUpgradeRequired:
            return "Jazz server must be upgraded before this durable download can be retried"
        }
    }
}

/// Non-secret projection of the one durable server download that may be resumed or explicitly
/// abandoned. Signed URLs, provider headers, and authorization credentials never enter this value.
public struct JazzArchiveServerDownloadPendingOperation: Codable, Equatable, Sendable {
    public let downloadOperationId: String
    public let authorityBinding: String
    public let routeBinding: JazzArchiveUploadRouteBinding?
    public let ingestId: String
    public let scope: JazzArchiveServerScope
    public let importTargetPath: String
    public let createdAt: String
}

/// Append-only explanation for an explicit user decision to stop retrying one durable operation.
/// This is acquisition audit metadata only; abandoning never removes an imported package, snapshot,
/// receipt, or any other archive evidence.
public struct JazzArchiveServerDownloadAbandonment: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let abandonmentId: String
    public let downloadOperationId: String
    public let authorityBinding: String
    public let routeBinding: JazzArchiveUploadRouteBinding?
    public let ingestId: String
    public let scope: JazzArchiveServerScope
    public let importTargetPath: String
    public let operationCreatedAt: String
    public let abandonedAt: String
    public let reason: String
}

/// Non-secret durable intent written before the first authorization request. Short-lived grant
/// material is intentionally absent: relaunch recovery reauthorizes this exact operation instead
/// of persisting a signed provider URL.
fileprivate struct JazzArchiveServerDownloadIntent: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let downloadOperationId: String
    let authorityBinding: String
    let routeBinding: JazzArchiveUploadRouteBinding?
    let ingestId: String
    let companyId: String
    let areaId: String
    let deviceId: String
    let importTargetPath: String
    let createdAt: String

    init(
        request: JazzArchiveServerDownloadRequest,
        routeBinding: JazzArchiveUploadRouteBinding,
        importTargetPath: String,
        createdAt: String
    ) {
        self.schemaVersion = 2
        self.downloadOperationId = request.downloadOperationId
        self.authorityBinding = routeBinding.ingestEndpoint
        self.routeBinding = routeBinding
        self.ingestId = request.ingestId
        self.companyId = request.scope.companyId
        self.areaId = request.scope.areaId
        self.deviceId = request.scope.deviceId
        self.importTargetPath = importTargetPath
        self.createdAt = createdAt
    }

    func validate() throws {
        guard [1, 2].contains(schemaVersion),
            Self.isUUIDv7(downloadOperationId, prefix: "dop"),
            JazzArchiveControlPlaneURL.normalize(authorityBinding) == authorityBinding,
            Self.isRouteComponent(ingestId, maximumBytes: 256),
            Self.isCanonicalText(companyId, maximumBytes: 256),
            Self.isCanonicalText(areaId, maximumBytes: 256),
            Self.isCanonicalText(deviceId, maximumBytes: 256),
            importTargetPath.hasPrefix("/"),
            importTargetPath.utf8.count <= 4_096,
            URL(fileURLWithPath: importTargetPath, isDirectory: true)
                .standardizedFileURL.path == importTargetPath,
            Timestamps.parse(createdAt) != nil,
            Self.validRouteSnapshot(
                schemaVersion: schemaVersion,
                routeBinding: routeBinding,
                authorityBinding: authorityBinding,
                companyId: companyId,
                areaId: areaId,
                deviceId: deviceId)
        else { throw JazzArchiveServerDownloadError.operationJournalCorrupt }
    }

    func binds(
        request: JazzArchiveServerDownloadRequest,
        routeBinding currentRoute: JazzArchiveUploadRouteBinding,
        importTargetPath: String
    ) -> Bool {
        guard schemaVersion == 2,
            let routeBinding,
            routeBinding.hasSameDeliveryAuthority(as: currentRoute),
            Self.routeScope(currentRoute)
                == (
                    request.scope.companyId,
                    request.scope.areaId,
                    request.scope.deviceId
                )
        else { return false }
        return authorityBinding == currentRoute.ingestEndpoint
            && ingestId == request.ingestId
            && companyId == request.scope.companyId
            && areaId == request.scope.areaId
            && deviceId == request.scope.deviceId
            && self.importTargetPath == importTargetPath
    }

    var pendingOperation: JazzArchiveServerDownloadPendingOperation {
        JazzArchiveServerDownloadPendingOperation(
            downloadOperationId: downloadOperationId,
            authorityBinding: authorityBinding,
            routeBinding: routeBinding,
            ingestId: ingestId,
            scope: JazzArchiveServerScope(
                companyId: companyId,
                areaId: areaId,
                deviceId: deviceId),
            importTargetPath: importTargetPath,
            createdAt: createdAt)
    }

    func abandonment(
        abandonmentId: String,
        abandonedAt: String,
        reason: String
    ) -> JazzArchiveServerDownloadAbandonment {
        JazzArchiveServerDownloadAbandonment(
            schemaVersion: schemaVersion,
            abandonmentId: abandonmentId,
            downloadOperationId: downloadOperationId,
            authorityBinding: authorityBinding,
            routeBinding: routeBinding,
            ingestId: ingestId,
            scope: JazzArchiveServerScope(
                companyId: companyId,
                areaId: areaId,
                deviceId: deviceId),
            importTargetPath: importTargetPath,
            operationCreatedAt: createdAt,
            abandonedAt: abandonedAt,
            reason: reason)
    }

    fileprivate static func validRouteSnapshot(
        schemaVersion: Int,
        routeBinding: JazzArchiveUploadRouteBinding?,
        authorityBinding: String,
        companyId: String,
        areaId: String,
        deviceId: String
    ) -> Bool {
        switch (schemaVersion, routeBinding) {
        case (1, nil):
            // Pre-snapshot journals remain inspectable and abandonable, but `binds` deliberately
            // refuses to resume them because their signed authority was never committed.
            return true
        case (2, let routeBinding?):
            return routeBinding.hasSignedAuthority
                && routeBinding.ingestEndpoint == authorityBinding
                && routeScope(routeBinding) == (companyId, areaId, deviceId)
        default:
            return false
        }
    }

    private static func routeScope(
        _ routeBinding: JazzArchiveUploadRouteBinding
    ) -> (String, String, String) {
        (
            routeBinding.scope.companyId,
            routeBinding.scope.areaId,
            routeBinding.scope.deviceId
        )
    }

    private static func isCanonicalText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func isRouteComponent(_ value: String, maximumBytes: Int) -> Bool {
        value.utf8.count <= maximumBytes
            && value.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression) != nil
    }

    fileprivate static func isUUIDv7(_ value: String, prefix: String) -> Bool {
        let marker = "\(prefix)-"
        guard value.hasPrefix(marker) else { return false }
        let raw = String(value.dropFirst(marker.count))
        guard let uuid = UUID(uuidString: raw),
            uuid.uuidString.lowercased() == raw
        else { return false }
        let characters = Array(raw)
        return characters.count == 36
            && characters[14] == "7"
            && "89ab".contains(characters[19])
    }
}

fileprivate final class JazzArchiveServerDownloadIntentStore {
    static let directoryName = ".server-download-intent"
    private static let documentName = "intent.json"
    private static let historyDirectoryName = ".server-download-history"
    private static let maximumDocumentBytes = 32 * 1_024
    private static let maximumReasonBytes = 1_024

    private let root: URL
    private let importTargetPath: String
    private let fileManager: FileManager
    private let durability: JazzArchiveFilesystemDurability

    init(
        root: URL,
        importTargetRoot: URL,
        fileManager: FileManager,
        durability: JazzArchiveFilesystemDurability
    ) {
        self.root = root.standardizedFileURL
        self.importTargetPath = importTargetRoot.standardizedFileURL.path
        self.fileManager = fileManager
        self.durability = durability
    }

    func begin(
        request: JazzArchiveServerDownloadRequest,
        routeBinding: JazzArchiveUploadRouteBinding,
        createdAt: String
    ) throws -> JazzArchiveServerDownloadIntent {
        let proposed = JazzArchiveServerDownloadIntent(
            request: request,
            routeBinding: routeBinding,
            importTargetPath: importTargetPath,
            createdAt: createdAt)
        try proposed.validate()
        if try abandonment(downloadOperationId: proposed.downloadOperationId) != nil {
            throw JazzArchiveServerDownloadError.operationAbandoned
        }
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            if fileManager.fileExists(atPath: activeDirectory.path) {
                let stored = try boundIntent(
                    request: request,
                    routeBinding: routeBinding)
                try synchronizeActiveIntentDurably()
                return stored
            }

            let staging = root.appendingPathComponent(
                ".server-download-intent-\(Identifiers.newUUIDv7().uuidString.lowercased())",
                isDirectory: true)
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            var keepStaging = true
            defer {
                if keepStaging {
                    try? fileManager.setAttributes(
                        [.posixPermissions: NSNumber(value: Int16(0o700))],
                        ofItemAtPath: staging.path)
                    try? fileManager.removeItem(at: staging)
                }
            }
            let documentURL = staging.appendingPathComponent(Self.documentName)
            let data = try JazzArchiveCanonicalJSON.encode(proposed)
            guard data.count <= Self.maximumDocumentBytes else {
                throw JazzArchiveServerDownloadError.operationJournalCorrupt
            }
            try data.write(to: documentURL, options: [.atomic])
            try synchronizeRegularFile(
                documentURL,
                permissions: Int16(0o400))
            try synchronizeDirectory(staging)
            do {
                try fileManager.moveItem(at: staging, to: activeDirectory)
            } catch {
                guard fileManager.fileExists(atPath: activeDirectory.path) else {
                    throw JazzArchiveServerDownloadError.operationJournalWriteFailed
                }
                let stored = try boundIntent(
                    request: request,
                    routeBinding: routeBinding)
                try synchronizeActiveIntentDurably()
                return stored
            }
            keepStaging = false
            try synchronizeDirectory(root)
            try synchronizeDirectory(root.deletingLastPathComponent())
            return try boundIntent(
                request: request,
                routeBinding: routeBinding)
        } catch let error as JazzArchiveServerDownloadError {
            throw error
        } catch {
            throw JazzArchiveServerDownloadError.operationJournalWriteFailed
        }
    }

    func pendingOperation() throws -> JazzArchiveServerDownloadPendingOperation? {
        guard fileManager.fileExists(atPath: activeDirectory.path) else { return nil }
        return try load().pendingOperation
    }

    func abandonment(
        downloadOperationId: String
    ) throws -> JazzArchiveServerDownloadAbandonment? {
        guard JazzArchiveServerDownloadIntent.isUUIDv7(
            downloadOperationId,
            prefix: "dop")
        else { throw JazzArchiveServerDownloadError.invalidRequest }
        let url = abandonmentURL(downloadOperationId: downloadOperationId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try loadAbandonment(at: url)
    }

    func abandon(
        downloadOperationId: String,
        abandonedAt: String,
        reason: String
    ) throws -> JazzArchiveServerDownloadAbandonment {
        let canonicalReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalReason.isEmpty,
            canonicalReason == reason,
            canonicalReason.utf8.count <= Self.maximumReasonBytes,
            !canonicalReason.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }),
            Timestamps.parse(abandonedAt) != nil
        else { throw JazzArchiveServerDownloadError.invalidRequest }

        if let existing = try abandonment(downloadOperationId: downloadOperationId) {
            if fileManager.fileExists(atPath: activeDirectory.path) {
                let stored = try load()
                guard stored.downloadOperationId == downloadOperationId,
                    existing == stored.abandonment(
                        abandonmentId: existing.abandonmentId,
                        abandonedAt: existing.abandonedAt,
                        reason: existing.reason)
                else {
                    throw JazzArchiveServerDownloadError.operationJournalBindingConflict
                }
                try synchronizeAbandonmentDurably(existing)
                try removeActiveDirectoryDurably()
            } else {
                try synchronizeAbandonmentDurably(existing)
            }
            return existing
        }

        guard fileManager.fileExists(atPath: activeDirectory.path) else {
            throw JazzArchiveServerDownloadError.noPendingOperation
        }
        let stored = try load()
        guard stored.downloadOperationId == downloadOperationId else {
            throw JazzArchiveServerDownloadError.operationJournalBindingConflict
        }
        let record = stored.abandonment(
            abandonmentId:
                "dab-\(Identifiers.newUUIDv7().uuidString.lowercased())",
            abandonedAt: abandonedAt,
            reason: canonicalReason)
        try validate(record)
        try persist(record)
        try removeActiveDirectoryDurably()
        return record
    }

    /// The operation lock proves that no live coordinator owns a claim. Only the exact UUID-shaped
    /// claim directories created by this coordinator are eligible; journal/history/lock paths and
    /// unexpected files or symlinks are never traversed or deleted.
    @discardableResult
    func reapStaleClaims() throws -> Int {
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        let candidates = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [])
        var removed = 0
        for candidate in candidates where Self.isClaimDirectoryName(candidate.lastPathComponent) {
            let values = try candidate.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw JazzArchiveServerDownloadError.staleClaimUnsafe
            }
            let children = try fileManager.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: [])
            guard children.count <= 1 else {
                throw JazzArchiveServerDownloadError.staleClaimUnsafe
            }
            for child in children {
                let childValues = try child.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard childValues.isRegularFile == true,
                    childValues.isSymbolicLink != true,
                    child.pathExtension == "jazz-archive",
                    !child.lastPathComponent.contains("/"),
                    !child.lastPathComponent.contains("\\")
                else {
                    throw JazzArchiveServerDownloadError.staleClaimUnsafe
                }
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: child.path)
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: candidate.path)
            try fileManager.removeItem(at: candidate)
            removed += 1
        }
        if removed > 0 {
            try synchronizeDirectory(root)
        }
        return removed
    }

    func complete(_ expected: JazzArchiveServerDownloadIntent) throws {
        do {
            // Called only while the cross-process operation lease is held and after the importer
            // durably published the exact verified archive. Missing therefore means a prior
            // idempotent completion won the same operation, not permission to complete a new one.
            guard fileManager.fileExists(atPath: activeDirectory.path) else { return }
            let stored = try load()
            guard stored == expected else {
                throw JazzArchiveServerDownloadError.operationJournalBindingConflict
            }
            try removeActiveDirectoryDurably()
        } catch let error as JazzArchiveServerDownloadError {
            throw error
        } catch {
            throw JazzArchiveServerDownloadError.operationJournalWriteFailed
        }
    }

    private func boundIntent(
        request: JazzArchiveServerDownloadRequest,
        routeBinding: JazzArchiveUploadRouteBinding
    ) throws -> JazzArchiveServerDownloadIntent {
        let stored = try load()
        if try abandonment(downloadOperationId: stored.downloadOperationId) != nil {
            throw JazzArchiveServerDownloadError.operationAbandoned
        }
        guard stored.binds(
            request: request,
            routeBinding: routeBinding,
            importTargetPath: importTargetPath)
        else {
            throw JazzArchiveServerDownloadError.operationJournalBindingConflict
        }
        return stored
    }

    private func load() throws -> JazzArchiveServerDownloadIntent {
        do {
            let directoryValues = try activeDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directoryValues.isDirectory == true,
                directoryValues.isSymbolicLink != true,
                try Set(fileManager.contentsOfDirectory(atPath: activeDirectory.path))
                    == Set([Self.documentName])
            else {
                throw JazzArchiveServerDownloadError.operationJournalCorrupt
            }
            let values = try documentURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                let fileSize = values.fileSize,
                fileSize > 0,
                fileSize <= Self.maximumDocumentBytes
            else {
                throw JazzArchiveServerDownloadError.operationJournalCorrupt
            }
            let data = try Data(contentsOf: documentURL)
            let intent = try JSONDecoder().decode(
                JazzArchiveServerDownloadIntent.self,
                from: data)
            guard try JazzArchiveCanonicalJSON.encode(intent) == data else {
                throw JazzArchiveServerDownloadError.operationJournalCorrupt
            }
            try intent.validate()
            return intent
        } catch let error as JazzArchiveServerDownloadError {
            throw error
        } catch {
            throw JazzArchiveServerDownloadError.operationJournalCorrupt
        }
    }

    private func removeActiveDirectoryDurably() throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: documentURL.path)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: activeDirectory.path)
        try fileManager.removeItem(at: activeDirectory)
        try synchronizeDirectory(root)
    }

    private func persist(_ record: JazzArchiveServerDownloadAbandonment) throws {
        try fileManager.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        try synchronizeDirectory(root)
        let url = abandonmentURL(downloadOperationId: record.downloadOperationId)
        let data = try JazzArchiveCanonicalJSON.encode(record)
        guard data.count <= Self.maximumDocumentBytes else {
            throw JazzArchiveServerDownloadError.operationJournalWriteFailed
        }
        if fileManager.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else {
                throw JazzArchiveServerDownloadError.operationJournalBindingConflict
            }
            try synchronizeAbandonmentDurably(record)
            return
        }
        try data.write(to: url, options: [.atomic])
        try synchronizeAbandonmentDurably(record)
    }

    private func synchronizeActiveIntentDurably() throws {
        try synchronizeRegularFile(
            documentURL,
            permissions: Int16(0o400))
        try synchronizeDirectory(activeDirectory)
        try synchronizeDirectory(root)
        try synchronizeDirectory(root.deletingLastPathComponent())
    }

    private func synchronizeAbandonmentDurably(
        _ record: JazzArchiveServerDownloadAbandonment
    ) throws {
        let url = abandonmentURL(downloadOperationId: record.downloadOperationId)
        try synchronizeRegularFile(
            url,
            permissions: Int16(0o400))
        try synchronizeDirectory(historyDirectory)
        try synchronizeDirectory(root)
        try synchronizeDirectory(root.deletingLastPathComponent())
    }

    private func loadAbandonment(
        at url: URL
    ) throws -> JazzArchiveServerDownloadAbandonment {
        do {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                let size = values.fileSize,
                size > 0,
                size <= Self.maximumDocumentBytes
            else { throw JazzArchiveServerDownloadError.operationJournalCorrupt }
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(
                JazzArchiveServerDownloadAbandonment.self,
                from: data)
            guard try JazzArchiveCanonicalJSON.encode(record) == data,
                url.lastPathComponent
                    == "\(record.downloadOperationId).abandoned.json"
            else { throw JazzArchiveServerDownloadError.operationJournalCorrupt }
            try validate(record)
            return record
        } catch let error as JazzArchiveServerDownloadError {
            throw error
        } catch {
            throw JazzArchiveServerDownloadError.operationJournalCorrupt
        }
    }

    private func validate(
        _ record: JazzArchiveServerDownloadAbandonment
    ) throws {
        guard [1, 2].contains(record.schemaVersion),
            record.abandonmentId.hasPrefix("dab-"),
            JazzArchiveServerDownloadIntent.isUUIDv7(
                record.abandonmentId,
                prefix: "dab"),
            JazzArchiveServerDownloadIntent.isUUIDv7(
                record.downloadOperationId,
                prefix: "dop"),
            JazzArchiveControlPlaneURL.normalize(record.authorityBinding)
                == record.authorityBinding,
            !record.ingestId.isEmpty,
            JazzArchiveServerDownloadIntent.validRouteSnapshot(
                schemaVersion: record.schemaVersion,
                routeBinding: record.routeBinding,
                authorityBinding: record.authorityBinding,
                companyId: record.scope.companyId,
                areaId: record.scope.areaId,
                deviceId: record.scope.deviceId),
            record.importTargetPath.hasPrefix("/"),
            Timestamps.parse(record.operationCreatedAt) != nil,
            Timestamps.parse(record.abandonedAt) != nil,
            !record.reason.isEmpty,
            record.reason == record.reason.trimmingCharacters(
                in: .whitespacesAndNewlines),
            record.reason.utf8.count <= Self.maximumReasonBytes,
            !record.reason.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else { throw JazzArchiveServerDownloadError.operationJournalCorrupt }
    }

    private static func isClaimDirectoryName(_ name: String) -> Bool {
        let prefix = ".server-download-"
        guard name.hasPrefix(prefix) else { return false }
        let raw = String(name.dropFirst(prefix.count))
        guard raw.count == 36,
            let uuid = UUID(uuidString: raw),
            uuid.uuidString.lowercased() == raw
        else { return false }
        let characters = Array(raw)
        return characters[14] == "7" && "89ab".contains(characters[19])
    }

    private var activeDirectory: URL {
        root.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private var documentURL: URL {
        activeDirectory.appendingPathComponent(Self.documentName)
    }

    private var historyDirectory: URL {
        root.appendingPathComponent(Self.historyDirectoryName, isDirectory: true)
    }

    private func abandonmentURL(downloadOperationId: String) -> URL {
        historyDirectory.appendingPathComponent(
            "\(downloadOperationId).abandoned.json")
    }

    private func synchronizeRegularFile(
        _ file: URL,
        permissions: Int16? = nil
    ) throws {
        do {
            try durability.synchronizeRegularFile(
                file,
                permissions: permissions)
        } catch {
            throw JazzArchiveServerDownloadError.operationJournalWriteFailed
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        do {
            try durability.synchronizeDirectory(directory)
        } catch {
            throw JazzArchiveServerDownloadError.operationJournalWriteFailed
        }
    }
}

/// Small explicit lifecycle surface for the one pending server acquisition. Inspection is
/// read-only. Abandonment requires the same cross-process lease as import and first appends a
/// durable non-secret explanation before removing only the operation journal.
public actor JazzArchiveServerDownloadRecovery {
    private let root: URL
    private let fileManager: FileManager
    private let store: JazzArchiveServerDownloadIntentStore
    private let leaseProvider: any JazzArchiveFilesystemLeaseProvider

    public init(
        root: URL,
        importTargetRoot: URL,
        leaseProvider: any JazzArchiveFilesystemLeaseProvider,
        durability: JazzArchiveFilesystemDurability,
        fileManager: FileManager = .default
    ) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        self.leaseProvider = leaseProvider
        self.store = JazzArchiveServerDownloadIntentStore(
            root: root,
            importTargetRoot: importTargetRoot,
            fileManager: fileManager,
            durability: durability)
    }

    public func pendingOperation() throws -> JazzArchiveServerDownloadPendingOperation? {
        try store.pendingOperation()
    }

    @discardableResult
    public func abandonPendingOperation(
        downloadOperationId: String,
        reason: String,
        abandonedAt: String = Timestamps.iso8601()
    ) throws -> JazzArchiveServerDownloadAbandonment {
        let lease = try acquireLease()
        defer { lease.release() }
        return try store.abandon(
            downloadOperationId: downloadOperationId,
            abandonedAt: abandonedAt,
            reason: reason)
    }

    public func abandonment(
        downloadOperationId: String
    ) throws -> JazzArchiveServerDownloadAbandonment? {
        try store.abandonment(downloadOperationId: downloadOperationId)
    }

    private func acquireLease() throws -> any JazzArchiveFilesystemLease {
        do {
            return try leaseProvider.acquire(
                root: root,
                fileManager: fileManager)
        } catch JazzArchiveFilesystemLeaseError.inProgress {
            throw JazzArchiveServerDownloadError.operationInProgress
        } catch {
            throw JazzArchiveServerDownloadError.operationJournalWriteFailed
        }
    }
}

/// Authorized server import path. It downloads opaque bytes into a private claim, seals and
/// fingerprints the complete file, then hands that exact file plus all expected identities to the
/// normal strict importer. ZIP/manifest parsing never occurs while the network body is arriving.
public actor JazzArchiveServerImportCoordinator {
    static let operationJournalDirectoryName =
        JazzArchiveServerDownloadIntentStore.directoryName

    private let root: URL
    private let importer: JazzArchiveImporter
    private let transport: any JazzArchiveServerDownloadTransport
    private let maximumBytes: Int64
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private let operationJournal: JazzArchiveServerDownloadIntentStore
    private let leaseProvider: any JazzArchiveFilesystemLeaseProvider

    public init(
        root: URL,
        importer: JazzArchiveImporter,
        transport: any JazzArchiveServerDownloadTransport,
        leaseProvider: any JazzArchiveFilesystemLeaseProvider,
        durability: JazzArchiveFilesystemDurability,
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
        self.leaseProvider = leaseProvider
        self.operationJournal = JazzArchiveServerDownloadIntentStore(
            root: root,
            importTargetRoot: importer.root,
            fileManager: fileManager,
            durability: durability)
    }

    public func importReadyArchive(
        _ request: JazzArchiveServerDownloadRequest,
        importedAt: String = Timestamps.iso8601(),
        context: JazzArchiveImportContext
    ) async throws -> JazzArchiveImportResult {
        try validate(request)
        let lease = try acquireLease()
        defer { lease.release() }
        try operationJournal.reapStaleClaims()
        let intent = try operationJournal.begin(
            request: request,
            routeBinding: transport.routeBinding,
            createdAt: Timestamps.iso8601(now()))
        var effectiveRequest = request
        effectiveRequest.downloadOperationId = intent.downloadOperationId
        let grant = try await transport.authorize(effectiveRequest)
        try validate(grant, request: effectiveRequest)

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
            acquisition: .jazzServerDownload,
            downloadOperationId: grant.downloadOperationId,
            downloadAuthorizationId: grant.downloadAuthorizationId)
        let result = try await importer.importArchive(
            at: packageURL,
            importedAt: importedAt,
            context: serverContext,
            expectedPackageFingerprint: fingerprint,
            expectedArchiveId: grant.archiveId,
            expectedContentDigest: grant.contentDigest)
        try operationJournal.complete(intent)
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
            isUUIDv7(request.downloadOperationId, prefix: "dop"),
            maximumBytes > 0
        else { throw JazzArchiveServerDownloadError.invalidRequest }
    }

    private func acquireLease() throws -> any JazzArchiveFilesystemLease {
        do {
            return try leaseProvider.acquire(
                root: root,
                fileManager: fileManager)
        } catch JazzArchiveFilesystemLeaseError.inProgress {
            throw JazzArchiveServerDownloadError.operationInProgress
        } catch {
            throw JazzArchiveServerDownloadError.operationJournalWriteFailed
        }
    }

    private func validate(
        _ grant: JazzArchiveServerDownloadGrant,
        request: JazzArchiveServerDownloadRequest
    ) throws {
        guard grant.formatVersion == 1 else {
            throw JazzArchiveServerDownloadError.invalidGrant("formatVersion")
        }
        guard isUUIDv7(grant.downloadOperationId, prefix: "dop"),
            grant.downloadOperationId == request.downloadOperationId,
            isBoundedCanonicalText(grant.downloadAuthorizationId, maximumBytes: 256),
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
        _ = try JazzArchiveServerDownloadInstructions(download: grant.download)
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
        isUUIDv7(value, prefix: "ar")
    }

    private func isUUIDv7(_ value: String, prefix: String) -> Bool {
        let marker = "\(prefix)-"
        guard value.hasPrefix(marker) else { return false }
        let raw = String(value.dropFirst(marker.count))
        guard let uuid = UUID(uuidString: raw),
            uuid.uuidString.lowercased() == raw
        else { return false }
        let characters = Array(raw)
        return characters.count == 36
            && characters[14] == "7"
            && "89ab".contains(characters[19])
    }

    private func isBoundedCanonicalText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}
