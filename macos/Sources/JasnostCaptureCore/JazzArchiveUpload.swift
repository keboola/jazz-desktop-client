import Foundation

extension Identifiers {
    /// Caller-owned idempotency identity for one whole-archive upload. It is minted locally and
    /// committed with the queue record before the first control-plane request.
    public static func newUploadOperationId() -> String {
        "uop-\(newUUIDv7().uuidString.lowercased())"
    }
}

/// Capture delivery is local-first by default. The compatibility mode is an explicit migration
/// switch; it may project the same canonical IDs to OTLP/Files while the archive is still open.
public enum JazzCaptureDeliveryPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case confirmedArchive
    case liveCompatibility

    public var usesLiveCompatibilityProjection: Bool { self == .liveCompatibility }
}

public struct JazzArchiveUploadScope: Codable, Equatable, Sendable {
    public let companyId: String
    public let areaId: String
    public let deviceId: String

    public init(companyId: String, areaId: String, deviceId: String) throws {
        let values = [companyId, areaId, deviceId]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.allSatisfy({ !$0.isEmpty }) else {
            throw JazzArchiveUploadError.invalidItem("upload scope")
        }
        self.companyId = values[0]
        self.areaId = values[1]
        self.deviceId = values[2]
    }
}

/// Authenticated, non-secret provenance of one accepted signed enrollment bundle. The issuer and
/// audience identify the signing authority. Bundle id, generation, envelope digest, and token id
/// snapshots are audit evidence: they deliberately do not prevent a newer bundle from rotating an
/// expired token under the same delivery authority.
public struct JazzArchiveSignedEnrollmentAuthority: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let issuer: String
    public let audience: String
    public let bundleId: String
    public let generation: Int
    public let envelopeDigest: String

    public init(
        schemaVersion: Int = 1,
        issuer: String,
        audience: String,
        bundleId: String,
        generation: Int,
        envelopeDigest: String
    ) throws {
        self.schemaVersion = schemaVersion
        self.issuer = issuer
        self.audience = audience
        self.bundleId = bundleId
        self.generation = generation
        self.envelopeDigest = envelopeDigest
        try validate()
    }

    fileprivate func validate() throws {
        guard schemaVersion == 1,
            Self.isSecureIssuerOrigin(issuer),
            !audience.isEmpty,
            audience == audience.trimmingCharacters(in: .whitespacesAndNewlines),
            audience.unicodeScalars.count <= 256,
            bundleId.range(
                of: #"^jdb_[a-f0-9]{32}$"#,
                options: .regularExpression) != nil,
            generation >= 1,
            generation <= 9_007_199_254_740_991,
            Self.isSHA256(envelopeDigest)
        else {
            throw JazzArchiveUploadError.invalidItem("signed enrollment authority")
        }
    }

    fileprivate func hasSameSignerAuthority(
        as other: JazzArchiveSignedEnrollmentAuthority
    ) -> Bool {
        issuer == other.issuer && audience == other.audience
    }

    private static func isSecureIssuerOrigin(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.contains("\\"),
            !value.contains("?"),
            !value.contains("#"),
            value.unicodeScalars.allSatisfy({
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
                    && $0.value != 0x7f
            }),
            let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/"
        else { return false }
        return scheme == "https"
            || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }
}

/// Immutable delivery route selected for one whole-archive delivery before its first network
/// attempt. The full endpoint is pinned in addition to its origin because two Jazz environments
/// can share a signing authority while exposing different ingest roots. A later signed bundle may
/// supply a rotated token only when issuer, audience, endpoint, origin, stack, project, and the
/// complete company/area/device scope are unchanged. `tokenId` remains an audit snapshot.
public struct JazzArchiveUploadRouteBinding: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let ingestEndpoint: String
    public let ingestOrigin: String
    public let stackURL: String
    public let projectId: String
    public let tokenId: String
    public let scope: JazzArchiveUploadScope
    public let signedAuthority: JazzArchiveSignedEnrollmentAuthority?
    public let authorizationProfile: JazzArchiveEnrollmentAuthorizationProfile?

    public init(
        schemaVersion: Int = 2,
        ingestEndpoint: String,
        stackURL: String,
        projectId: String,
        tokenId: String,
        scope: JazzArchiveUploadScope,
        signedAuthority: JazzArchiveSignedEnrollmentAuthority
    ) throws {
        guard let endpoint = JazzArchiveControlPlaneURL.normalize(ingestEndpoint),
            let endpointURL = URL(string: endpoint),
            let origin = Self.origin(endpointURL),
            let normalizedStack = KeboolaStack.normalize(stackURL)
        else { throw JazzArchiveUploadError.invalidItem("upload route binding") }
        let project = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tokenId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard schemaVersion == 2, !project.isEmpty, !token.isEmpty else {
            throw JazzArchiveUploadError.invalidItem("upload route binding")
        }
        try signedAuthority.validate()
        self.schemaVersion = schemaVersion
        self.ingestEndpoint = endpoint
        self.ingestOrigin = origin
        self.stackURL = normalizedStack
        self.projectId = project
        self.tokenId = token
        self.scope = scope
        self.signedAuthority = signedAuthority
        self.authorizationProfile = .signedJWS
    }

    /// R&D-only route created from an explicit `enrollmentProfile: mvp` administrator handoff.
    /// It remains structurally distinct from both old schema-v1 records and production JWS trust.
    public init(
        mvpIngestEndpoint ingestEndpoint: String,
        stackURL: String,
        projectId: String,
        tokenId: String,
        scope: JazzArchiveUploadScope
    ) throws {
        guard let endpoint = JazzArchiveControlPlaneURL.normalize(ingestEndpoint),
            let endpointURL = URL(string: endpoint),
            let origin = Self.origin(endpointURL),
            let normalizedStack = KeboolaStack.normalize(stackURL)
        else { throw JazzArchiveUploadError.invalidItem("upload route binding") }
        let project = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tokenId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !token.isEmpty else {
            throw JazzArchiveUploadError.invalidItem("upload route binding")
        }
        self.schemaVersion = 3
        self.ingestEndpoint = endpoint
        self.ingestOrigin = origin
        self.stackURL = normalizedStack
        self.projectId = project
        self.tokenId = token
        self.scope = scope
        self.signedAuthority = nil
        self.authorizationProfile = .mvpOperatorHandoff
    }

    fileprivate func validate() throws {
        guard [1, 2, 3].contains(schemaVersion),
            JazzArchiveControlPlaneURL.normalize(ingestEndpoint) == ingestEndpoint,
            URL(string: ingestEndpoint).flatMap(Self.origin) == ingestOrigin,
            KeboolaStack.normalize(stackURL) == stackURL,
            !projectId.isEmpty,
            projectId == projectId.trimmingCharacters(in: .whitespacesAndNewlines),
            !tokenId.isEmpty,
            tokenId == tokenId.trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw JazzArchiveUploadError.invalidItem("upload route binding") }
        switch (schemaVersion, signedAuthority, authorizationProfile) {
        case (1, nil, nil):
            // Legacy records remain readable so their immutable package is not orphaned, but
            // `bindRoute` never permits this unauthenticated route to reach a credential read.
            break
        case (2, let authority?, nil), (2, let authority?, .some(.signedJWS)):
            try authority.validate()
        case (3, nil, .some(.mvpOperatorHandoff)):
            break
        default:
            throw JazzArchiveUploadError.invalidItem("upload route binding")
        }
    }

    fileprivate func validateForDelivery() throws {
        try validate()
        guard
            (schemaVersion == 2 && signedAuthority != nil)
                || (schemaVersion == 3
                    && signedAuthority == nil
                    && authorizationProfile == .mvpOperatorHandoff)
        else {
            throw JazzArchiveUploadError.routeBindingMissing("enrollment authority")
        }
    }

    /// True only for a route backed by an authenticated enrollment bundle. Version-1 queue
    /// records intentionally return false and require a safe pre-attempt upgrade.
    public var hasSignedAuthority: Bool {
        schemaVersion == 2 && signedAuthority != nil && (try? validateForDelivery()) != nil
    }

    public var hasMVPAdminHandoffAuthority: Bool {
        schemaVersion == 3 && authorizationProfile == .mvpOperatorHandoff
            && signedAuthority == nil && (try? validateForDelivery()) != nil
    }

    public var hasDeliveryAuthority: Bool {
        (try? validateForDelivery()) != nil
    }

    /// Credential-rotation check. Audit snapshots (`tokenId`, bundle id/generation/digest) are
    /// intentionally excluded, while every field that could redirect or broaden delivery remains
    /// pinned.
    public func hasSameDeliveryAuthority(
        as other: JazzArchiveUploadRouteBinding
    ) -> Bool {
        guard (try? validateForDelivery()) != nil,
            (try? other.validateForDelivery()) != nil
        else { return false }
        switch (authorizationProfile, other.authorizationProfile) {
        case (.some(.mvpOperatorHandoff), .some(.mvpOperatorHandoff)):
            break
        case (_, _):
            guard let signedAuthority,
                let otherAuthority = other.signedAuthority,
                signedAuthority.hasSameSignerAuthority(as: otherAuthority)
            else { return false }
        }
        return ingestEndpoint == other.ingestEndpoint
            && ingestOrigin == other.ingestOrigin
            && stackURL == other.stackURL
            && projectId == other.projectId
            && scope == other.scope
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
            let rawHost = url.host?.lowercased(),
            !rawHost.isEmpty
        else { return nil }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let authorityHost = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(authorityHost)\(port)"
    }
}

/// The provenance claims a new capture should write for the currently enrolled device. The
/// server-issued upload scope is authoritative: a stale menu selection can provide a display name,
/// but it can never change the Area id carried by the archive.
public struct JazzArchiveCaptureBinding: Equatable, Sendable {
    public let enrolledDeviceIdentity: JazzArchiveExternalIdentity?
    public let area: JazzArchiveArea?

    public init(
        uploadScope: JazzArchiveUploadScope?,
        selectedAreaId: String?,
        selectedAreaName: String?
    ) {
        let selectedId =
            selectedAreaId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedName =
            selectedAreaName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let uploadScope else {
            enrolledDeviceIdentity = nil
            area =
                selectedId.isEmpty
                ? nil
                : JazzArchiveArea(
                    areaId: selectedId,
                    nameSnapshot: selectedName.isEmpty ? selectedId : selectedName)
            return
        }

        enrolledDeviceIdentity = JazzArchiveExternalIdentity(
            namespace: "jazz.device", value: uploadScope.deviceId)
        let name: String
        if uploadScope.areaId == CaptureScope.generalAreaId {
            name = CaptureScope.generalAreaName
        } else if selectedId == uploadScope.areaId, !selectedName.isEmpty {
            name = selectedName
        } else {
            // Enrollment currently carries the stable Area id but not a separate display label.
            // Using that id is truthful and deterministic; a registry enrichment may add the name.
            name = uploadScope.areaId
        }
        area = JazzArchiveArea(areaId: uploadScope.areaId, nameSnapshot: name)
    }
}

extension JazzArchiveUploadScope {
    /// Fail closed before the first network request when immutable package claims cannot be
    /// accepted under this enrollment. A missing device claim remains valid for captures made
    /// before enrollment; when present, the claim must use the canonical namespace and exact id.
    public func validateArchiveClaims(
        manifest: JazzArchiveManifest,
        sessions: [JazzArchiveSession]
    ) throws {
        if let identity = manifest.enrolledDeviceIdentity,
            identity.namespace != "jazz.device" || identity.value != deviceId
        {
            throw JazzArchiveUploadError.scopeClaimMismatch(
                "SCOPE_DEVICE_CLAIM_MISMATCH")
        }
        for session in sessions {
            if let claimedAreaId = session.area?.areaId {
                guard claimedAreaId == areaId else {
                    throw JazzArchiveUploadError.scopeClaimMismatch("SCOPE_AREA_MISMATCH")
                }
            } else if areaId != CaptureScope.generalAreaId {
                throw JazzArchiveUploadError.scopeClaimMismatch("SCOPE_AREA_CLAIM_MISSING")
            }
        }
    }
}

/// Durable client-side states. Transient upload grants never enter this model.
public enum JazzArchiveUploadState: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case creatingIntent
    case uploading
    case finalizing
    case verifying
    case processing
    case ready
    case retryable
    case reconnectRequired
    case failedTerminal = "failed_terminal"
    case rejected
    case quarantined
    case conflict
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .ready, .failedTerminal, .rejected, .quarantined, .conflict, .cancelled: true
        default: false
        }
    }

    public var canRunAutomatically: Bool {
        switch self {
        case .queued, .creatingIntent, .uploading, .finalizing, .verifying, .processing,
            .retryable:
            true
        case .reconnectRequired, .ready, .failedTerminal, .rejected, .quarantined,
            .conflict, .cancelled:
            false
        }
    }
}

public struct JazzArchiveUploadIssue: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// One immutable archive delivery. `packageFileName` is relative to the queue-owned package
/// directory, so relaunches cannot accidentally follow an arbitrary mutable URL.
public struct JazzArchiveUploadItem: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: Int
    /// Durable caller-owned idempotency identity. Version-1 records did not carry this field.
    /// Only a provably unattempted legacy record may acquire one during queue migration.
    public var uploadOperationId: String?
    public let archiveId: String
    public let originId: String
    public let captureIds: [String]
    public let formatVersion: Int
    public let revision: Int
    public let contentDigest: String
    public let rawSHA256: String
    public let byteLength: Int64
    public let packageFileName: String
    public var scope: JazzArchiveUploadScope?
    public var routeBinding: JazzArchiveUploadRouteBinding?
    public var state: JazzArchiveUploadState
    public var resumeState: JazzArchiveUploadState?
    public var ingestId: String?
    public var uploadReceipt: String?
    public var attempt: Int
    public let queuedAt: String
    public var updatedAt: String
    public var issue: JazzArchiveUploadIssue?
    public var conflictingRawSHA256: String?
    /// Durable retry watermark. A server value is authoritative; otherwise the client derives a
    /// deterministic bounded backoff. It is never part of archive or upload-operation identity.
    public var nextAttemptAt: String?

    public var id: String { archiveId }

    public init(
        schemaVersion: Int = 2,
        uploadOperationId: String? = nil,
        archiveId: String,
        originId: String,
        captureIds: [String],
        formatVersion: Int = JazzArchiveManifest.currentFormatVersion,
        revision: Int,
        contentDigest: String,
        rawSHA256: String,
        byteLength: Int64,
        packageFileName: String? = nil,
        scope: JazzArchiveUploadScope?,
        routeBinding: JazzArchiveUploadRouteBinding? = nil,
        state: JazzArchiveUploadState? = nil,
        attempt: Int = 0,
        queuedAt: String = Timestamps.iso8601(),
        updatedAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.uploadOperationId =
            uploadOperationId
            ?? (schemaVersion == 2 ? Identifiers.newUploadOperationId() : nil)
        self.archiveId = archiveId
        self.originId = originId
        self.captureIds = captureIds
        self.formatVersion = formatVersion
        self.revision = revision
        self.contentDigest = contentDigest
        self.rawSHA256 = rawSHA256
        self.byteLength = byteLength
        self.packageFileName = packageFileName ?? "\(archiveId).jazz-archive"
        self.scope = scope
        self.routeBinding = routeBinding
        self.state = state ?? (scope == nil ? .reconnectRequired : .queued)
        self.resumeState = scope == nil ? .queued : nil
        self.ingestId = nil
        self.uploadReceipt = nil
        self.attempt = attempt
        self.queuedAt = queuedAt
        self.updatedAt = updatedAt ?? queuedAt
        self.issue =
            scope == nil
            ? JazzArchiveUploadIssue(
                code: "ARCHIVE_SCOPE_UNAVAILABLE",
                message: "Import an updated device enrollment bundle before upload.")
            : nil
        self.conflictingRawSHA256 = nil
        self.nextAttemptAt = nil
    }

    fileprivate func validate() throws {
        guard [1, 2].contains(schemaVersion),
            Self.isUUIDv7(archiveId, prefix: "ar"),
            Self.isUUIDv7(originId, prefix: "origin"),
            !captureIds.isEmpty,
            captureIds.allSatisfy({ Self.isUUIDv7($0, prefix: "cap") }),
            Set(captureIds).count == captureIds.count,
            formatVersion >= 1,
            revision >= 1,
            Self.isSHA256(contentDigest),
            Self.isSHA256(rawSHA256),
            byteLength > 0,
            packageFileName == "\(archiveId).jazz-archive",
            !packageFileName.contains("/"),
            attempt >= 0,
            Timestamps.parse(queuedAt) != nil,
            Timestamps.parse(updatedAt) != nil
        else { throw JazzArchiveUploadError.invalidItem(archiveId) }
        switch schemaVersion {
        case 1:
            guard uploadOperationId == nil else {
                throw JazzArchiveUploadError.invalidItem(archiveId)
            }
        case 2:
            guard let uploadOperationId,
                Self.isUploadOperationId(uploadOperationId)
            else { throw JazzArchiveUploadError.invalidItem(archiveId) }
        default:
            throw JazzArchiveUploadError.invalidItem(archiveId)
        }
        if let conflictingRawSHA256, !Self.isSHA256(conflictingRawSHA256) {
            throw JazzArchiveUploadError.invalidItem(archiveId)
        }
        if let nextAttemptAt, Timestamps.parse(nextAttemptAt) == nil {
            throw JazzArchiveUploadError.invalidItem(archiveId)
        }
        if let uploadReceipt,
            (try? JazzArchiveHTTPPutGrant.validateReceipt(uploadReceipt)) == nil
        {
            throw JazzArchiveUploadError.invalidItem(archiveId)
        }
        if let routeBinding {
            try routeBinding.validate()
            guard scope == routeBinding.scope else {
                throw JazzArchiveUploadError.invalidItem(archiveId)
            }
        }
        if state == .finalizing, uploadReceipt?.isEmpty != false {
            throw JazzArchiveUploadError.invalidItem(archiveId)
        }
        if [.finalizing, .verifying, .processing, .ready, .failedTerminal].contains(state),
            ingestId?.isEmpty != false
        {
            throw JazzArchiveUploadError.invalidItem(archiveId)
        }
    }

    public func canRunAutomatically(at date: Date = Date()) -> Bool {
        guard state.canRunAutomatically else { return false }
        guard state == .retryable,
            let nextAttemptAt,
            let retryDate = Timestamps.parse(nextAttemptAt)
        else { return true }
        return retryDate <= date
    }

    /// A pinned route always wins over later settings. The current enrollment is consulted only
    /// for an item that has not selected an authority yet.
    public func effectiveRouteBinding(
        currentEnrollment: JazzArchiveUploadRouteBinding?
    ) -> JazzArchiveUploadRouteBinding? {
        guard let routeBinding else { return currentEnrollment }
        return routeBinding.hasDeliveryAuthority ? routeBinding : currentEnrollment
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }

    fileprivate static func isUploadOperationId(_ value: String) -> Bool {
        isUUIDv7(value, prefix: "uop")
    }

    private static func isUUIDv7(
        _ value: String,
        prefix: String
    ) -> Bool {
        let delimiter = "\(prefix)-"
        guard value.hasPrefix(delimiter) else { return false }
        let raw = String(value.dropFirst(delimiter.count))
        guard let uuid = UUID(uuidString: raw),
            uuid.uuidString.lowercased() == raw
        else { return false }
        let characters = Array(raw)
        return characters.count == 36
            && characters[14] == "7"
            && "89ab".contains(characters[19])
    }
}

public enum JazzArchiveUploadError: Error, Equatable, CustomStringConvertible {
    case invalidItem(String)
    case missing(String)
    case packageMissing(String)
    case packageChanged(String)
    case archiveCollision(String)
    case scopeClaimMismatch(String)
    case persistenceFailed(String)
    case operationInProgress
    case invalidTransition(from: JazzArchiveUploadState, to: JazzArchiveUploadState)
    case scopeAlreadyBound(String)
    case routeAlreadyBound(String)
    case routeBindingMissing(String)
    case credentialUnavailable
    case credentialExpired
    case credentialBindingMismatch
    case tokenRejected(String)
    case retryable(String)
    case rejected(String)
    case quarantined(String)
    case conflict(String)
    case invalidServerResponse(String)

    public var description: String {
        switch self {
        case .invalidItem(let value): "Invalid archive delivery item: \(value)"
        case .missing(let value): "Archive delivery item is missing: \(value)"
        case .packageMissing(let value): "Archive package is missing: \(value)"
        case .packageChanged(let value): "Archive package changed after queueing: \(value)"
        case .archiveCollision(let value): "Archive identity collision: \(value)"
        case .scopeClaimMismatch(let code): "Archive scope claim does not match enrollment: \(code)"
        case .persistenceFailed(let value):
            "Archive delivery state could not be committed durably: \(value)"
        case .operationInProgress:
            "Another process is updating the archive delivery queue"
        case .invalidTransition(let from, let to):
            "Invalid archive delivery transition: \(from.rawValue) -> \(to.rawValue)"
        case .scopeAlreadyBound(let value): "Archive delivery scope is already bound: \(value)"
        case .routeAlreadyBound(let value): "Archive delivery route is already bound: \(value)"
        case .routeBindingMissing(let value):
            "Archive delivery route cannot be recovered safely: \(value)"
        case .credentialUnavailable: "Device credential is unavailable"
        case .credentialExpired: "Device credential expired"
        case .credentialBindingMismatch:
            "Current device credential belongs to a different archive enrollment"
        case .tokenRejected(let code): "Device credential rejected: \(code)"
        case .retryable(let code): "Archive delivery can retry: \(code)"
        case .rejected(let code): "Archive delivery rejected: \(code)"
        case .quarantined(let code): "Archive delivery quarantined: \(code)"
        case .conflict(let code): "Archive delivery conflict: \(code)"
        case .invalidServerResponse(let code): "Invalid archive server response: \(code)"
        }
    }
}

/// Durable queue for whole `.jazz-archive` packages. This is intentionally separate from
/// `JazzArchiveDeliveryQueue`, which is the old per-artifact Keboola Files compatibility queue.
enum JazzArchiveUploadQueueWorkUnit: Equatable, Sendable {
    case packageFingerprint
}

public actor JazzArchiveUploadQueue {
    public nonisolated let root: URL

    private let fileManager: FileManager
    private let durability: JazzArchiveFilesystemDurability
    private let leaseProvider: any JazzArchiveFilesystemLeaseProvider
    private let workObserver: (@Sendable (JazzArchiveUploadQueueWorkUnit) -> Void)?
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    public init(
        root: URL,
        durability: JazzArchiveFilesystemDurability,
        leaseProvider: any JazzArchiveFilesystemLeaseProvider,
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.durability = durability
        self.leaseProvider = leaseProvider
        self.fileManager = fileManager
        self.workObserver = nil
    }

    init(
        root: URL,
        durability: JazzArchiveFilesystemDurability,
        leaseProvider: any JazzArchiveFilesystemLeaseProvider,
        fileManager: FileManager = .default,
        workObserver: @escaping @Sendable (JazzArchiveUploadQueueWorkUnit) -> Void
    ) {
        self.root = root
        self.durability = durability
        self.leaseProvider = leaseProvider
        self.fileManager = fileManager
        self.workObserver = workObserver
    }

    public func enqueue(
        file source: URL,
        archiveId: String,
        originId: String,
        captureIds: [String],
        formatVersion: Int = JazzArchiveManifest.currentFormatVersion,
        revision: Int,
        contentDigest: String,
        scope: JazzArchiveUploadScope?,
        queuedAt: String = Timestamps.iso8601()
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        let incoming = try JazzArchiveFileIO.fingerprint(source)
        var candidate = JazzArchiveUploadItem(
            uploadOperationId: try mintUniqueUploadOperationId(),
            archiveId: archiveId,
            originId: originId,
            captureIds: captureIds,
            formatVersion: formatVersion,
            revision: revision,
            contentDigest: contentDigest,
            rawSHA256: incoming.sha256,
            byteLength: incoming.byteLength,
            scope: scope,
            queuedAt: queuedAt)
        try candidate.validate()
        try prepareDirectories()

        if var existing = try loadIfPresent(archiveId) {
            let existingFingerprint = try verifiedFingerprint(existing)
            guard existing.rawSHA256 == incoming.sha256,
                existing.byteLength == incoming.byteLength,
                existingFingerprint == incoming,
                immutableIdentity(existing) == immutableIdentity(candidate)
            else {
                existing.state = .conflict
                existing.resumeState = nil
                existing.issue = JazzArchiveUploadIssue(
                    code: "ARCHIVE_ID_COLLISION",
                    message: "The same archive ID was presented with different immutable bytes or metadata.")
                existing.conflictingRawSHA256 = incoming.sha256
                existing.updatedAt = queuedAt
                try persist(existing)
                throw JazzArchiveUploadError.archiveCollision(archiveId)
            }
            if existing.scope == nil, let scope, existing.ingestId == nil {
                existing.scope = scope
                if existing.state == .reconnectRequired,
                    existing.issue?.code == "ARCHIVE_SCOPE_UNAVAILABLE"
                {
                    existing.state = .queued
                    existing.resumeState = nil
                    existing.issue = nil
                }
                existing.updatedAt = queuedAt
                try persist(existing)
            }
            try synchronizePackageDurably(existing)
            try synchronizeRecordDurably(existing)
            return existing
        }

        let destination = packageURL(candidate)
        if fileManager.fileExists(atPath: destination.path) {
            let existing = try JazzArchiveFileIO.fingerprint(destination)
            guard existing == incoming else {
                candidate.state = .conflict
                candidate.resumeState = nil
                candidate.issue = JazzArchiveUploadIssue(
                    code: "ARCHIVE_ID_COLLISION",
                    message: "A queue-owned package already uses this archive ID with different bytes.")
                candidate.conflictingRawSHA256 = existing.sha256
                try persist(candidate)
                throw JazzArchiveUploadError.archiveCollision(archiveId)
            }
        } else {
            do {
                _ = try JazzArchiveFileIO.copyAtomically(
                    source,
                    to: destination,
                    expected: incoming,
                    fileManager: fileManager)
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o400))],
                    ofItemAtPath: destination.path)
            } catch {
                if fileManager.fileExists(atPath: destination.path),
                    (try? JazzArchiveFileIO.fingerprint(destination)) != incoming
                {
                    candidate.state = .conflict
                    candidate.resumeState = nil
                    candidate.issue = JazzArchiveUploadIssue(
                        code: "ARCHIVE_ID_COLLISION",
                        message: "Concurrent queueing found different bytes for this archive ID.")
                    candidate.conflictingRawSHA256 = try? JazzArchiveFileIO.fingerprint(destination).sha256
                    try persist(candidate)
                    throw JazzArchiveUploadError.archiveCollision(archiveId)
                }
                throw error
            }
        }
        try synchronizePackageDurably(candidate)
        try persist(candidate)
        return candidate
    }

    public func item(archiveId: String) throws -> JazzArchiveUploadItem? {
        let lease = try acquireLease()
        defer { lease.release() }
        return try loadIfPresent(archiveId)
    }

    public func all() throws -> [JazzArchiveUploadItem] {
        let lease = try acquireLease()
        defer { lease.release() }
        guard fileManager.fileExists(atPath: recordsRoot.path) else { return [] }
        // Listing is metadata-only. Hashing every immutable ZIP here made each UI refresh O(total
        // queued bytes) and let one damaged package hide unrelated deliveries. `packageURL`
        // performs the fail-closed exact fingerprint check immediately before object upload.
        return try fileManager.contentsOfDirectory(
            at: recordsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
            .filter { $0.pathExtension == "json" }
            .map { url in
                guard let item = try loadRecord(at: url) else {
                    throw JazzArchiveUploadError.invalidItem(
                        url.deletingPathExtension().lastPathComponent)
                }
                return item
            }
            .sorted { ($0.queuedAt, $0.archiveId) < ($1.queuedAt, $1.archiveId) }
    }

    public func nextRunnable() throws -> JazzArchiveUploadItem? {
        try all().first { $0.canRunAutomatically() }
    }

    public func packageURL(archiveId: String) throws -> URL {
        let lease = try acquireLease()
        defer { lease.release() }
        guard let item = try loadIfPresent(archiveId) else {
            throw JazzArchiveUploadError.missing(archiveId)
        }
        _ = try verifiedFingerprint(item)
        try synchronizePackageDurably(item)
        return packageURL(item)
    }

    /// Rebind only delivery routing that has never reached the server. Canonical archive bytes and
    /// capture scope in the manifest are immutable; this fills enrollment metadata omitted by an
    /// older device bundle.
    public func bindScope(
        archiveId: String,
        scope: JazzArchiveUploadScope,
        at: String = Timestamps.iso8601()
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        var item = try require(archiveId)
        if let existing = item.scope, existing != scope {
            throw JazzArchiveUploadError.scopeAlreadyBound(archiveId)
        }
        guard item.ingestId == nil else {
            if item.scope == scope { return item }
            throw JazzArchiveUploadError.scopeAlreadyBound(archiveId)
        }
        item.scope = scope
        if item.state == .reconnectRequired,
            item.issue?.code == "ARCHIVE_SCOPE_UNAVAILABLE"
        {
            item.state = item.resumeState ?? .queued
            item.resumeState = nil
            item.issue = nil
        }
        item.updatedAt = at
        try persist(item)
        return item
    }

    /// Persist the exact non-secret authority tuple before the first credential read or HTTP
    /// request. A legacy item may acquire a route only when its durable state proves that no
    /// attempt has started; ambiguous in-flight legacy entries fail closed and keep their bytes.
    public func bindRoute(
        archiveId: String,
        routeBinding: JazzArchiveUploadRouteBinding,
        at: String = Timestamps.iso8601()
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        try routeBinding.validateForDelivery()
        var item = try require(archiveId)
        if let existing = item.routeBinding {
            if existing == routeBinding || existing.hasSameDeliveryAuthority(as: routeBinding) {
                try synchronizePackageDurably(item)
                try synchronizeRecordDurably(item)
                return item
            }
            // A legacy route did not carry signed authority. It may be replaced only while the
            // durable state proves that no credential or network attempt has started.
            guard !existing.hasDeliveryAuthority,
                item.attempt == 0,
                item.ingestId == nil,
                item.uploadReceipt == nil,
                item.state == .queued
                    || (item.state == .reconnectRequired
                        && item.issue?.code == "ARCHIVE_SCOPE_UNAVAILABLE")
            else {
                throw JazzArchiveUploadError.routeAlreadyBound(archiveId)
            }
            guard item.scope == routeBinding.scope else {
                throw JazzArchiveUploadError.routeAlreadyBound(archiveId)
            }
            item.routeBinding = routeBinding
            item.updatedAt = at
            try persist(item)
            try synchronizePackageDurably(item)
            return item
        }
        guard item.scope == routeBinding.scope else {
            throw JazzArchiveUploadError.routeAlreadyBound(archiveId)
        }
        guard item.attempt == 0,
            item.ingestId == nil,
            item.uploadReceipt == nil,
            item.state == .queued
                || (item.state == .reconnectRequired
                    && item.issue?.code == "ARCHIVE_SCOPE_UNAVAILABLE")
        else {
            throw JazzArchiveUploadError.routeBindingMissing(archiveId)
        }
        item.routeBinding = routeBinding
        item.updatedAt = at
        try persist(item)
        try synchronizePackageDurably(item)
        return item
    }

    /// Deliberate recovery path for an ambiguous version-1 operation. Unlike ordinary route
    /// binding, this may attach the current signed authority to a conflict record, but only after a
    /// user explicitly selected reconciliation and only when every pre-existing non-secret route
    /// and scope field agrees.
    fileprivate func prepareLegacyReconciliation(
        archiveId: String,
        routeBinding: JazzArchiveUploadRouteBinding,
        at: String
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        try routeBinding.validateForDelivery()
        var item = try require(archiveId)
        guard item.schemaVersion == 1,
            item.uploadOperationId == nil,
            item.state == .conflict,
            item.issue?.code == "ARCHIVE_UPLOAD_OPERATION_RECONCILIATION_REQUIRED",
            item.scope == routeBinding.scope
        else { throw JazzArchiveUploadError.invalidItem(archiveId) }
        guard let existing = item.routeBinding else {
            // An attempted v1 record without a persisted authority cannot prove which server may
            // already own the operation. Current Settings are not sufficient evidence for sending
            // the one operation-id-less reconciliation request.
            throw JazzArchiveUploadError.routeBindingMissing(archiveId)
        }
        guard existing.ingestEndpoint == routeBinding.ingestEndpoint,
            existing.ingestOrigin == routeBinding.ingestOrigin,
            existing.stackURL == routeBinding.stackURL,
            existing.projectId == routeBinding.projectId,
            existing.scope == routeBinding.scope,
            !existing.hasDeliveryAuthority
                || existing.hasSameDeliveryAuthority(as: routeBinding)
        else {
            throw JazzArchiveUploadError.routeAlreadyBound(archiveId)
        }
        item.routeBinding = routeBinding
        item.updatedAt = at
        try persist(item)
        try synchronizePackageDurably(item)
        return item
    }

    /// Atomically adopts only the operation identity returned by the authenticated legacy intent
    /// lookup. No locally minted replacement is accepted. The retained v1 stage determines whether
    /// the next exact-v2 request finalizes, polls, or reacquires an upload grant.
    fileprivate func adoptLegacyReconciliation(
        archiveId: String,
        uploadOperationId: String,
        ingestId: String,
        at: String
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        guard JazzArchiveUploadItem.isUploadOperationId(uploadOperationId),
            !ingestId.isEmpty
        else {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_UPLOAD_RECONCILIATION_ID_INVALID")
        }
        var item = try require(archiveId)
        guard item.schemaVersion == 1,
            item.uploadOperationId == nil,
            item.state == .conflict,
            item.issue?.code == "ARCHIVE_UPLOAD_OPERATION_RECONCILIATION_REQUIRED",
            item.routeBinding?.hasSignedAuthority == true
        else { throw JazzArchiveUploadError.invalidItem(archiveId) }
        if let existingIngestId = item.ingestId, existingIngestId != ingestId {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_RESPONSE_INGEST_MISMATCH")
        }
        guard try !persistedOperationIds(excluding: archiveId).contains(uploadOperationId) else {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_UPLOAD_OPERATION_ID_COLLISION")
        }
        let recoveryStage = item.resumeState
        item.schemaVersion = 2
        item.uploadOperationId = uploadOperationId
        item.ingestId = ingestId
        if item.uploadReceipt != nil {
            item.state = .finalizing
        } else if recoveryStage == .verifying || recoveryStage == .processing {
            item.state = recoveryStage ?? .processing
        } else {
            item.state = .queued
        }
        item.resumeState = nil
        item.issue = nil
        item.nextAttemptAt = nil
        item.updatedAt = at
        try persist(item)
        return item
    }

    public func retry(
        archiveId: String,
        at: String = Timestamps.iso8601()
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        var item = try require(archiveId)
        guard [.retryable, .reconnectRequired, .cancelled].contains(item.state) else {
            throw JazzArchiveUploadError.invalidTransition(from: item.state, to: .queued)
        }
        if item.state == .retryable,
            let nextAttemptAt = item.nextAttemptAt,
            let retryDate = Timestamps.parse(nextAttemptAt),
            let requestedDate = Timestamps.parse(at),
            requestedDate < retryDate
        {
            return item
        }
        guard item.scope != nil else {
            item.state = .reconnectRequired
            item.resumeState = item.resumeState ?? .queued
            item.issue = JazzArchiveUploadIssue(
                code: "ARCHIVE_SCOPE_UNAVAILABLE",
                message: "Import an updated device enrollment bundle before upload.")
            item.updatedAt = at
            try persist(item)
            return item
        }
        let target = resumableTarget(item)
        guard Self.isAllowed(from: item.state, to: target) else {
            throw JazzArchiveUploadError.invalidTransition(from: item.state, to: target)
        }
        item.state = target
        // A queued/create-intent retry increments in `beginIntent`; an already-created ingest
        // resumes directly at finalize/poll and therefore accounts for its new attempt here.
        if target != .queued {
            item.attempt += 1
        }
        item.resumeState = nil
        item.issue = nil
        item.nextAttemptAt = nil
        item.updatedAt = at
        try persist(item)
        return item
    }

    public func cancel(
        archiveId: String,
        at: String = Timestamps.iso8601()
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        let item = try require(archiveId)
        return try transition(
            item,
            to: .cancelled,
            issue: JazzArchiveUploadIssue(
                code: "ARCHIVE_UPLOAD_CANCELLED",
                message: "Upload was cancelled; local archive bytes were retained."),
            at: at)
    }

    @discardableResult
    public func transition(
        archiveId: String,
        to state: JazzArchiveUploadState,
        at: String = Timestamps.iso8601()
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        return try transition(try require(archiveId), to: state, at: at)
    }

    fileprivate func beginIntent(
        archiveId: String,
        at: String
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        var item = try require(archiveId)
        guard item.routeBinding != nil else {
            throw JazzArchiveUploadError.routeBindingMissing(archiveId)
        }
        let target: JazzArchiveUploadState = .creatingIntent
        guard Self.isAllowed(from: item.state, to: target) else {
            throw JazzArchiveUploadError.invalidTransition(from: item.state, to: target)
        }
        item.state = target
        item.resumeState = nil
        item.attempt += 1
        item.issue = nil
        item.nextAttemptAt = nil
        item.updatedAt = at
        try persist(item)
        return item
    }

    fileprivate func setIntent(
        archiveId: String,
        ingestId: String,
        state: JazzArchiveUploadState,
        at: String
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        guard !ingestId.isEmpty else { throw JazzArchiveUploadError.invalidItem(archiveId) }
        var item = try require(archiveId)
        guard Self.isAllowed(from: item.state, to: state) else {
            throw JazzArchiveUploadError.invalidTransition(from: item.state, to: state)
        }
        if let existing = item.ingestId, existing != ingestId {
            return try markConflict(
                item,
                code: "ARCHIVE_INGEST_ID_CHANGED",
                message: "The server returned a different ingest identity for the same archive.",
                at: at)
        }
        item.ingestId = ingestId
        item.state = state
        item.resumeState = nil
        item.issue = nil
        item.nextAttemptAt = nil
        item.updatedAt = at
        try persist(item)
        return item
    }

    fileprivate func setUploadReceipt(
        archiveId: String,
        receipt: String,
        at: String
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        let receipt = try JazzArchiveHTTPPutGrant.validateReceipt(receipt)
        var item = try require(archiveId)
        guard Self.isAllowed(from: item.state, to: .finalizing) else {
            throw JazzArchiveUploadError.invalidTransition(from: item.state, to: .finalizing)
        }
        item.uploadReceipt = receipt
        item.state = .finalizing
        item.resumeState = nil
        item.issue = nil
        item.nextAttemptAt = nil
        item.updatedAt = at
        try persist(item)
        return item
    }

    fileprivate func markRetryable(
        archiveId: String,
        code: String,
        resumeState: JazzArchiveUploadState,
        nextAttemptAt: String? = nil,
        at: String
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        if let nextAttemptAt, Timestamps.parse(nextAttemptAt) == nil {
            throw JazzArchiveUploadError.invalidServerResponse("NEXT_ATTEMPT_AT_INVALID")
        }
        var item = try require(archiveId)
        guard Self.isAllowed(from: item.state, to: .retryable) else {
            if item.state == .cancelled { return item }
            throw JazzArchiveUploadError.invalidTransition(from: item.state, to: .retryable)
        }
        item.resumeState = resumeState
        item.state = .retryable
        item.issue = JazzArchiveUploadIssue(
            code: code,
            message: "Delivery is waiting for a safe retry; the local package is unchanged.")
        item.nextAttemptAt = nextAttemptAt
        item.updatedAt = at
        try persist(item)
        return item
    }

    fileprivate func markReconnectRequired(
        archiveId: String,
        code: String,
        resumeState: JazzArchiveUploadState,
        at: String
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        var item = try require(archiveId)
        guard Self.isAllowed(from: item.state, to: .reconnectRequired) else {
            if item.state == .cancelled { return item }
            throw JazzArchiveUploadError.invalidTransition(
                from: item.state, to: .reconnectRequired)
        }
        item.resumeState = resumeState
        item.state = .reconnectRequired
        item.issue = JazzArchiveUploadIssue(
            code: code,
            message: "Reconnect this device with a newly issued scoped token; local bytes are safe.")
        item.nextAttemptAt = nil
        item.updatedAt = at
        try persist(item)
        return item
    }

    fileprivate func applyTerminal(
        archiveId: String,
        state: JazzArchiveUploadState,
        code: String?,
        at: String
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        var item = try require(archiveId)
        guard Self.isAllowed(from: item.state, to: state) else {
            if item.state == .cancelled { return item }
            throw JazzArchiveUploadError.invalidTransition(from: item.state, to: state)
        }
        item.state = state
        item.resumeState = nil
        item.nextAttemptAt = nil
        item.issue = code.map {
            let message: String
            switch state {
            case .ready:
                message = "Archive is ready on the server."
            case .failedTerminal:
                message = "The server reported a terminal processing failure; local bytes were retained."
            default:
                message = "The server stopped this delivery; local bytes were retained."
            }
            return JazzArchiveUploadIssue(
                code: $0,
                message: message)
        }
        item.updatedAt = at
        try persist(item)
        return item
    }

    fileprivate func markConflict(
        archiveId: String,
        code: String,
        at: String
    ) throws -> JazzArchiveUploadItem {
        let lease = try acquireLease()
        defer { lease.release() }
        return try markConflict(
            try require(archiveId),
            code: code,
            message: "The server reported an immutable identity or digest conflict.",
            at: at)
    }

    private func markConflict(
        _ item: JazzArchiveUploadItem,
        code: String,
        message: String,
        at: String
    ) throws -> JazzArchiveUploadItem {
        var changed = item
        guard Self.isAllowed(from: changed.state, to: .conflict) else {
            if changed.state == .conflict { return changed }
            throw JazzArchiveUploadError.invalidTransition(from: changed.state, to: .conflict)
        }
        changed.state = .conflict
        changed.resumeState = nil
        changed.nextAttemptAt = nil
        changed.issue = JazzArchiveUploadIssue(code: code, message: message)
        changed.updatedAt = at
        try persist(changed)
        return changed
    }

    private func transition(
        _ item: JazzArchiveUploadItem,
        to state: JazzArchiveUploadState,
        issue: JazzArchiveUploadIssue? = nil,
        at: String
    ) throws -> JazzArchiveUploadItem {
        guard Self.isAllowed(from: item.state, to: state) else {
            throw JazzArchiveUploadError.invalidTransition(from: item.state, to: state)
        }
        var changed = item
        changed.state = state
        changed.resumeState = nil
        changed.nextAttemptAt = nil
        changed.issue = issue
        changed.updatedAt = at
        try persist(changed)
        return changed
    }

    private static func isAllowed(
        from: JazzArchiveUploadState,
        to: JazzArchiveUploadState
    ) -> Bool {
        if from == to {
            // A process can terminate after `beginIntent` durably commits this state but before the
            // idempotent control-plane request returns. Relaunch must be allowed to replay the same
            // caller-owned operation and immutable tuple instead of wedging the queue.
            return [.creatingIntent, .processing, .verifying].contains(from)
        }
        if to == .conflict { return from != .conflict }
        if to == .cancelled { return !from.isTerminal }
        switch from {
        case .queued:
            return [.creatingIntent, .reconnectRequired, .retryable].contains(to)
        case .creatingIntent:
            return [
                .uploading, .verifying, .processing, .ready, .retryable,
                .reconnectRequired, .failedTerminal, .rejected, .quarantined,
            ].contains(to)
        case .uploading:
            return [
                .creatingIntent, .finalizing, .retryable, .reconnectRequired,
                .failedTerminal, .rejected, .quarantined,
            ].contains(to)
        case .finalizing:
            return [
                .verifying, .processing, .ready, .retryable, .reconnectRequired,
                .failedTerminal, .rejected, .quarantined,
            ].contains(to)
        case .verifying:
            return [
                .processing, .ready, .retryable, .reconnectRequired,
                .failedTerminal, .rejected, .quarantined,
            ].contains(to)
        case .processing:
            return [
                .verifying, .ready, .retryable, .reconnectRequired,
                .failedTerminal, .rejected, .quarantined,
            ].contains(to)
        case .retryable, .reconnectRequired, .cancelled:
            return [
                .queued, .creatingIntent, .finalizing, .verifying, .processing,
                .failedTerminal, .rejected, .quarantined,
            ].contains(to)
        case .ready, .failedTerminal, .rejected, .quarantined, .conflict:
            return false
        }
    }

    private func resumableTarget(_ item: JazzArchiveUploadItem) -> JazzArchiveUploadState {
        switch item.resumeState {
        case .finalizing where item.ingestId != nil && item.uploadReceipt != nil: .finalizing
        case .verifying where item.ingestId != nil: .verifying
        case .processing where item.ingestId != nil: .processing
        default: .queued
        }
    }

    private func verifiedFingerprint(
        _ item: JazzArchiveUploadItem
    ) throws -> JazzArchiveFileFingerprint {
        let url = packageURL(item)
        guard fileManager.fileExists(atPath: url.path) else {
            throw JazzArchiveUploadError.packageMissing(item.archiveId)
        }
        workObserver?(.packageFingerprint)
        let actual = try JazzArchiveFileIO.fingerprint(url)
        guard actual.sha256 == item.rawSHA256, actual.byteLength == item.byteLength else {
            throw JazzArchiveUploadError.packageChanged(item.archiveId)
        }
        return actual
    }

    private func immutableIdentity(_ item: JazzArchiveUploadItem) -> [String] {
        [
            item.archiveId, item.originId, item.captureIds.joined(separator: ","),
            String(item.formatVersion), String(item.revision), item.contentDigest, item.rawSHA256,
            String(item.byteLength), item.packageFileName,
        ]
    }

    private func require(_ archiveId: String) throws -> JazzArchiveUploadItem {
        guard let item = try loadIfPresent(archiveId) else {
            throw JazzArchiveUploadError.missing(archiveId)
        }
        return item
    }

    private func loadIfPresent(_ archiveId: String) throws -> JazzArchiveUploadItem? {
        let url = recordURL(archiveId)
        guard let item = try loadRecord(at: url) else { return nil }
        guard item.archiveId == archiveId else {
            throw JazzArchiveUploadError.invalidItem(archiveId)
        }
        return item
    }

    private func loadRecord(at url: URL) throws -> JazzArchiveUploadItem? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        var item = try Self.decoder.decode(
            JazzArchiveUploadItem.self, from: Data(contentsOf: url))
        try item.validate()
        guard url.deletingPathExtension().lastPathComponent == item.archiveId else {
            throw JazzArchiveUploadError.invalidItem(item.archiveId)
        }
        if item.schemaVersion == 1 {
            if canMintOperationId(for: item) {
                item.schemaVersion = 2
                item.uploadOperationId = try mintUniqueUploadOperationId()
                try persist(item)
            } else if requiresLegacyReconciliation(item) {
                let recoveryStage = item.resumeState ?? item.state
                item.state = .conflict
                item.resumeState = recoveryStage
                item.nextAttemptAt = nil
                item.issue = JazzArchiveUploadIssue(
                    code: "ARCHIVE_UPLOAD_OPERATION_RECONCILIATION_REQUIRED",
                    message:
                        "This legacy delivery may already have reached the server; reconcile it before any retry."
                )
                item.updatedAt = Timestamps.iso8601()
                try persist(item)
            }
        }
        try assertUniqueOperationId(for: item)
        return item
    }

    private func canMintOperationId(for item: JazzArchiveUploadItem) -> Bool {
        item.attempt == 0
            && item.ingestId == nil
            && item.uploadReceipt == nil
            && [.queued, .reconnectRequired, .cancelled].contains(item.state)
    }

    private func requiresLegacyReconciliation(_ item: JazzArchiveUploadItem) -> Bool {
        item.schemaVersion == 1
            && item.uploadOperationId == nil
            && (!item.state.isTerminal || item.state == .cancelled)
            && item.state != .conflict
    }

    private func mintUniqueUploadOperationId() throws -> String {
        let existing = try persistedOperationIds()
        for _ in 0..<16 {
            let candidate = Identifiers.newUploadOperationId()
            if !existing.contains(candidate) { return candidate }
        }
        throw JazzArchiveUploadError.invalidServerResponse(
            "ARCHIVE_UPLOAD_OPERATION_ID_EXHAUSTED")
    }

    private func persistedOperationIds(excluding archiveId: String? = nil) throws -> Set<String> {
        guard fileManager.fileExists(atPath: recordsRoot.path) else { return [] }
        var values: Set<String> = []
        for url in try fileManager.contentsOfDirectory(
            at: recordsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let storedArchiveId = object["archiveId"] as? String
            else {
                throw JazzArchiveUploadError.invalidItem(
                    url.deletingPathExtension().lastPathComponent)
            }
            guard url.deletingPathExtension().lastPathComponent == storedArchiveId else {
                throw JazzArchiveUploadError.invalidItem(storedArchiveId)
            }
            if let archiveId, url.standardizedFileURL == recordURL(archiveId).standardizedFileURL {
                continue
            }
            if let operationId = object["uploadOperationId"] as? String {
                guard JazzArchiveUploadItem.isUploadOperationId(operationId),
                    values.insert(operationId).inserted
                else {
                    throw JazzArchiveUploadError.invalidItem(storedArchiveId)
                }
            }
        }
        return values
    }

    private func assertUniqueOperationId(for item: JazzArchiveUploadItem) throws {
        guard let operationId = item.uploadOperationId else { return }
        guard try !persistedOperationIds(excluding: item.archiveId).contains(operationId) else {
            throw JazzArchiveUploadError.invalidItem(item.archiveId)
        }
    }

    private func persist(_ item: JazzArchiveUploadItem) throws {
        do {
            try item.validate()
            try assertUniqueOperationId(for: item)
            try prepareDirectories()
            let url = recordURL(item.archiveId)
            let data = try Self.encoder.encode(item)
            try data.write(to: url, options: [.atomic])
            try synchronizeRecordDurably(item)
        } catch let error as JazzArchiveUploadError {
            throw error
        } catch {
            throw JazzArchiveUploadError.persistenceFailed(item.archiveId)
        }
    }

    private func prepareDirectories() throws {
        let recordsWereMissing = !fileManager.fileExists(atPath: recordsRoot.path)
        let packagesWereMissing = !fileManager.fileExists(atPath: packagesRoot.path)
        do {
            try fileManager.createDirectory(at: recordsRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: packagesRoot, withIntermediateDirectories: true)
            if recordsWereMissing {
                try durability.synchronizeDirectory(recordsRoot)
            }
            if packagesWereMissing {
                try durability.synchronizeDirectory(packagesRoot)
            }
            // The native lease may have created `root` before this actor entered the critical
            // section, so absence cannot be inferred here. Committing both directory levels is
            // cheap and guarantees the queue root plus its child directories survive power loss.
            try durability.synchronizeDirectory(root)
            try durability.synchronizeDirectory(root.deletingLastPathComponent())
        } catch {
            throw JazzArchiveUploadError.persistenceFailed(root.path)
        }
    }

    private func synchronizeRecordDurably(
        _ item: JazzArchiveUploadItem
    ) throws {
        do {
            try durability.synchronizeRegularFile(
                recordURL(item.archiveId),
                permissions: Int16(0o600))
            try durability.synchronizeDirectory(recordsRoot)
            try durability.synchronizeDirectory(root)
        } catch {
            throw JazzArchiveUploadError.persistenceFailed(item.archiveId)
        }
    }

    private func synchronizePackageDurably(
        _ item: JazzArchiveUploadItem
    ) throws {
        do {
            try durability.synchronizeRegularFile(
                packageURL(item),
                permissions: Int16(0o400))
            try durability.synchronizeDirectory(packagesRoot)
            try durability.synchronizeDirectory(root)
        } catch {
            throw JazzArchiveUploadError.persistenceFailed(item.archiveId)
        }
    }

    private func acquireLease() throws -> any JazzArchiveFilesystemLease {
        do {
            return try leaseProvider.acquire(
                root: root,
                fileManager: fileManager)
        } catch JazzArchiveFilesystemLeaseError.inProgress {
            throw JazzArchiveUploadError.operationInProgress
        } catch {
            throw JazzArchiveUploadError.persistenceFailed(root.path)
        }
    }

    private var recordsRoot: URL { root.appendingPathComponent("records", isDirectory: true) }
    private var packagesRoot: URL { root.appendingPathComponent("packages", isDirectory: true) }
    private func recordURL(_ archiveId: String) -> URL {
        recordsRoot.appendingPathComponent("\(archiveId).json")
    }
    private func packageURL(_ item: JazzArchiveUploadItem) -> URL {
        packagesRoot.appendingPathComponent(item.packageFileName)
    }
}

// MARK: - Transport-neutral upload workflow

/// A token wrapper that deliberately has no Codable/Equatable conformance and always redacts its
/// textual representation. The value is exposed only to the injected HTTP adapter at call time.
public struct JazzArchiveScopedDeviceCredential: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    private let value: String

    public init(_ value: String) throws {
        guard !value.isEmpty else { throw JazzArchiveUploadError.credentialUnavailable }
        self.value = value
    }

    public var description: String { "<redacted scoped device credential>" }
    public var debugDescription: String { description }

    public func withValue<Result>(_ body: (String) throws -> Result) rethrows -> Result {
        try body(value)
    }
}

public protocol JazzArchiveCredentialProvider: Sendable {
    func credential(
        for routeBinding: JazzArchiveUploadRouteBinding
    ) async throws -> JazzArchiveScopedDeviceCredential
}

public struct JazzArchiveUploadIntentRequest: Equatable, Sendable {
    public let uploadOperationId: String
    public let archiveId: String
    public let originId: String
    public let formatVersion: Int
    public let revision: Int
    public let contentDigest: String
    public let rawSHA256: String
    public let byteLength: Int64
    public let scope: JazzArchiveUploadScope
}

/// One deliberately operation-id-less lookup used only to reconcile an ambiguous queue-v1 record.
/// The authenticated server must return its already-bound stable v2 operation id and the exact
/// immutable archive tuple. Ordinary capture and retry paths never construct this request.
public struct JazzArchiveLegacyUploadReconciliationRequest: Equatable, Sendable {
    public let archiveId: String
    public let originId: String
    public let formatVersion: Int
    public let revision: Int
    public let contentDigest: String
    public let rawSHA256: String
    public let byteLength: Int64
    public let scope: JazzArchiveUploadScope
}

public struct JazzArchiveOpaqueUploadInstructions: Equatable, Sendable {
    public let transport: String
    public let values: [String: JazzArchiveJSONValue]

    public init(transport: String, values: [String: JazzArchiveJSONValue]) throws {
        guard !transport.isEmpty else {
            throw JazzArchiveUploadError.invalidServerResponse("ARCHIVE_UPLOAD_GRANT_INVALID")
        }
        self.transport = transport
        self.values = values
    }
}

/// Strict, provider-neutral interpretation of the only direct-upload profile supported by the
/// desktop client. This value is deliberately not Codable: signed URLs and signed headers must
/// live only for the duration of the current network attempt.
public struct JazzArchiveHTTPPutGrant: Equatable, Sendable {
    public static let transport = "http-put/v1"

    public let url: URL
    public let headers: [String: String]
    public let receiptHeader: String

    public init(instructions: JazzArchiveOpaqueUploadInstructions) throws {
        guard instructions.transport == Self.transport else {
            throw Self.invalid("ARCHIVE_UPLOAD_TRANSPORT_UNSUPPORTED")
        }
        let values = instructions.values
        let allowed = Set(["method", "url", "headers", "receiptHeader"])
        guard Set(values.keys).isSubset(of: allowed),
            values["method"] == .string("PUT"),
            case .string(let rawURL)? = values["url"],
            case .string(let receiptHeader)? = values["receiptHeader"]
        else {
            throw Self.invalid("ARCHIVE_UPLOAD_INSTRUCTIONS_INVALID")
        }
        self.url = try Self.validateURL(rawURL)
        self.headers = try Self.validateHeaders(values["headers"])
        guard Self.isHeaderName(receiptHeader) else {
            throw Self.invalid("ARCHIVE_UPLOAD_RECEIPT_HEADER_INVALID")
        }
        self.receiptHeader = receiptHeader
    }

    /// Validates the exact receipt value before it becomes durable queue state or a finalize body.
    public static func validateReceipt(_ value: String) throws -> String {
        guard !value.isEmpty,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            value.utf8.count <= 8_192,
            value.unicodeScalars.allSatisfy({
                $0.value >= 0x20 && $0.value != 0x7f
            })
        else {
            throw Self.invalid("ARCHIVE_UPLOAD_RECEIPT_INVALID")
        }
        return value
    }

    private static func validateURL(_ value: String) throws -> URL {
        guard !value.isEmpty,
            value.utf8.count <= 16_384,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.contains("\\"),
            value.unicodeScalars.allSatisfy({
                !$0.properties.isWhitespace
                    && !CharacterSet.controlCharacters.contains($0)
                    && $0.value != 0x7f
            }),
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            components.fragment == nil,
            components.port.map({ (1...65_535).contains($0) }) ?? true,
            let url = components.url,
            url.host?.isEmpty == false
        else {
            throw Self.invalid("ARCHIVE_UPLOAD_URL_INVALID")
        }
        return url
    }

    private static func validateHeaders(
        _ value: JazzArchiveJSONValue?
    ) throws -> [String: String] {
        guard let value else { return [:] }
        guard case .object(let rawHeaders) = value, rawHeaders.count <= 32 else {
            throw Self.invalid("ARCHIVE_UPLOAD_HEADERS_INVALID")
        }
        let forbidden = Set([
            "connection", "content-length", "host", "keep-alive",
            "proxy-authenticate", "proxy-authorization", "te", "trailer",
            "transfer-encoding", "upgrade",
        ])
        var headers: [String: String] = [:]
        var normalizedNames: Set<String> = []
        var aggregateBytes = 0
        for (name, rawValue) in rawHeaders {
            let normalizedName = name.lowercased()
            guard Self.isHeaderName(name),
                !forbidden.contains(normalizedName),
                normalizedNames.insert(normalizedName).inserted,
                case .string(let text) = rawValue,
                text.utf8.count <= 8_192,
                !text.contains("\r"),
                !text.contains("\n"),
                text.unicodeScalars.allSatisfy({
                    ($0.value >= 0x20 || $0.value == 0x09) && $0.value != 0x7f
                })
            else {
                throw Self.invalid("ARCHIVE_UPLOAD_HEADERS_INVALID")
            }
            aggregateBytes += name.utf8.count + text.utf8.count
            guard aggregateBytes <= 32_768 else {
                throw Self.invalid("ARCHIVE_UPLOAD_HEADERS_TOO_LARGE")
            }
            headers[name] = text
        }
        return headers
    }

    private static func isHeaderName(_ value: String) -> Bool {
        value.utf8.count <= 128
            && value.range(
                of: #"^[!#$%&'*+\-.^_`|~0-9A-Za-z]{1,128}$"#,
                options: .regularExpression) != nil
    }

    private static func invalid(_ code: String) -> JazzArchiveUploadError {
        .invalidServerResponse(code)
    }
}

/// Narrow compatibility detector for a mixed rollout where an older FastAPI replica still
/// rejects the new caller-owned field as an extra body input. Only this exact validation shape is
/// retryable; no request is ever retried without its durable operation identity.
public enum JazzArchiveUploadServerCompatibility {
    public static let operationIdContractNotReadyCode =
        "ARCHIVE_UPLOAD_OPERATION_ID_CONTRACT_NOT_READY"

    public static func rejectsUploadOperationId(
        statusCode: Int,
        responseBody: Data,
        expectedOperationId: String
    ) -> Bool {
        guard statusCode == 422,
            JazzArchiveUploadItem.isUploadOperationId(expectedOperationId),
            let root = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
            let details = root["detail"] as? [[String: Any]],
            details.count == 1,
            let detail = details.first,
            detail["type"] as? String == "extra_forbidden",
            let location = detail["loc"] as? [String],
            location == ["body", "uploadOperationId"]
        else { return false }
        if let input = detail["input"] {
            return input as? String == expectedOperationId
        }
        return true
    }
}

public enum JazzArchiveRemoteState: String, Codable, Equatable, Sendable {
    case created
    case uploaded
    case validating
    case validated
    case importing
    case ready
    case failedRetryable = "failed_retryable"
    case failedTerminal = "failed_terminal"
    case rejected
    case quarantined
}

public struct JazzArchiveRemoteStatus: Equatable, Sendable {
    /// `nil` represents an otherwise decodable response from a pre-operation-id server replica.
    /// A present but malformed or mismatched value remains a hard identity conflict.
    public let uploadOperationId: String?
    public let ingestId: String
    public let state: JazzArchiveRemoteState
    public let archiveId: String
    public let originId: String
    public let formatVersion: Int
    public let revision: Int
    public let contentDigest: String
    public let rawSHA256: String
    public let byteLength: Int64
    public let errorCode: String?
    public let nextAttemptAt: String?

    public init(
        uploadOperationId: String?,
        ingestId: String,
        state: JazzArchiveRemoteState,
        archiveId: String,
        originId: String,
        formatVersion: Int,
        revision: Int,
        contentDigest: String,
        rawSHA256: String,
        byteLength: Int64,
        errorCode: String? = nil,
        nextAttemptAt: String? = nil
    ) {
        self.uploadOperationId = uploadOperationId
        self.ingestId = ingestId
        self.state = state
        self.archiveId = archiveId
        self.originId = originId
        self.formatVersion = formatVersion
        self.revision = revision
        self.contentDigest = contentDigest
        self.rawSHA256 = rawSHA256
        self.byteLength = byteLength
        self.errorCode = errorCode
        self.nextAttemptAt = nextAttemptAt
    }
}

public struct JazzArchiveUploadIntentResponse: Equatable, Sendable {
    public let status: JazzArchiveRemoteStatus
    public let upload: JazzArchiveOpaqueUploadInstructions?

    public init(
        status: JazzArchiveRemoteStatus,
        upload: JazzArchiveOpaqueUploadInstructions?
    ) {
        self.status = status
        self.upload = upload
    }
}

public protocol JazzArchiveUploadControlPlane: Sendable {
    var routeBinding: JazzArchiveUploadRouteBinding { get }

    func createIntent(
        _ request: JazzArchiveUploadIntentRequest,
        credential: JazzArchiveScopedDeviceCredential
    ) async throws -> JazzArchiveUploadIntentResponse

    func reconcileLegacyIntent(
        _ request: JazzArchiveLegacyUploadReconciliationRequest,
        credential: JazzArchiveScopedDeviceCredential
    ) async throws -> JazzArchiveUploadIntentResponse

    func finalize(
        ingestId: String,
        uploadOperationId: String,
        scope: JazzArchiveUploadScope,
        uploadReceipt: String,
        credential: JazzArchiveScopedDeviceCredential
    ) async throws -> JazzArchiveRemoteStatus

    func status(
        ingestId: String,
        scope: JazzArchiveUploadScope,
        credential: JazzArchiveScopedDeviceCredential
    ) async throws -> JazzArchiveRemoteStatus
}

/// The object-store grant stays opaque to the queue and control plane. A transport adapter may
/// interpret it in memory, but must not persist a signed URL or provider credential.
public protocol JazzArchiveDirectUploadTransport: Sendable {
    func upload(
        file: URL,
        instructions: JazzArchiveOpaqueUploadInstructions
    ) async throws -> String
}

/// Deterministic retry timing shared by the durable coordinator and the app scheduler.
///
/// Ordinary transport/provider failures use a bounded exponential delay multiplied by stable
/// per-operation jitter. The jitter comes from the durable `uploadOperationId`, not process-local
/// randomness, so independent archives spread across the retry window while one archive computes
/// the same schedule after relaunch. The selected absolute timestamp is then committed to the queue
/// record. A server-provided `nextAttemptAt` remains authoritative and bypasses this local policy.
public enum JazzArchiveUploadRetryPolicy {
    private static let initialDelayMilliseconds: UInt64 = 2_000
    private static let maximumDelayMilliseconds: UInt64 = 300_000
    /// Retain at least 75% of the exponential delay. The closed 75–100% window keeps every retry
    /// positive, preserves the hard cap, and still spreads archives by up to 75 seconds at the cap.
    private static let jitterFloorBasisPoints: UInt64 = 7_500
    private static let jitterBasisPointCount: UInt64 = 2_501
    private static let basisPointDenominator: UInt64 = 10_000
    private static let jitterDomain = "jazz-archive-upload-retry-jitter/v1\u{0}"
    private static let processingPollSeconds: TimeInterval = 2
    private static let minimumSchedulerDelaySeconds: TimeInterval = 0.1

    public static func localNextAttemptAt(
        after timestamp: String,
        failedAttempt: Int,
        uploadOperationId: String
    ) throws -> String {
        guard let anchor = Timestamps.parse(timestamp), failedAttempt >= 0 else {
            throw JazzArchiveUploadError.invalidItem("archive retry timestamp")
        }
        guard JazzArchiveUploadItem.isUploadOperationId(uploadOperationId) else {
            throw JazzArchiveUploadError.invalidItem("archive retry upload operation id")
        }
        let exponent = min(max(failedAttempt - 1, 0), 8)
        let exponentialMultiplier = UInt64(1) << UInt64(exponent)
        let exponentialDelay = min(
            initialDelayMilliseconds * exponentialMultiplier,
            maximumDelayMilliseconds)
        let digest = JazzArchiveDigest.sha256Hex(
            Data((jitterDomain + uploadOperationId).utf8))
        guard let sample = UInt64(digest.prefix(16), radix: 16) else {
            throw JazzArchiveUploadError.invalidItem("archive retry jitter")
        }
        let jitterBasisPoints =
            jitterFloorBasisPoints + sample % jitterBasisPointCount
        let delayMilliseconds =
            exponentialDelay * jitterBasisPoints / basisPointDenominator
        return Timestamps.iso8601(
            anchor.addingTimeInterval(TimeInterval(delayMilliseconds) / 1_000))
    }

    /// Earliest time at which the app should run another pass. A retryable legacy record without
    /// a watermark is scheduled immediately once, allowing the coordinator to migrate it to a
    /// durable local backoff instead of leaving it stranded until another UI event.
    public static func nextAutomaticFollowUp(
        for items: [JazzArchiveUploadItem],
        now: Date = Date()
    ) -> Date? {
        items.compactMap { item -> Date? in
            switch item.state {
            case .verifying, .processing:
                return now.addingTimeInterval(processingPollSeconds)
            case .retryable:
                let earliest = now.addingTimeInterval(minimumSchedulerDelaySeconds)
                guard let retryAt = Timestamps.parse(item.nextAttemptAt) else {
                    return earliest
                }
                return max(retryAt, earliest)
            default:
                return nil
            }
        }.min()
    }
}

public struct JazzArchiveUploadPassFailure: Equatable, Sendable {
    public let archiveId: String
    public let message: String

    public init(archiveId: String, message: String) {
        self.archiveId = archiveId
        self.message = message
    }
}

/// Serial per-archive fault isolation for one delivery pass. A damaged or missing local package
/// remains visible in its own durable queue state but cannot prevent a later archive from
/// progressing. Structured task cancellation always terminates the pass and is never converted
/// into an item failure.
public enum JazzArchiveUploadPassRunner {
    public static func drain(
        _ items: [JazzArchiveUploadItem],
        operation: (JazzArchiveUploadItem) async throws -> Void
    ) async throws -> [JazzArchiveUploadPassFailure] {
        var failures: [JazzArchiveUploadPassFailure] = []
        for item in items {
            try Task.checkCancellation()
            do {
                try await operation(item)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                failures.append(JazzArchiveUploadPassFailure(
                    archiveId: item.archiveId,
                    message: safeMessage(error)))
            }
        }
        return failures
    }

    private static func safeMessage(_ error: Error) -> String {
        if let value = error as? JazzArchiveUploadError { return value.description }
        return "Archive delivery is temporarily unavailable; local bytes are safe."
    }
}

/// Advances durable deliveries without ever owning canonical evidence. Every retry re-verifies the
/// queue-owned package fingerprint and reads a fresh credential from the injected runtime provider.
public actor JazzArchiveUploadCoordinator {
    private let queue: JazzArchiveUploadQueue
    private let credentials: any JazzArchiveCredentialProvider
    private let controlPlane: any JazzArchiveUploadControlPlane
    private let objectTransport: any JazzArchiveDirectUploadTransport
    private let now: @Sendable () -> String

    public init(
        queue: JazzArchiveUploadQueue,
        credentials: any JazzArchiveCredentialProvider,
        controlPlane: any JazzArchiveUploadControlPlane,
        objectTransport: any JazzArchiveDirectUploadTransport,
        now: @escaping @Sendable () -> String = { Timestamps.iso8601() }
    ) {
        self.queue = queue
        self.credentials = credentials
        self.controlPlane = controlPlane
        self.objectTransport = objectTransport
        self.now = now
    }

    @discardableResult
    public func runNext() async throws -> JazzArchiveUploadItem? {
        guard let item = try await queue.nextRunnable() else { return nil }
        return try await run(archiveId: item.archiveId)
    }

    @discardableResult
    public func run(archiveId: String) async throws -> JazzArchiveUploadItem {
        guard let item = try await queue.item(archiveId: archiveId) else {
            throw JazzArchiveUploadError.missing(archiveId)
        }
        let currentDate = Timestamps.parse(now()) ?? Date()
        guard item.canRunAutomatically(at: currentDate) else { return item }
        do {
            // The queue-owned immutable package is the local authority for every runnable stage.
            // Verify it before even pinning delivery routing, so a missing or changed package
            // cannot advance local delivery state and cannot be masked by a later fsync failure.
            _ = try await queue.packageURL(archiveId: archiveId)
            let bound = try await queue.bindRoute(
                archiveId: archiveId,
                routeBinding: controlPlane.routeBinding,
                at: now())
            switch bound.state {
            case .finalizing:
                return try await finalize(bound)
            case .verifying, .processing:
                return try await poll(bound)
            case .retryable:
                switch bound.resumeState {
                case .finalizing where bound.ingestId != nil && bound.uploadReceipt != nil:
                    _ = try await queue.retry(archiveId: archiveId, at: now())
                    return try await finalize(try await requiredItem(archiveId))
                case .verifying where bound.ingestId != nil,
                    .processing where bound.ingestId != nil:
                    _ = try await queue.retry(archiveId: archiveId, at: now())
                    return try await poll(try await requiredItem(archiveId))
                default:
                    return try await createIntent(bound)
                }
            case .queued, .creatingIntent, .uploading:
                return try await createIntent(bound)
            case .ready, .reconnectRequired, .failedTerminal, .rejected, .quarantined,
                .conflict, .cancelled:
                return item
            }
        } catch let error as JazzArchiveUploadError {
            return try await handle(error, archiveId: archiveId)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return try await markOrdinaryRetryable(
                archiveId: archiveId,
                code: "ARCHIVE_DELIVERY_UNAVAILABLE",
                resumeState: nil)
        }
    }

    /// Explicit user-driven migration for a queue-v1 record whose prior network outcome is
    /// ambiguous. Exactly one authenticated request omits the operation id; the client adopts only
    /// the server-returned v2 id after validating the full immutable tuple, then immediately
    /// continues through the ordinary exact-operation path.
    @discardableResult
    public func reconcileLegacy(archiveId: String) async throws -> JazzArchiveUploadItem {
        guard let initial = try await queue.item(archiveId: archiveId) else {
            throw JazzArchiveUploadError.missing(archiveId)
        }
        guard initial.schemaVersion == 1,
            initial.uploadOperationId == nil,
            initial.state == .conflict,
            initial.issue?.code == "ARCHIVE_UPLOAD_OPERATION_RECONCILIATION_REQUIRED"
        else { throw JazzArchiveUploadError.invalidItem(archiveId) }
        guard let scope = initial.scope else {
            throw JazzArchiveUploadError.invalidItem(archiveId)
        }
        let prepared = try await queue.prepareLegacyReconciliation(
            archiveId: archiveId,
            routeBinding: controlPlane.routeBinding,
            at: now())
        let credential = try await credential(for: prepared)
        let response = try await controlPlane.reconcileLegacyIntent(
            JazzArchiveLegacyUploadReconciliationRequest(
                archiveId: prepared.archiveId,
                originId: prepared.originId,
                formatVersion: prepared.formatVersion,
                revision: prepared.revision,
                contentDigest: prepared.contentDigest,
                rawSHA256: prepared.rawSHA256,
                byteLength: prepared.byteLength,
                scope: scope),
            credential: credential)
        try validateLegacyReconciliation(response.status, against: prepared)
        guard let operationId = response.status.uploadOperationId else {
            throw JazzArchiveUploadError.retryable(
                JazzArchiveUploadServerCompatibility.operationIdContractNotReadyCode)
        }
        _ = try await queue.adoptLegacyReconciliation(
            archiveId: archiveId,
            uploadOperationId: operationId,
            ingestId: response.status.ingestId,
            at: now())
        return try await run(archiveId: archiveId)
    }

    private func createIntent(
        _ prior: JazzArchiveUploadItem
    ) async throws -> JazzArchiveUploadItem {
        guard let scope = prior.scope else {
            return try await queue.markReconnectRequired(
                archiveId: prior.archiveId,
                code: "ARCHIVE_SCOPE_UNAVAILABLE",
                resumeState: .queued,
                at: now())
        }
        guard let uploadOperationId = prior.uploadOperationId else {
            throw JazzArchiveUploadError.invalidItem(prior.archiveId)
        }
        _ = try await queue.beginIntent(archiveId: prior.archiveId, at: now())
        let current = try await requiredItem(prior.archiveId)
        let credential = try await credential(for: current)
        let response = try await controlPlane.createIntent(
            JazzArchiveUploadIntentRequest(
                uploadOperationId: uploadOperationId,
                archiveId: current.archiveId,
                originId: current.originId,
                formatVersion: current.formatVersion,
                revision: current.revision,
                contentDigest: current.contentDigest,
                rawSHA256: current.rawSHA256,
                byteLength: current.byteLength,
                scope: scope),
            credential: credential)
        try validate(response.status, against: current)
        switch response.status.state {
        case .created:
            guard let upload = response.upload else {
                throw JazzArchiveUploadError.invalidServerResponse(
                    "ARCHIVE_UPLOAD_GRANT_MISSING")
            }
            _ = try await queue.setIntent(
                archiveId: current.archiveId,
                ingestId: response.status.ingestId,
                state: .uploading,
                at: now())
            guard try await queue.item(archiveId: current.archiveId)?.state == .uploading else {
                return try await requiredItem(current.archiveId)
            }
            let file = try await queue.packageURL(archiveId: current.archiveId)
            let receipt = try await objectTransport.upload(file: file, instructions: upload)
            guard try await queue.item(archiveId: current.archiveId)?.state == .uploading else {
                return try await requiredItem(current.archiveId)
            }
            _ = try await queue.setUploadReceipt(
                archiveId: current.archiveId, receipt: receipt, at: now())
            return try await finalize(try await requiredItem(current.archiveId))
        default:
            let local = localState(response.status.state)
            let persistedState: JazzArchiveUploadState =
                [.retryable, .failedTerminal, .rejected, .quarantined, .ready].contains(local)
                ? .processing : local
            _ = try await queue.setIntent(
                archiveId: current.archiveId,
                ingestId: response.status.ingestId,
                state: persistedState,
                at: now())
            return try await apply(response.status, to: current.archiveId)
        }
    }

    private func finalize(_ item: JazzArchiveUploadItem) async throws -> JazzArchiveUploadItem {
        guard let scope = item.scope,
            let ingestId = item.ingestId,
            let uploadOperationId = item.uploadOperationId,
            let receipt = item.uploadReceipt
        else { throw JazzArchiveUploadError.invalidItem(item.archiveId) }
        let credential = try await credential(for: item)
        let response = try await controlPlane.finalize(
            ingestId: ingestId,
            uploadOperationId: uploadOperationId,
            scope: scope,
            uploadReceipt: receipt,
            credential: credential)
        try validate(response, against: item)
        return try await apply(response, to: item.archiveId)
    }

    private func poll(_ item: JazzArchiveUploadItem) async throws -> JazzArchiveUploadItem {
        guard let scope = item.scope, let ingestId = item.ingestId else {
            throw JazzArchiveUploadError.invalidItem(item.archiveId)
        }
        let credential = try await credential(for: item)
        let response = try await controlPlane.status(
            ingestId: ingestId, scope: scope, credential: credential)
        try validate(response, against: item)
        return try await apply(response, to: item.archiveId)
    }

    private func apply(
        _ status: JazzArchiveRemoteStatus,
        to archiveId: String
    ) async throws -> JazzArchiveUploadItem {
        switch status.state {
        case .created:
            return try await markOrdinaryRetryable(
                archiveId: archiveId,
                code: status.errorCode ?? "ARCHIVE_UPLOAD_GRANT_REQUIRED",
                resumeState: .creatingIntent)
        case .uploaded:
            return try await queue.setIntent(
                archiveId: archiveId,
                ingestId: status.ingestId,
                state: .verifying,
                at: now())
        case .validating, .validated, .importing:
            return try await queue.setIntent(
                archiveId: archiveId,
                ingestId: status.ingestId,
                state: .processing,
                at: now())
        case .ready:
            return try await queue.applyTerminal(
                archiveId: archiveId,
                state: .ready,
                code: nil,
                at: now())
        case .failedRetryable:
            return try await markOrdinaryRetryable(
                archiveId: archiveId,
                code: status.errorCode ?? "ARCHIVE_PROCESSING_RETRYABLE",
                resumeState: .verifying,
                authoritativeNextAttemptAt: status.nextAttemptAt)
        case .failedTerminal:
            return try await queue.applyTerminal(
                archiveId: archiveId,
                state: .failedTerminal,
                code: status.errorCode ?? "ARCHIVE_PROCESSING_FAILED_TERMINAL",
                at: now())
        case .rejected:
            return try await queue.applyTerminal(
                archiveId: archiveId,
                state: .rejected,
                code: status.errorCode ?? "ARCHIVE_REJECTED",
                at: now())
        case .quarantined:
            return try await queue.applyTerminal(
                archiveId: archiveId,
                state: .quarantined,
                code: status.errorCode ?? "ARCHIVE_QUARANTINED",
                at: now())
        }
    }

    private func handle(
        _ error: JazzArchiveUploadError,
        archiveId: String
    ) async throws -> JazzArchiveUploadItem {
        let current = try await requiredItem(archiveId)
        if current.state == .cancelled { return current }
        switch error {
        case .credentialUnavailable, .credentialExpired, .credentialBindingMismatch:
            return try await queue.markReconnectRequired(
                archiveId: archiveId,
                code: error == .credentialExpired
                    ? "ARCHIVE_TOKEN_EXPIRED"
                    : error == .credentialBindingMismatch
                        ? "ARCHIVE_ENROLLMENT_BINDING_CHANGED"
                        : "ARCHIVE_AUTH_REQUIRED",
                resumeState: resumeState(for: current),
                at: now())
        case .tokenRejected(let code):
            return try await queue.markReconnectRequired(
                archiveId: archiveId,
                code: code,
                resumeState: resumeState(for: current),
                at: now())
        case .retryable(let code):
            return try await markOrdinaryRetryable(
                archiveId: archiveId,
                code: code,
                resumeState: resumeState(for: current))
        case .rejected(let code):
            return try await queue.applyTerminal(
                archiveId: archiveId, state: .rejected, code: code, at: now())
        case .quarantined(let code):
            return try await queue.applyTerminal(
                archiveId: archiveId, state: .quarantined, code: code, at: now())
        case .scopeClaimMismatch(let code), .conflict(let code),
            .invalidServerResponse(let code):
            return try await queue.markConflict(archiveId: archiveId, code: code, at: now())
        case .routeAlreadyBound, .routeBindingMissing:
            return try await queue.markConflict(
                archiveId: archiveId,
                code: "ARCHIVE_ROUTE_BINDING_CONFLICT",
                at: now())
        case .archiveCollision, .packageChanged:
            return try await queue.markConflict(
                archiveId: archiveId, code: "ARCHIVE_LOCAL_INTEGRITY_CONFLICT", at: now())
        case .invalidItem, .missing, .packageMissing, .persistenceFailed,
            .operationInProgress, .invalidTransition, .scopeAlreadyBound:
            throw error
        }
    }

    private func credential(
        for item: JazzArchiveUploadItem
    ) async throws -> JazzArchiveScopedDeviceCredential {
        guard let routeBinding = item.routeBinding else {
            throw JazzArchiveUploadError.routeBindingMissing(item.archiveId)
        }
        return try await credentials.credential(for: routeBinding)
    }

    private func validate(
        _ status: JazzArchiveRemoteStatus,
        against item: JazzArchiveUploadItem
    ) throws {
        guard !status.ingestId.isEmpty,
            status.archiveId == item.archiveId,
            status.originId == item.originId,
            status.formatVersion == item.formatVersion,
            status.revision == item.revision,
            status.contentDigest == item.contentDigest,
            status.rawSHA256 == item.rawSHA256,
            status.byteLength == item.byteLength
        else {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_RESPONSE_IDENTITY_MISMATCH")
        }
        if let ingestId = item.ingestId, ingestId != status.ingestId {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_RESPONSE_INGEST_MISMATCH")
        }
        if let nextAttemptAt = status.nextAttemptAt,
            status.state != .failedRetryable || Timestamps.parse(nextAttemptAt) == nil
        {
            throw JazzArchiveUploadError.invalidServerResponse("NEXT_ATTEMPT_AT_INVALID")
        }
        guard let uploadOperationId = status.uploadOperationId else {
            throw JazzArchiveUploadError.retryable(
                JazzArchiveUploadServerCompatibility.operationIdContractNotReadyCode)
        }
        guard uploadOperationId == item.uploadOperationId else {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_RESPONSE_IDENTITY_MISMATCH")
        }
    }

    private func validateLegacyReconciliation(
        _ status: JazzArchiveRemoteStatus,
        against item: JazzArchiveUploadItem
    ) throws {
        guard !status.ingestId.isEmpty,
            status.archiveId == item.archiveId,
            status.originId == item.originId,
            status.formatVersion == item.formatVersion,
            status.revision == item.revision,
            status.contentDigest == item.contentDigest,
            status.rawSHA256 == item.rawSHA256,
            status.byteLength == item.byteLength
        else {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_RESPONSE_IDENTITY_MISMATCH")
        }
        if let ingestId = item.ingestId, ingestId != status.ingestId {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_RESPONSE_INGEST_MISMATCH")
        }
        guard let operationId = status.uploadOperationId else {
            throw JazzArchiveUploadError.retryable(
                JazzArchiveUploadServerCompatibility.operationIdContractNotReadyCode)
        }
        guard JazzArchiveUploadItem.isUploadOperationId(operationId) else {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_UPLOAD_RECONCILIATION_ID_INVALID")
        }
    }

    private func localState(_ remote: JazzArchiveRemoteState) -> JazzArchiveUploadState {
        switch remote {
        case .created: .creatingIntent
        case .uploaded: .verifying
        case .validating, .validated, .importing: .processing
        case .ready: .ready
        case .failedRetryable: .retryable
        case .failedTerminal: .failedTerminal
        case .rejected: .rejected
        case .quarantined: .quarantined
        }
    }

    private func resumeState(for item: JazzArchiveUploadItem) -> JazzArchiveUploadState {
        switch item.state {
        case .finalizing: .finalizing
        case .verifying: .verifying
        case .processing: .processing
        case .retryable, .reconnectRequired: item.resumeState ?? .queued
        default: .creatingIntent
        }
    }

    private func markOrdinaryRetryable(
        archiveId: String,
        code: String,
        resumeState requestedResumeState: JazzArchiveUploadState?,
        authoritativeNextAttemptAt: String? = nil
    ) async throws -> JazzArchiveUploadItem {
        let current = try await requiredItem(archiveId)
        let at = now()
        let retryAt: String
        if let authoritativeNextAttemptAt {
            retryAt = authoritativeNextAttemptAt
        } else {
            guard let uploadOperationId = current.uploadOperationId else {
                throw JazzArchiveUploadError.invalidItem(archiveId)
            }
            retryAt = try JazzArchiveUploadRetryPolicy.localNextAttemptAt(
                after: at,
                failedAttempt: current.attempt,
                uploadOperationId: uploadOperationId)
        }
        return try await queue.markRetryable(
            archiveId: archiveId,
            code: code,
            resumeState: requestedResumeState ?? resumeState(for: current),
            nextAttemptAt: retryAt,
            at: at)
    }

    private func requiredItem(_ archiveId: String) async throws -> JazzArchiveUploadItem {
        guard let item = try await queue.item(archiveId: archiveId) else {
            throw JazzArchiveUploadError.missing(archiveId)
        }
        return item
    }
}

/// Deterministically finalizes a confirmed revision and places exactly one immutable ZIP in the
/// whole-archive queue. It performs no network operation.
public actor JazzArchiveConfirmedDelivery {
    private let finalizer: JazzArchiveFinalizer
    private let queue: JazzArchiveUploadQueue
    private let fileManager: FileManager

    public init(
        archiveRoot: URL,
        queue: JazzArchiveUploadQueue,
        durability: JazzArchiveFilesystemDurability,
        fileManager: FileManager = .default
    ) {
        self.finalizer = JazzArchiveFinalizer(
            root: archiveRoot,
            durability: durability,
            fileManager: fileManager)
        self.queue = queue
        self.fileManager = fileManager
    }

    @discardableResult
    public func enqueueConfirmed(
        archiveId: String,
        scope: JazzArchiveUploadScope?,
        snapshotAt: String = Timestamps.iso8601()
    ) async throws -> JazzArchiveUploadItem {
        let package = try await finalizer.finalize(
            archiveId: archiveId,
            snapshotAt: snapshotAt,
            requireArchiveConfirmation: true)
        guard let contentDigest = package.manifest.contentDigest else {
            throw JazzArchiveUploadError.invalidItem(archiveId)
        }
        if let scope {
            try scope.validateArchiveClaims(
                manifest: package.manifest,
                sessions: try sessions(in: package))
        }
        let stagingRoot = queue.root.appendingPathComponent("staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staging = stagingRoot.appendingPathComponent(
            ".\(archiveId).\(Identifiers.newUUIDv7().uuidString.lowercased()).jazz-archive")
        defer { try? fileManager.removeItem(at: staging) }
        try await finalizer.export(package, to: staging)
        return try await queue.enqueue(
            file: staging,
            archiveId: archiveId,
            originId: package.manifest.originId,
            captureIds: package.manifest.sessions.map(\.captureId),
            formatVersion: package.manifest.formatVersion,
            revision: package.manifest.revision,
            contentDigest: contentDigest,
            scope: scope,
            queuedAt: snapshotAt)
    }

    /// Bind a rotated/new enrollment only after re-verifying the immutable package's provenance
    /// claims against it. This prevents a pre-enrollment non-General capture from reaching the
    /// network under an unrelated Area merely because the queue previously lacked scope metadata.
    @discardableResult
    public func bindScope(
        archiveId: String,
        scope: JazzArchiveUploadScope,
        at: String = Timestamps.iso8601()
    ) async throws -> JazzArchiveUploadItem {
        let package = try await finalizer.finalize(
            archiveId: archiveId,
            snapshotAt: at,
            requireArchiveConfirmation: true)
        try scope.validateArchiveClaims(
            manifest: package.manifest,
            sessions: try sessions(in: package))
        return try await queue.bindScope(archiveId: archiveId, scope: scope, at: at)
    }

    private func sessions(
        in package: JazzArchiveFinalizedPackage
    ) throws -> [JazzArchiveSession] {
        let decoder = JSONDecoder()
        return try package.manifest.sessions.map { reference in
            let session = try decoder.decode(
                JazzArchiveSession.self,
                from: Data(contentsOf: package.url.appendingPathComponent(reference.path)))
            guard session.captureId == reference.captureId,
                session.archiveId == package.manifest.archiveId
            else {
                throw JazzArchiveUploadError.invalidItem(package.manifest.archiveId)
            }
            return session
        }
    }
}
