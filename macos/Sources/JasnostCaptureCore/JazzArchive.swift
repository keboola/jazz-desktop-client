import Foundation

/// Lossless carrier for contract-defined `extensions` objects. Unknown future evidence survives a
/// Swift decode/encode cycle instead of being silently discarded by synthesized Codable models.
public indirect enum JazzArchiveJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case string(String)
    case array([JazzArchiveJSONValue])
    case object([String: JazzArchiveJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JazzArchiveJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JazzArchiveJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsignedInteger(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Canonical manifest

/// Swift mirror of `contract/archive/schema/archive-manifest.schema.json`.
///
/// The archive preserves the existing ActivityEvent as its payload; it does not change the live
/// ActivityEvent schema or its OTLP projection. `archiveId` is opaque identity, while digests
/// describe content and are always kept separate from that identity.
public struct JazzArchiveManifest: Codable, Equatable, Sendable {
    public static let expectedFormat = "dev.jazz.archive"
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var archiveId: String
    public var originId: String
    public var enrolledDeviceIdentity: JazzArchiveExternalIdentity?
    public var revision: Int
    public var supersedesArchiveId: String?
    public var originScope: JazzArchiveExternalIdentity?
    public var state: JazzArchiveState
    public var createdAt: String
    public var snapshotAt: String?
    public var contentDigest: String?
    public var producer: JazzArchiveProducer
    public var contracts: [JazzArchiveContract]
    public var actors: [JazzArchiveActor]
    public var sources: [JazzArchiveSource]
    public var sessions: [JazzArchiveSessionRef]
    public var captureCommits: [JazzArchiveCaptureCommitRef]?
    public var inventory: JazzArchiveInventoryRef
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        format: String = JazzArchiveManifest.expectedFormat,
        formatVersion: Int = JazzArchiveManifest.currentFormatVersion,
        archiveId: String = Identifiers.newArchiveId(),
        originId: String = Identifiers.newOriginId(),
        enrolledDeviceIdentity: JazzArchiveExternalIdentity? = nil,
        revision: Int = 1,
        supersedesArchiveId: String? = nil,
        originScope: JazzArchiveExternalIdentity? = nil,
        state: JazzArchiveState = .live,
        createdAt: String = Timestamps.iso8601(),
        snapshotAt: String? = nil,
        contentDigest: String? = nil,
        producer: JazzArchiveProducer,
        contracts: [JazzArchiveContract] = [.activityEvent],
        actors: [JazzArchiveActor],
        sources: [JazzArchiveSource],
        sessions: [JazzArchiveSessionRef],
        captureCommits: [JazzArchiveCaptureCommitRef]? = nil,
        inventory: JazzArchiveInventoryRef = .draftPlaceholder,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.archiveId = archiveId
        self.originId = originId
        self.enrolledDeviceIdentity = enrolledDeviceIdentity
        self.revision = revision
        self.supersedesArchiveId = supersedesArchiveId
        self.originScope = originScope
        self.state = state
        self.createdAt = createdAt
        self.snapshotAt = snapshotAt
        self.contentDigest = contentDigest
        self.producer = producer
        self.contracts = contracts
        self.actors = actors
        self.sources = sources
        self.sessions = sessions
        self.captureCommits = captureCommits
        self.inventory = inventory
        self.extensions = extensions
    }

    public func validate() throws {
        guard format == Self.expectedFormat else {
            throw JazzArchiveError.invalidConstant(field: "format", value: format)
        }
        guard formatVersion == Self.currentFormatVersion else {
            throw JazzArchiveError.unsupportedFormatVersion(formatVersion)
        }
        try JazzArchiveValidation.archiveId(archiveId)
        try JazzArchiveValidation.originId(originId)
        try enrolledDeviceIdentity?.validate()
        guard revision >= 1 else { throw JazzArchiveError.invalidCount(revision) }
        if let supersedesArchiveId {
            try JazzArchiveValidation.archiveId(supersedesArchiveId)
        }
        try originScope?.validate()
        try JazzArchiveValidation.timestamp(createdAt, field: "createdAt")
        if let snapshotAt { try JazzArchiveValidation.timestamp(snapshotAt, field: "snapshotAt") }
        if let contentDigest { try JazzArchiveValidation.sha256(contentDigest, field: "contentDigest") }
        switch state {
        case .live:
            guard snapshotAt == nil, contentDigest == nil else {
                throw JazzArchiveError.invalidState("live archive has finalized fields")
            }
        case .finalized:
            guard snapshotAt != nil, contentDigest != nil, captureCommits != nil else {
                throw JazzArchiveError.invalidState("finalized archive lacks snapshot/digest/commit")
            }
        }

        try producer.validate()
        guard !contracts.isEmpty else { throw JazzArchiveError.invalidField("contracts") }
        try JazzArchiveValidation.unique(contracts.map(\.recordType), kind: "contract recordType")
        for contract in contracts { try contract.validate() }

        try JazzArchiveValidation.unique(actors.map(\.actorId), kind: "actor")
        try JazzArchiveValidation.unique(sources.map(\.sourceId), kind: "source")
        try JazzArchiveValidation.unique(sessions.map(\.captureId), kind: "capture")
        try JazzArchiveValidation.unique(sessions.map(\.path), kind: "session path")
        for actor in actors { try actor.validate() }
        for source in sources { try source.validate() }
        guard !sessions.isEmpty else { throw JazzArchiveError.invalidField("sessions") }
        for session in sessions { try session.validate() }
        if let captureCommits {
            guard !captureCommits.isEmpty else {
                throw JazzArchiveError.invalidField("captureCommits")
            }
            try JazzArchiveValidation.unique(
                captureCommits.map(\.commitId), kind: "capture commit")
            try JazzArchiveValidation.unique(
                captureCommits.map(\.captureId), kind: "capture commit capture")
            try JazzArchiveValidation.unique(
                captureCommits.map(\.path), kind: "capture commit path")
            let captureIds = Set(sessions.map(\.captureId))
            for commit in captureCommits {
                try commit.validate()
                guard captureIds.contains(commit.captureId) else {
                    throw JazzArchiveError.missingReference(
                        kind: "capture", id: commit.captureId)
                }
            }
        }
        try inventory.validate()

        let actorIds = Set(actors.map(\.actorId))
        let sourceIds = Set(sources.map(\.sourceId))
        for actor in actors {
            try JazzArchiveValidation.provenanceSources(actor.provenance, sourceIds: sourceIds)
        }
        for source in sources {
            if let actorId = source.actorId, !actorIds.contains(actorId) {
                throw JazzArchiveError.missingReference(kind: "actor", id: actorId)
            }
            try JazzArchiveValidation.provenanceSources(source.provenance, sourceIds: sourceIds)
        }
    }
}

public enum JazzArchiveState: String, Codable, Equatable, Sendable {
    case live
    case finalized
}

public struct JazzArchiveProducer: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var build: String?
    public var platform: String?
    public var model: String?

    public init(
        name: String,
        version: String,
        build: String? = nil,
        platform: String? = nil,
        model: String? = nil
    ) {
        self.name = name
        self.version = version
        self.build = build
        self.platform = platform
        self.model = model
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.nonempty(name, field: "producer.name")
        try JazzArchiveValidation.nonempty(version, field: "producer.version")
    }
}

public struct JazzArchiveContract: Codable, Equatable, Sendable {
    public var recordType: String
    public var schemaId: String
    public var schemaVersion: Int

    public init(recordType: String, schemaId: String, schemaVersion: Int) {
        self.recordType = recordType
        self.schemaId = schemaId
        self.schemaVersion = schemaVersion
    }

    public static let activityEvent = JazzArchiveContract(
        recordType: "jazz.activity-event",
        schemaId: "https://jasnost.dev/schema/activity-event.schema.json",
        schemaVersion: 1)

    public static let mediaObservation = JazzArchiveContract(
        recordType: "jazz.media-observation",
        schemaId: "https://jasnost.dev/schema/media-observation.schema.json",
        schemaVersion: 1)

    fileprivate func validate() throws {
        try JazzArchiveValidation.token(recordType, field: "contract.recordType")
        guard let url = URL(string: schemaId), url.scheme != nil else {
            throw JazzArchiveError.invalidURI(field: "contract.schemaId", value: schemaId)
        }
        guard schemaVersion >= 1 else { throw JazzArchiveError.invalidCount(schemaVersion) }
    }
}

public struct JazzArchiveSessionRef: Codable, Equatable, Sendable {
    public var captureId: String
    public var legacySessionId: String?
    public var path: String

    public init(captureId: String, legacySessionId: String? = nil, path: String? = nil) {
        self.captureId = captureId
        self.legacySessionId = legacySessionId
        self.path = path ?? "sessions/\(legacySessionId ?? captureId)/session.json"
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.captureId(captureId)
        if let legacySessionId { try JazzArchiveValidation.sessionId(legacySessionId) }
        try JazzArchiveValidation.relativePath(path)
    }
}

public struct JazzArchiveCaptureCommitRef: Codable, Equatable, Sendable {
    public var commitId: String
    public var captureId: String
    public var path: String
    public var digest: String

    public init(commitId: String, captureId: String, path: String, digest: String) {
        self.commitId = commitId
        self.captureId = captureId
        self.path = path
        self.digest = digest
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.commitId(commitId)
        try JazzArchiveValidation.captureId(captureId)
        try JazzArchiveValidation.relativePath(path)
        try JazzArchiveValidation.sha256(digest, field: "captureCommit.digest")
    }
}

public struct JazzArchiveInventoryRef: Codable, Equatable, Sendable {
    public var path: String
    public var algorithm: String
    public var digest: String

    public init(path: String = "inventory.json", algorithm: String = "sha256", digest: String) {
        self.path = path
        self.algorithm = algorithm
        self.digest = digest
    }

    /// `create` replaces this syntactically valid sentinel with the digest of its first inventory.
    public static let draftPlaceholder = JazzArchiveInventoryRef(
        digest: String(repeating: "0", count: 64))

    fileprivate func validate() throws {
        try JazzArchiveValidation.relativePath(path)
        guard algorithm == "sha256" else {
            throw JazzArchiveError.invalidConstant(field: "inventory.algorithm", value: algorithm)
        }
        try JazzArchiveValidation.sha256(digest, field: "inventory.digest")
    }
}

// MARK: - Actor and source identity

public struct JazzArchiveExternalIdentity: Codable, Equatable, Hashable, Sendable {
    public var namespace: String
    public var value: String

    public init(namespace: String, value: String) {
        self.namespace = namespace
        self.value = value
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.nonempty(namespace, field: "externalIdentity.namespace")
        try JazzArchiveValidation.nonempty(value, field: "externalIdentity.value")
    }
}

public enum JazzArchiveActorKind: String, Codable, Equatable, Sendable {
    case human
    case agent
    case service
    case system
    case unknown
}

public enum JazzArchiveIdentityStatus: String, Codable, Equatable, Sendable {
    case identified
    case anonymous
    case unknown
}

/// WHO performed the work. Human claims are separate from the opaque archive-scoped actor id.
public struct JazzArchiveActor: Codable, Equatable, Sendable {
    public var actorId: String
    public var kind: JazzArchiveActorKind
    public var identityStatus: JazzArchiveIdentityStatus
    public var identityReason: String?
    public var displayName: String?
    public var externalIdentities: [JazzArchiveExternalIdentity]?
    public var provenance: JazzArchiveProvenance
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        actorId: String = Identifiers.newActorId(),
        kind: JazzArchiveActorKind,
        identityStatus: JazzArchiveIdentityStatus = .identified,
        identityReason: String? = nil,
        displayName: String? = nil,
        externalIdentities: [JazzArchiveExternalIdentity]? = nil,
        provenance: JazzArchiveProvenance,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.actorId = actorId
        self.kind = kind
        self.identityStatus = identityStatus
        self.identityReason = identityReason
        self.displayName = displayName
        self.externalIdentities = externalIdentities
        self.provenance = provenance
        self.extensions = extensions
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.actorId(actorId)
        if identityStatus == .unknown {
            guard let identityReason else {
                throw JazzArchiveError.invalidField("actor.identityReason")
            }
            try JazzArchiveValidation.nonempty(identityReason, field: "actor.identityReason")
            guard displayName == nil, externalIdentities == nil else {
                throw JazzArchiveError.invalidField("unknown actor identity metadata")
            }
        }
        if let identities = externalIdentities {
            guard Set(identities).count == identities.count else {
                throw JazzArchiveError.duplicateIdentifier(kind: "external identity", id: actorId)
            }
            for identity in identities { try identity.validate() }
        }
        try provenance.validate()
    }
}

public struct JazzArchiveClock: Codable, Equatable, Sendable {
    public var wallClock: String
    public var monotonicClock: String?
    public var clockDomainId: String?
    public var bootId: String?
    public var timeZone: String?
    public var estimatedSkewMillis: Double?

    public init(
        wallClock: String,
        monotonicClock: String? = nil,
        clockDomainId: String? = nil,
        bootId: String? = nil,
        timeZone: String? = nil,
        estimatedSkewMillis: Double? = nil
    ) {
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.clockDomainId = clockDomainId
        self.bootId = bootId
        self.timeZone = timeZone
        self.estimatedSkewMillis = estimatedSkewMillis
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.nonempty(wallClock, field: "clock.wallClock")
        let monotonicFields = [monotonicClock, clockDomainId, bootId].compactMap { $0 }.count
        guard monotonicFields == 0 || monotonicFields == 3 else {
            throw JazzArchiveError.invalidField("clock monotonic domain")
        }
        if let monotonicClock {
            try JazzArchiveValidation.nonempty(monotonicClock, field: "clock.monotonicClock")
            try JazzArchiveValidation.nonempty(clockDomainId!, field: "clock.clockDomainId")
            try JazzArchiveValidation.nonempty(bootId!, field: "clock.bootId")
        }
        if let estimatedSkewMillis, estimatedSkewMillis < 0 {
            throw JazzArchiveError.invalidNumber(field: "clock.estimatedSkewMillis")
        }
    }
}

public struct JazzArchiveMonotonicTime: Codable, Equatable, Sendable {
    public var ticks: String
    public var unit: String
    public var clockId: String
    public var clockDomainId: String
    public var bootId: String

    public init(
        ticks: String,
        unit: String,
        clockId: String,
        clockDomainId: String,
        bootId: String
    ) {
        self.ticks = ticks
        self.unit = unit
        self.clockId = clockId
        self.clockDomainId = clockDomainId
        self.bootId = bootId
    }

    fileprivate func validate() throws {
        guard !ticks.isEmpty, ticks.allSatisfy(\.isNumber) else {
            throw JazzArchiveError.invalidField("monotonicTime.ticks")
        }
        try JazzArchiveValidation.nonempty(unit, field: "monotonicTime.unit")
        try JazzArchiveValidation.nonempty(clockId, field: "monotonicTime.clockId")
        try JazzArchiveValidation.nonempty(
            clockDomainId, field: "monotonicTime.clockDomainId")
        try JazzArchiveValidation.nonempty(bootId, field: "monotonicTime.bootId")
    }
}

public struct JazzArchiveContextRefs: Codable, Equatable, Sendable {
    public var engagement: JazzArchiveExternalIdentity?
    public var meeting: JazzArchiveExternalIdentity?
    public var conversation: JazzArchiveExternalIdentity?

    public init(
        engagement: JazzArchiveExternalIdentity? = nil,
        meeting: JazzArchiveExternalIdentity? = nil,
        conversation: JazzArchiveExternalIdentity? = nil
    ) {
        self.engagement = engagement
        self.meeting = meeting
        self.conversation = conversation
    }

    fileprivate func validate() throws {
        guard engagement != nil || meeting != nil || conversation != nil else {
            throw JazzArchiveError.invalidField("contextRefs")
        }
        try engagement?.validate()
        try meeting?.validate()
        try conversation?.validate()
    }
}

/// WHICH collector/device observed the work. `kind` is intentionally extensible (for example
/// `macos.cg-event`, `macos.accessibility`, or `microphone`).
public struct JazzArchiveSource: Codable, Equatable, Sendable {
    public var sourceId: String
    public var kind: String
    public var actorId: String?
    public var producer: JazzArchiveProducer
    public var deviceId: String?
    public var externalIdentities: [JazzArchiveExternalIdentity]?
    public var clock: JazzArchiveClock?
    public var capabilities: [String]
    public var unavailableCapabilities: [JazzArchiveUnavailableCapability]
    public var provenance: JazzArchiveProvenance
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        sourceId: String = Identifiers.newSourceId(),
        kind: String,
        actorId: String? = nil,
        producer: JazzArchiveProducer,
        deviceId: String? = nil,
        externalIdentities: [JazzArchiveExternalIdentity]? = nil,
        clock: JazzArchiveClock? = nil,
        capabilities: [String] = [],
        unavailableCapabilities: [JazzArchiveUnavailableCapability] = [],
        provenance: JazzArchiveProvenance,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.sourceId = sourceId
        self.kind = kind
        self.actorId = actorId
        self.producer = producer
        self.deviceId = deviceId
        self.externalIdentities = externalIdentities
        self.clock = clock
        self.capabilities = capabilities
        self.unavailableCapabilities = unavailableCapabilities
        self.provenance = provenance
        self.extensions = extensions
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.sourceId(sourceId)
        try JazzArchiveValidation.token(kind, field: "source.kind")
        if let actorId { try JazzArchiveValidation.actorId(actorId) }
        try producer.validate()
        if let identities = externalIdentities {
            guard Set(identities).count == identities.count else {
                throw JazzArchiveError.duplicateIdentifier(kind: "external identity", id: sourceId)
            }
            for identity in identities { try identity.validate() }
        }
        try clock?.validate()
        try JazzArchiveValidation.unique(capabilities, kind: "source capability")
        for capability in capabilities {
            try JazzArchiveValidation.token(capability, field: "source.capability")
        }
        try JazzArchiveValidation.unique(
            unavailableCapabilities.map(\.capability), kind: "unavailable source capability")
        for unavailable in unavailableCapabilities { try unavailable.validate() }
        let available = Set(capabilities)
        guard unavailableCapabilities.allSatisfy({ !available.contains($0.capability) }) else {
            throw JazzArchiveError.invalidField("source capability both available and unavailable")
        }
        try provenance.validate()
    }
}

public enum JazzArchiveCapabilityUnavailableReason: String, Codable, Equatable, Sendable {
    case notSupported = "not_supported"
    case permissionDenied = "permission_denied"
    case disabledByPolicy = "disabled_by_policy"
    case temporarilyUnavailable = "temporarily_unavailable"
    case notRequested = "not_requested"
    case unknown
}

public struct JazzArchiveUnavailableCapability: Codable, Equatable, Sendable {
    public var capability: String
    public var reason: JazzArchiveCapabilityUnavailableReason
    public var detail: String?

    public init(
        capability: String,
        reason: JazzArchiveCapabilityUnavailableReason,
        detail: String? = nil
    ) {
        self.capability = capability
        self.reason = reason
        self.detail = detail
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.token(capability, field: "unavailableCapability.capability")
    }
}

// MARK: - Provenance, quality, and privacy

public enum JazzArchiveFactClass: String, Codable, Equatable, Sendable {
    case observed
    case declared
    case imported
    case derived
    case corrected
}

public struct JazzArchiveTransformation: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var at: String

    public init(name: String, version: String, at: String) {
        self.name = name
        self.version = version
        self.at = at
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.nonempty(name, field: "transformation.name")
        try JazzArchiveValidation.nonempty(version, field: "transformation.version")
        try JazzArchiveValidation.timestamp(at, field: "transformation.at")
    }
}

public struct JazzArchiveProvenance: Codable, Equatable, Sendable {
    public var factClass: JazzArchiveFactClass
    public var sources: [String]
    public var transformations: [JazzArchiveTransformation]?

    public init(
        factClass: JazzArchiveFactClass,
        sources: [String],
        transformations: [JazzArchiveTransformation]? = nil
    ) {
        self.factClass = factClass
        self.sources = sources
        self.transformations = transformations
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.unique(sources, kind: "provenance source")
        for source in sources { try JazzArchiveValidation.sourceId(source) }
        if let transformations {
            for transformation in transformations { try transformation.validate() }
        }
    }
}

public enum JazzArchiveQualityStatus: String, Codable, Equatable, Sendable {
    case complete
    case partial
    case missing
    case invalid
}

public struct JazzArchiveQuality: Codable, Equatable, Sendable {
    public var status: JazzArchiveQualityStatus
    public var reasons: [String]
    public var timingErrorMillis: Double?
    public var confidence: Double?
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        status: JazzArchiveQualityStatus,
        reasons: [String] = [],
        timingErrorMillis: Double? = nil,
        confidence: Double? = nil,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.status = status
        self.reasons = reasons
        self.timingErrorMillis = timingErrorMillis
        self.confidence = confidence
        self.extensions = extensions
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.unique(reasons, kind: "quality reason")
        for reason in reasons { try JazzArchiveValidation.token(reason, field: "quality.reason") }
        if let timingErrorMillis, timingErrorMillis < 0 {
            throw JazzArchiveError.invalidNumber(field: "quality.timingErrorMillis")
        }
        if let confidence, !(0...1).contains(confidence) {
            throw JazzArchiveError.invalidNumber(field: "quality.confidence")
        }
    }
}

public enum JazzArchivePrivacyStatus: String, Codable, Equatable, Sendable {
    case captured
    case masked
    case omitted
    case denied
    case unknown
}

public enum JazzArchiveRedactionAction: String, Codable, Equatable, Sendable {
    case masked
    case omitted
}

public struct JazzArchiveRedaction: Codable, Equatable, Sendable {
    public var path: String
    public var action: JazzArchiveRedactionAction
    public var reason: String

    public init(path: String, action: JazzArchiveRedactionAction, reason: String) {
        self.path = path
        self.action = action
        self.reason = reason
    }

    fileprivate func validate() throws {
        guard path.hasPrefix("/") else { throw JazzArchiveError.invalidJSONPointer(path) }
        try JazzArchiveValidation.nonempty(reason, field: "privacy.redaction.reason")
    }
}

public struct JazzArchivePrivacy: Codable, Equatable, Sendable {
    public var status: JazzArchivePrivacyStatus
    public var policyVersion: String
    public var redactions: [JazzArchiveRedaction]

    public init(
        status: JazzArchivePrivacyStatus,
        policyVersion: String,
        redactions: [JazzArchiveRedaction] = []
    ) {
        self.status = status
        self.policyVersion = policyVersion
        self.redactions = redactions
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.nonempty(policyVersion, field: "privacy.policyVersion")
        for redaction in redactions { try redaction.validate() }
    }
}

// MARK: - Session document

public enum JazzArchiveSessionStatus: String, Codable, Equatable, Sendable {
    case open
    case closed
    case interrupted
    case recovered
}

public struct JazzArchiveArea: Codable, Equatable, Sendable {
    public var areaId: String
    public var nameSnapshot: String
    public var registryRevision: String?

    public init(areaId: String, nameSnapshot: String, registryRevision: String? = nil) {
        self.areaId = areaId
        self.nameSnapshot = nameSnapshot
        self.registryRevision = registryRevision
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.nonempty(areaId, field: "session.area.areaId")
        try JazzArchiveValidation.nonempty(nameSnapshot, field: "session.area.nameSnapshot")
    }
}

public enum JazzArchiveModality: String, Codable, Equatable, Sendable {
    case pointer
    case keyboard
    case accessibility
    case screenshots
    case narration
    case screenShareVideo = "screen_share_video"
    case meetingAudio = "meeting_audio"
    case meetingMetadata = "meeting_metadata"
    case transcript
    case browserDOM = "browser_dom"
}

public struct JazzArchiveCapturePolicy: Codable, Equatable, Sendable {
    public var policyVersion: String
    public var consentedAt: String
    public var modalities: [JazzArchiveModality]
    public var excludedApplications: [String]
    public var businessDataCapture: Bool

    public init(
        policyVersion: String,
        consentedAt: String,
        modalities: [JazzArchiveModality],
        excludedApplications: [String],
        businessDataCapture: Bool
    ) {
        self.policyVersion = policyVersion
        self.consentedAt = consentedAt
        self.modalities = modalities
        self.excludedApplications = excludedApplications
        self.businessDataCapture = businessDataCapture
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.nonempty(policyVersion, field: "capturePolicy.policyVersion")
        try JazzArchiveValidation.timestamp(consentedAt, field: "capturePolicy.consentedAt")
        try JazzArchiveValidation.unique(modalities.map(\.rawValue), kind: "capture modality")
        try JazzArchiveValidation.unique(excludedApplications, kind: "excluded application")
    }
}

/// Swift mirror of `contract/archive/schema/archive-session.schema.json`.
public struct JazzArchiveSession: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var captureId: String
    public var legacySessionId: String?
    public var archiveId: String
    public var streamIds: [String]
    public var startedAt: String
    public var endedAt: String?
    public var status: JazzArchiveSessionStatus
    public var sessionKind: String?
    public var recorderActorId: String
    public var sourceIds: [String]
    public var contextRefs: JazzArchiveContextRefs?
    public var area: JazzArchiveArea?
    public var capturePolicy: JazzArchiveCapturePolicy
    public var clock: JazzArchiveClock?
    public var captureCommit: JazzArchiveCaptureCommitRef?
    public var quality: JazzArchiveQuality
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        schemaVersion: Int = 1,
        captureId: String,
        legacySessionId: String? = nil,
        archiveId: String,
        streamIds: [String],
        startedAt: String,
        endedAt: String? = nil,
        status: JazzArchiveSessionStatus = .open,
        sessionKind: String? = nil,
        recorderActorId: String,
        sourceIds: [String],
        contextRefs: JazzArchiveContextRefs? = nil,
        area: JazzArchiveArea? = nil,
        capturePolicy: JazzArchiveCapturePolicy,
        clock: JazzArchiveClock? = nil,
        captureCommit: JazzArchiveCaptureCommitRef? = nil,
        quality: JazzArchiveQuality,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.captureId = captureId
        self.legacySessionId = legacySessionId
        self.archiveId = archiveId
        self.streamIds = streamIds
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.sessionKind = sessionKind
        self.recorderActorId = recorderActorId
        self.sourceIds = sourceIds
        self.contextRefs = contextRefs
        self.area = area
        self.capturePolicy = capturePolicy
        self.clock = clock
        self.captureCommit = captureCommit
        self.quality = quality
        self.extensions = extensions
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw JazzArchiveError.unsupportedSchemaVersion(type: "session", version: schemaVersion)
        }
        try JazzArchiveValidation.captureId(captureId)
        if let legacySessionId { try JazzArchiveValidation.sessionId(legacySessionId) }
        try JazzArchiveValidation.archiveId(archiveId)
        guard !streamIds.isEmpty else { throw JazzArchiveError.invalidField("session.streamIds") }
        try JazzArchiveValidation.unique(streamIds, kind: "session stream")
        for streamId in streamIds { try JazzArchiveValidation.streamId(streamId) }
        try JazzArchiveValidation.timestamp(startedAt, field: "session.startedAt")
        if let endedAt { try JazzArchiveValidation.timestamp(endedAt, field: "session.endedAt") }
        if status == .closed, endedAt == nil || captureCommit == nil {
            throw JazzArchiveError.invalidState("closed session lacks endedAt/captureCommit")
        }
        if status == .open, endedAt != nil || captureCommit != nil {
            throw JazzArchiveError.invalidState("open session has closure fields")
        }
        if let sessionKind {
            try JazzArchiveValidation.nonempty(sessionKind, field: "session.sessionKind")
        }
        try JazzArchiveValidation.actorId(recorderActorId)
        guard !sourceIds.isEmpty else { throw JazzArchiveError.invalidField("session.sourceIds") }
        try JazzArchiveValidation.unique(sourceIds, kind: "session source")
        for sourceId in sourceIds { try JazzArchiveValidation.sourceId(sourceId) }
        try contextRefs?.validate()
        try area?.validate()
        try capturePolicy.validate()
        try clock?.validate()
        if let captureCommit {
            try captureCommit.validate()
            guard captureCommit.captureId == captureId else {
                throw JazzArchiveError.referenceMismatch(
                    field: "session.captureCommit.captureId",
                    expected: captureId,
                    actual: captureCommit.captureId)
            }
        }
        try quality.validate()
    }
}

// MARK: - Archive record

public struct JazzArchiveSourceRef: Codable, Equatable, Sendable {
    public var sourceId: String
    public var role: String

    public init(sourceId: String, role: String) {
        self.sourceId = sourceId
        self.role = role
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.sourceId(sourceId)
        try JazzArchiveValidation.token(role, field: "sourceRef.role")
    }
}

public enum JazzArchiveActorRefBasis: String, Codable, Equatable, Sendable {
    case observed
    case declared
}

public struct JazzArchiveActorRef: Codable, Equatable, Sendable {
    public var actorId: String
    public var role: String
    public var basis: JazzArchiveActorRefBasis
    public var method: String?

    public init(
        actorId: String,
        role: String,
        basis: JazzArchiveActorRefBasis,
        method: String? = nil
    ) {
        self.actorId = actorId
        self.role = role
        self.basis = basis
        self.method = method
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.actorId(actorId)
        try JazzArchiveValidation.token(role, field: "actorRef.role")
    }
}

public struct JazzArchiveArtifactRef: Codable, Equatable, Sendable {
    public var artifactId: String
    public var role: String

    public init(artifactId: String, role: String) {
        self.artifactId = artifactId
        self.role = role
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.artifactId(artifactId)
        try JazzArchiveValidation.token(role, field: "artifactRef.role")
    }
}

// MARK: - Canonical artifacts

public enum JazzArchiveArtifactOrigin: String, Codable, Equatable, Sendable {
    case captured
    case imported
    case derived
}

public struct JazzArchiveArtifactContent: Codable, Equatable, Sendable {
    public var path: String
    public var mediaType: String
    public var byteLength: Int64
    public var sha256: String

    public init(path: String, mediaType: String, byteLength: Int64, sha256: String) {
        self.path = path
        self.mediaType = mediaType
        self.byteLength = byteLength
        self.sha256 = sha256
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.relativePath(path)
        guard mediaType.contains("/"), !mediaType.contains(where: \.isWhitespace) else {
            throw JazzArchiveError.invalidField("artifact.content.mediaType")
        }
        guard byteLength >= 0 else {
            throw JazzArchiveError.invalidNumber(field: "artifact.content.byteLength")
        }
        try JazzArchiveValidation.sha256(sha256, field: "artifact.content.sha256")
        let expected = "blobs/sha256/\(sha256.prefix(2))/\(sha256)"
        guard path == expected else {
            throw JazzArchiveError.referenceMismatch(
                field: "artifact.content.path", expected: expected, actual: path)
        }
    }
}

public struct JazzArchiveArtifactCaptureInterval: Codable, Equatable, Sendable {
    public var startedAt: String
    public var endedAt: String?

    public init(startedAt: String, endedAt: String? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.timestamp(startedAt, field: "artifact.captureInterval.startedAt")
        if let endedAt {
            try JazzArchiveValidation.timestamp(endedAt, field: "artifact.captureInterval.endedAt")
        }
    }
}

public enum JazzArchiveGenericRefKind: String, Codable, Equatable, Sendable {
    case archive
    case capture
    case commit
    case label
    case observation
    case artifact
    case assertion
    case actor
    case source
}

public struct JazzArchiveGenericRef: Codable, Equatable, Sendable {
    public var kind: JazzArchiveGenericRefKind
    public var id: String

    public init(kind: JazzArchiveGenericRefKind, id: String) {
        self.kind = kind
        self.id = id
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.nonempty(id, field: "genericRef.id")
    }
}

public struct JazzArchiveArtifactDerivation: Codable, Equatable, Sendable {
    public var producer: JazzArchiveProducer
    public var computedAt: String
    public var inputRefs: [JazzArchiveGenericRef]
    public var parametersDigest: String?

    public init(
        producer: JazzArchiveProducer,
        computedAt: String,
        inputRefs: [JazzArchiveGenericRef],
        parametersDigest: String? = nil
    ) {
        self.producer = producer
        self.computedAt = computedAt
        self.inputRefs = inputRefs
        self.parametersDigest = parametersDigest
    }

    fileprivate func validate() throws {
        try producer.validate()
        try JazzArchiveValidation.timestamp(computedAt, field: "artifact.derivation.computedAt")
        guard !inputRefs.isEmpty else {
            throw JazzArchiveError.invalidField("artifact.derivation.inputRefs")
        }
        for ref in inputRefs { try ref.validate() }
        if let parametersDigest {
            try JazzArchiveValidation.sha256(
                parametersDigest, field: "artifact.derivation.parametersDigest")
        }
    }
}

/// Canonical artifact metadata. Captured bytes live once at a content-addressed path and are
/// inventoried together with this document. Remote Files ids deliberately do not appear here;
/// those are mutable delivery state, not evidence identity.
public struct JazzArchiveArtifact: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var artifactId: String
    public var captureId: String
    public var origin: JazzArchiveArtifactOrigin
    public var kind: String
    public var contentSchema: String?
    public var content: JazzArchiveArtifactContent
    public var sourceRefs: [JazzArchiveSourceRef]
    public var actorRefs: [JazzArchiveActorRef]
    public var labelRefs: [String]
    public var observationRefs: [String]
    public var captureInterval: JazzArchiveArtifactCaptureInterval?
    public var derivation: JazzArchiveArtifactDerivation?
    public var provenance: JazzArchiveProvenance
    public var quality: JazzArchiveQuality
    public var privacy: JazzArchivePrivacy
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        schemaVersion: Int = 1,
        artifactId: String,
        captureId: String,
        origin: JazzArchiveArtifactOrigin = .captured,
        kind: String,
        contentSchema: String? = nil,
        content: JazzArchiveArtifactContent,
        sourceRefs: [JazzArchiveSourceRef],
        actorRefs: [JazzArchiveActorRef] = [],
        labelRefs: [String] = [],
        observationRefs: [String] = [],
        captureInterval: JazzArchiveArtifactCaptureInterval? = nil,
        derivation: JazzArchiveArtifactDerivation? = nil,
        provenance: JazzArchiveProvenance,
        quality: JazzArchiveQuality,
        privacy: JazzArchivePrivacy,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.artifactId = artifactId
        self.captureId = captureId
        self.origin = origin
        self.kind = kind
        self.contentSchema = contentSchema
        self.content = content
        self.sourceRefs = sourceRefs
        self.actorRefs = actorRefs
        self.labelRefs = labelRefs
        self.observationRefs = observationRefs
        self.captureInterval = captureInterval
        self.derivation = derivation
        self.provenance = provenance
        self.quality = quality
        self.privacy = privacy
        self.extensions = extensions
    }

    public func validate(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws {
        guard schemaVersion == 1 else {
            throw JazzArchiveError.unsupportedSchemaVersion(type: "artifact", version: schemaVersion)
        }
        try JazzArchiveValidation.artifactId(artifactId)
        try JazzArchiveValidation.captureId(captureId)
        guard captureId == session.captureId, session.archiveId == manifest.archiveId else {
            throw JazzArchiveError.referenceMismatch(
                field: "artifact.captureId", expected: session.captureId, actual: captureId)
        }
        try JazzArchiveValidation.token(kind, field: "artifact.kind")
        if let contentSchema {
            guard let url = URL(string: contentSchema), url.scheme != nil else {
                throw JazzArchiveError.invalidURI(
                    field: "artifact.contentSchema", value: contentSchema)
            }
        }
        try content.validate()
        let sourceIds = Set(manifest.sources.map(\.sourceId))
        for ref in sourceRefs {
            try ref.validate()
            guard sourceIds.contains(ref.sourceId) else {
                throw JazzArchiveError.missingReference(kind: "source", id: ref.sourceId)
            }
        }
        let actorIds = Set(manifest.actors.map(\.actorId))
        for ref in actorRefs {
            try ref.validate()
            guard actorIds.contains(ref.actorId) else {
                throw JazzArchiveError.missingReference(kind: "actor", id: ref.actorId)
            }
        }
        try JazzArchiveValidation.unique(labelRefs, kind: "artifact label reference")
        for ref in labelRefs { try JazzArchiveValidation.labelId(ref) }
        try JazzArchiveValidation.unique(observationRefs, kind: "artifact observation reference")
        for ref in observationRefs { try JazzArchiveValidation.observationId(ref) }
        try captureInterval?.validate()
        if origin == .derived {
            guard let derivation else {
                throw JazzArchiveError.invalidField("artifact.derivation")
            }
            try derivation.validate()
            guard provenance.factClass == .derived else {
                throw JazzArchiveError.invalidField("artifact.provenance.factClass")
            }
        } else if derivation != nil {
            throw JazzArchiveError.invalidField("artifact.derivation")
        }
        try provenance.validate()
        try JazzArchiveValidation.provenanceSources(provenance, sourceIds: sourceIds)
        try quality.validate()
        try privacy.validate()
    }
}

// MARK: - Append-only human review assertions

public enum JazzArchiveAssertionTargetKind: String, Codable, Equatable, Sendable {
    case archive
    case capture
    case label
    case observation
    case artifact
    case assertion
}

public struct JazzArchiveAssertionTarget: Codable, Equatable, Sendable {
    public var kind: JazzArchiveAssertionTargetKind
    public var id: String
    public var path: String?

    public init(kind: JazzArchiveAssertionTargetKind, id: String, path: String? = nil) {
        self.kind = kind
        self.id = id
        self.path = path
    }

    fileprivate func validate(manifest: JazzArchiveManifest) throws {
        switch kind {
        case .archive:
            try JazzArchiveValidation.archiveId(id)
            guard id == manifest.archiveId else {
                throw JazzArchiveError.missingReference(kind: "archive", id: id)
            }
        case .capture:
            try JazzArchiveValidation.captureId(id)
            guard manifest.sessions.contains(where: { $0.captureId == id }) else {
                throw JazzArchiveError.missingReference(kind: "capture", id: id)
            }
        case .label: try JazzArchiveValidation.labelId(id)
        case .observation: try JazzArchiveValidation.observationId(id)
        case .artifact: try JazzArchiveValidation.artifactId(id)
        case .assertion: try JazzArchiveValidation.assertionId(id)
        }
        if let path {
            guard path.hasPrefix("/") else {
                throw JazzArchiveError.invalidField("assertion.target.path")
            }
        }
    }
}

public enum JazzArchiveAssertionDecision: String, Codable, Equatable, Sendable {
    case confirm
    case correct
    case reject
    case exclude
    case split
    case merge
    case redact
    case delete
}

public enum JazzArchiveAssertionScope: String, Codable, Equatable, Sendable {
    case analysis
    case publication
    case archive
}

/// Human review is an overlay: it never rewrites captured observations or artifact bytes.
public struct JazzArchiveAssertion: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var assertionId: String
    public var target: JazzArchiveAssertionTarget
    public var decision: JazzArchiveAssertionDecision
    public var value: JazzArchiveJSONValue?
    public var reason: String?
    public var authoredByActorId: String
    public var authoredAt: String
    public var baseRevision: Int
    public var scope: JazzArchiveAssertionScope
    public var supersedes: String?
    public var provenance: JazzArchiveProvenance
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        schemaVersion: Int = 1,
        assertionId: String = Identifiers.newAssertionId(),
        target: JazzArchiveAssertionTarget,
        decision: JazzArchiveAssertionDecision,
        value: JazzArchiveJSONValue? = nil,
        reason: String? = nil,
        authoredByActorId: String,
        authoredAt: String = Timestamps.iso8601(),
        baseRevision: Int,
        scope: JazzArchiveAssertionScope,
        supersedes: String? = nil,
        provenance: JazzArchiveProvenance,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.assertionId = assertionId
        self.target = target
        self.decision = decision
        self.value = value
        self.reason = reason
        self.authoredByActorId = authoredByActorId
        self.authoredAt = authoredAt
        self.baseRevision = baseRevision
        self.scope = scope
        self.supersedes = supersedes
        self.provenance = provenance
        self.extensions = extensions
    }

    public func validate(manifest: JazzArchiveManifest) throws {
        guard schemaVersion == 1 else {
            throw JazzArchiveError.unsupportedSchemaVersion(
                type: "assertion", version: schemaVersion)
        }
        try JazzArchiveValidation.assertionId(assertionId)
        try target.validate(manifest: manifest)
        if decision == .correct, value == nil {
            throw JazzArchiveError.invalidField("assertion.value")
        }
        if let reason {
            try JazzArchiveValidation.nonempty(reason, field: "assertion.reason")
        }
        try JazzArchiveValidation.actorId(authoredByActorId)
        guard manifest.actors.contains(where: { $0.actorId == authoredByActorId }) else {
            throw JazzArchiveError.missingReference(kind: "actor", id: authoredByActorId)
        }
        try JazzArchiveValidation.timestamp(authoredAt, field: "assertion.authoredAt")
        guard baseRevision == manifest.revision else {
            throw JazzArchiveError.referenceMismatch(
                field: "assertion.baseRevision",
                expected: String(manifest.revision),
                actual: String(baseRevision))
        }
        if let supersedes { try JazzArchiveValidation.assertionId(supersedes) }
        try provenance.validate()
        try JazzArchiveValidation.provenanceSources(
            provenance, sourceIds: Set(manifest.sources.map(\.sourceId)))
    }
}

// MARK: - Platform-neutral interaction context

public struct JazzArchiveApplicationContext: Codable, Equatable, Sendable {
    public var identity: JazzArchiveExternalIdentity
    public var name: String?
    public var version: String?
    public var instanceId: String?

    public init(
        identity: JazzArchiveExternalIdentity,
        name: String? = nil,
        version: String? = nil,
        instanceId: String? = nil
    ) {
        self.identity = identity
        self.name = name
        self.version = version
        self.instanceId = instanceId
    }

    fileprivate func validate() throws {
        try identity.validate()
    }
}

public struct JazzArchiveWindowContext: Codable, Equatable, Sendable {
    public var identity: JazzArchiveExternalIdentity?
    public var title: String?

    public init(identity: JazzArchiveExternalIdentity? = nil, title: String? = nil) {
        self.identity = identity
        self.title = title
    }

    fileprivate func validate() throws {
        try identity?.validate()
    }
}

public enum JazzArchiveActionModifier: String, Codable, Equatable, Sendable {
    case command
    case control
    case option
    case shift
    case function
    case capsLock = "caps_lock"
}

public struct JazzArchiveActionContext: Codable, Equatable, Sendable {
    public var type: String
    public var gestureId: String?
    public var modifiers: [JazzArchiveActionModifier]

    public init(
        type: String,
        gestureId: String? = nil,
        modifiers: [JazzArchiveActionModifier] = []
    ) {
        self.type = type
        self.gestureId = gestureId
        self.modifiers = modifiers
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.token(type, field: "interactionContext.action.type")
        try JazzArchiveValidation.unique(
            modifiers.map(\.rawValue), kind: "interaction action modifier")
    }
}

public enum JazzArchiveLocatorStability: String, Codable, Equatable, Sendable {
    case stable
    case session
    case ephemeral
}

public enum JazzArchiveLocatorScope: String, Codable, Equatable, Sendable {
    case application
    case window
    case document
    case target
}

public struct JazzArchiveLocatorCandidate: Codable, Equatable, Sendable {
    public var namespace: String
    public var kind: String
    public var value: String
    public var stability: JazzArchiveLocatorStability
    public var scope: JazzArchiveLocatorScope?

    public init(
        namespace: String,
        kind: String,
        value: String,
        stability: JazzArchiveLocatorStability,
        scope: JazzArchiveLocatorScope? = nil
    ) {
        self.namespace = namespace
        self.kind = kind
        self.value = value
        self.stability = stability
        self.scope = scope
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.nonempty(
            namespace, field: "interactionContext.target.locator.namespace")
        try JazzArchiveValidation.nonempty(
            kind, field: "interactionContext.target.locator.kind")
        try JazzArchiveValidation.nonempty(
            value, field: "interactionContext.target.locator.value")
    }
}

public enum JazzArchiveCoordinateSpace: String, Codable, Equatable, Sendable {
    case screenPoints = "screen_points"
    case screenDIP = "screen_dip"
    case physicalPixels = "physical_pixels"
    case windowPoints = "window_points"
    case viewportCSSPixels = "viewport_css_pixels"
}

public struct JazzArchiveGeometry: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var coordinateSpace: JazzArchiveCoordinateSpace
    public var displayId: String?
    public var scaleFactor: Double?

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        coordinateSpace: JazzArchiveCoordinateSpace,
        displayId: String? = nil,
        scaleFactor: Double? = nil
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.coordinateSpace = coordinateSpace
        self.displayId = displayId
        self.scaleFactor = scaleFactor
    }

    fileprivate func validate() throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
            width >= 0, height >= 0
        else { throw JazzArchiveError.invalidNumber(field: "interactionContext.target.geometry") }
        if let scaleFactor, !scaleFactor.isFinite || scaleFactor <= 0 {
            throw JazzArchiveError.invalidNumber(
                field: "interactionContext.target.geometry.scaleFactor")
        }
    }
}

public struct JazzArchiveTargetContext: Codable, Equatable, Sendable {
    public var role: String?
    public var name: String?
    public var locatorCandidates: [JazzArchiveLocatorCandidate]?
    public var geometry: JazzArchiveGeometry?
    public var capabilities: [String]?

    public init(
        role: String? = nil,
        name: String? = nil,
        locatorCandidates: [JazzArchiveLocatorCandidate]? = nil,
        geometry: JazzArchiveGeometry? = nil,
        capabilities: [String]? = nil
    ) {
        self.role = role
        self.name = name
        self.locatorCandidates = locatorCandidates
        self.geometry = geometry
        self.capabilities = capabilities
    }

    fileprivate func validate() throws {
        if let locatorCandidates {
            for locator in locatorCandidates { try locator.validate() }
        }
        try geometry?.validate()
        if let capabilities {
            try JazzArchiveValidation.unique(capabilities, kind: "interaction target capability")
            for capability in capabilities {
                try JazzArchiveValidation.nonempty(
                    capability, field: "interactionContext.target.capability")
            }
        }
    }
}

/// Archive-only replay context. It deliberately does not alter ActivityEvent or its v1 OTLP map.
public struct JazzArchiveInteractionContext: Codable, Equatable, Sendable {
    public var application: JazzArchiveApplicationContext
    public var window: JazzArchiveWindowContext?
    public var action: JazzArchiveActionContext
    public var target: JazzArchiveTargetContext?
    public var quality: JazzArchiveQuality

    public init(
        application: JazzArchiveApplicationContext,
        window: JazzArchiveWindowContext? = nil,
        action: JazzArchiveActionContext,
        target: JazzArchiveTargetContext? = nil,
        quality: JazzArchiveQuality
    ) {
        self.application = application
        self.window = window
        self.action = action
        self.target = target
        self.quality = quality
    }

    fileprivate func validate() throws {
        try application.validate()
        try window?.validate()
        try action.validate()
        try target?.validate()
        try quality.validate()
    }
}

public struct JazzArchiveLegacyCorrelation: Codable, Equatable, Sendable {
    public var sessionId: String
    public var eventId: String
    public var sequence: Int

    public init(sessionId: String, eventId: String, sequence: Int) {
        self.sessionId = sessionId
        self.eventId = eventId
        self.sequence = sequence
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.sessionId(sessionId)
        try JazzArchiveValidation.eventId(eventId)
        guard sequence >= 0 else { throw JazzArchiveError.invalidCount(sequence) }
        guard eventId == Identifiers.eventId(sessionId: sessionId, sequence: sequence) else {
            throw JazzArchiveError.referenceMismatch(
                field: "legacyCorrelation.eventId",
                expected: Identifiers.eventId(sessionId: sessionId, sequence: sequence),
                actual: eventId)
        }
    }
}

/// Generic, transport-neutral observation envelope. Payload identity and schema are bound by the
/// manifest contract; ActivityEvent is only one typed specialization.
public struct ArchiveRecord<Payload: Codable & Sendable>: Codable, Sendable {
    public var schemaVersion: Int
    public var observationId: String
    public var recordType: String
    public var payloadSchema: String
    /// Stable identity of the capture origin. Kept on every record so a live/standalone
    /// envelope remains attributable even when it is transported without its manifest.
    public var originId: String
    public var captureId: String
    public var streamId: String
    public var streamSequence: Int
    public var capturedAt: String
    public var occurredAt: String?
    public var monotonicTime: JazzArchiveMonotonicTime?
    public var enrichedAt: String?
    public var contextRefs: JazzArchiveContextRefs?
    public var sourceRefs: [JazzArchiveSourceRef]
    public var actorRefs: [JazzArchiveActorRef]
    public var labelRefs: [String]
    public var artifactRefs: [JazzArchiveArtifactRef]
    public var interactionContext: JazzArchiveInteractionContext?
    public var legacyCorrelation: JazzArchiveLegacyCorrelation?
    public var payload: Payload
    public var provenance: JazzArchiveProvenance
    public var quality: JazzArchiveQuality
    public var privacy: JazzArchivePrivacy
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        schemaVersion: Int = 1,
        observationId: String = Identifiers.newObservationId(),
        recordType: String,
        payloadSchema: String,
        originId: String,
        captureId: String,
        streamId: String,
        streamSequence: Int,
        capturedAt: String,
        occurredAt: String? = nil,
        monotonicTime: JazzArchiveMonotonicTime? = nil,
        enrichedAt: String? = nil,
        contextRefs: JazzArchiveContextRefs? = nil,
        sourceRefs: [JazzArchiveSourceRef],
        actorRefs: [JazzArchiveActorRef],
        labelRefs: [String] = [],
        artifactRefs: [JazzArchiveArtifactRef] = [],
        interactionContext: JazzArchiveInteractionContext? = nil,
        legacyCorrelation: JazzArchiveLegacyCorrelation? = nil,
        payload: Payload,
        provenance: JazzArchiveProvenance,
        quality: JazzArchiveQuality,
        privacy: JazzArchivePrivacy,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.observationId = observationId
        self.recordType = recordType
        self.payloadSchema = payloadSchema
        self.originId = originId
        self.captureId = captureId
        self.streamId = streamId
        self.streamSequence = streamSequence
        self.capturedAt = capturedAt
        self.occurredAt = occurredAt
        self.monotonicTime = monotonicTime
        self.enrichedAt = enrichedAt
        self.contextRefs = contextRefs
        self.sourceRefs = sourceRefs
        self.actorRefs = actorRefs
        self.labelRefs = labelRefs
        self.artifactRefs = artifactRefs
        self.interactionContext = interactionContext
        self.legacyCorrelation = legacyCorrelation
        self.payload = payload
        self.provenance = provenance
        self.quality = quality
        self.privacy = privacy
        self.extensions = extensions
    }

    public func validateEnvelope(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws {
        guard schemaVersion == 1 else {
            throw JazzArchiveError.unsupportedSchemaVersion(type: "record", version: schemaVersion)
        }
        try JazzArchiveValidation.observationId(observationId)
        try JazzArchiveValidation.token(recordType, field: "recordType")
        guard let url = URL(string: payloadSchema), url.scheme != nil else {
            throw JazzArchiveError.invalidURI(field: "payloadSchema", value: payloadSchema)
        }
        try JazzArchiveValidation.originId(originId)
        guard originId == manifest.originId else {
            throw JazzArchiveError.referenceMismatch(
                field: "originId", expected: manifest.originId, actual: originId)
        }
        try JazzArchiveValidation.captureId(captureId)
        try JazzArchiveValidation.streamId(streamId)
        guard captureId == session.captureId else {
            throw JazzArchiveError.referenceMismatch(
                field: "captureId", expected: session.captureId, actual: captureId)
        }
        guard session.streamIds.contains(streamId) else {
            throw JazzArchiveError.missingReference(kind: "stream", id: streamId)
        }
        guard streamSequence >= 0 else { throw JazzArchiveError.invalidCount(streamSequence) }
        try JazzArchiveValidation.timestamp(capturedAt, field: "record.capturedAt")
        if let occurredAt {
            try JazzArchiveValidation.timestamp(occurredAt, field: "record.occurredAt")
        }
        try monotonicTime?.validate()
        if let enrichedAt {
            try JazzArchiveValidation.timestamp(enrichedAt, field: "record.enrichedAt")
        }
        try contextRefs?.validate()

        guard !sourceRefs.isEmpty else { throw JazzArchiveError.invalidField("record.sourceRefs") }
        let sourceIds = Set(manifest.sources.map(\.sourceId))
        for ref in sourceRefs {
            try ref.validate()
            guard sourceIds.contains(ref.sourceId) else {
                throw JazzArchiveError.missingReference(kind: "source", id: ref.sourceId)
            }
        }
        let actorIds = Set(manifest.actors.map(\.actorId))
        for ref in actorRefs {
            try ref.validate()
            guard actorIds.contains(ref.actorId) else {
                throw JazzArchiveError.missingReference(kind: "actor", id: ref.actorId)
            }
        }
        try JazzArchiveValidation.unique(labelRefs, kind: "label reference")
        for ref in labelRefs { try JazzArchiveValidation.labelId(ref) }
        try JazzArchiveValidation.unique(
            artifactRefs.map(\.artifactId), kind: "artifact reference")
        for ref in artifactRefs { try ref.validate() }
        try interactionContext?.validate()
        try legacyCorrelation?.validate()
        try provenance.validate()
        try JazzArchiveValidation.provenanceSources(provenance, sourceIds: sourceIds)
        try quality.validate()
        try privacy.validate()

        guard
            manifest.contracts.contains(where: {
            $0.recordType == recordType && $0.schemaId == payloadSchema
            })
        else {
            throw JazzArchiveError.missingReference(kind: "contract", id: recordType)
        }
        let payloadData = try JSONEncoder().encode(payload)
        guard (try JSONSerialization.jsonObject(with: payloadData)) is [String: Any] else {
            throw JazzArchiveError.invalidField("record.payload")
        }
    }
}

extension ArchiveRecord: Equatable where Payload: Equatable {}

extension ArchiveRecord where Payload == ActivityEvent {
    public static let activityRecordType = "jazz.activity-event"
    public static let activityPayloadSchema =
        "https://jasnost.dev/schema/activity-event.schema.json"

    public init(
        event: ActivityEvent,
        observationId: String = Identifiers.newObservationId(),
        originId: String,
        captureId: String,
        streamId: String,
        streamSequence: Int,
        capturedAt: String? = nil,
        occurredAt: String? = nil,
        monotonicTime: JazzArchiveMonotonicTime? = nil,
        enrichedAt: String? = nil,
        contextRefs: JazzArchiveContextRefs? = nil,
        sourceRefs: [JazzArchiveSourceRef],
        actorRefs: [JazzArchiveActorRef],
        labelRefs: [String]? = nil,
        artifactRefs: [JazzArchiveArtifactRef] = [],
        interactionContext: JazzArchiveInteractionContext? = nil,
        provenance: JazzArchiveProvenance,
        quality: JazzArchiveQuality,
        privacy: JazzArchivePrivacy,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        let legacyCorrelation = event.sequence.map {
            JazzArchiveLegacyCorrelation(
                sessionId: event.sessionId, eventId: event.eventId, sequence: $0)
        }
        self.init(
            observationId: observationId,
            recordType: Self.activityRecordType,
            payloadSchema: Self.activityPayloadSchema,
            originId: originId,
            captureId: captureId,
            streamId: streamId,
            streamSequence: streamSequence,
            capturedAt: capturedAt ?? event.timestamp,
            occurredAt: occurredAt ?? event.timestamp,
            monotonicTime: monotonicTime,
            enrichedAt: enrichedAt,
            contextRefs: contextRefs,
            sourceRefs: sourceRefs,
            actorRefs: actorRefs,
            labelRefs: labelRefs ?? event.labelId.map { [$0] } ?? [],
            artifactRefs: artifactRefs,
            interactionContext: interactionContext,
            legacyCorrelation: legacyCorrelation,
            payload: event,
            provenance: provenance,
            quality: quality,
            privacy: privacy,
            extensions: extensions)
    }

    public func validate(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws {
        try validateEnvelope(manifest: manifest, session: session)
        guard recordType == Self.activityRecordType else {
            throw JazzArchiveError.invalidConstant(field: "recordType", value: recordType)
        }
        guard payloadSchema == Self.activityPayloadSchema else {
            throw JazzArchiveError.invalidConstant(field: "payloadSchema", value: payloadSchema)
        }
        if let legacyCorrelation {
            guard legacyCorrelation.sessionId == payload.sessionId else {
                throw JazzArchiveError.referenceMismatch(
                    field: "legacyCorrelation.sessionId",
                    expected: payload.sessionId,
                    actual: legacyCorrelation.sessionId)
            }
            guard legacyCorrelation.eventId == payload.eventId else {
                throw JazzArchiveError.referenceMismatch(
                    field: "legacyCorrelation.eventId",
                    expected: payload.eventId,
                    actual: legacyCorrelation.eventId)
            }
            guard legacyCorrelation.sequence == payload.sequence else {
                throw JazzArchiveError.sequenceMismatch(
                    expected: payload.sequence, actual: legacyCorrelation.sequence)
            }
        }
        if let legacySessionId = session.legacySessionId,
            legacySessionId != payload.sessionId
        {
            throw JazzArchiveError.referenceMismatch(
                field: "payload.sessionId",
                expected: legacySessionId,
                actual: payload.sessionId)
        }
        if let labelId = payload.labelId, !labelRefs.contains(labelId) {
            throw JazzArchiveError.missingReference(kind: "record label", id: labelId)
        }
    }
}

// MARK: - Capture commit

public struct JazzArchiveStreamSummary: Codable, Equatable, Sendable {
    public var streamId: String
    public var firstSequence: Int
    public var lastSequence: Int
    public var observationCount: Int

    public init(
        streamId: String,
        firstSequence: Int,
        lastSequence: Int,
        observationCount: Int
    ) {
        self.streamId = streamId
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence
        self.observationCount = observationCount
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.streamId(streamId)
        guard firstSequence >= 0, lastSequence >= firstSequence, observationCount >= 1,
            observationCount <= lastSequence - firstSequence + 1
        else { throw JazzArchiveError.invalidField("captureCommit.streamSummary") }
    }
}

public enum JazzArchiveGapReason: String, Codable, Equatable, Sendable {
    case captureLoss = "capture_loss"
    case permissionDenied = "permission_denied"
    case sourceUnavailable = "source_unavailable"
    case bufferOverflow = "buffer_overflow"
    case recoveryTruncation = "recovery_truncation"
    case intentionallyOmitted = "intentionally_omitted"
    case unknown
}

public struct JazzArchiveSequenceGap: Codable, Equatable, Sendable {
    public var streamId: String
    public var firstSequence: Int
    public var lastSequence: Int
    public var reason: JazzArchiveGapReason
    public var detail: String?

    public init(
        streamId: String,
        firstSequence: Int,
        lastSequence: Int,
        reason: JazzArchiveGapReason,
        detail: String? = nil
    ) {
        self.streamId = streamId
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence
        self.reason = reason
        self.detail = detail
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.streamId(streamId)
        guard firstSequence >= 0, lastSequence >= firstSequence else {
            throw JazzArchiveError.invalidField("captureCommit.gap")
        }
    }
}

/// Immutable reconciliation boundary for one capture revision.
public struct JazzArchiveCaptureCommit: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var commitId: String
    public var captureId: String
    public var revision: Int
    public var endedAt: String
    public var streamSummaries: [JazzArchiveStreamSummary]
    public var orderedObservationDigest: String
    public var artifactCount: Int
    public var artifactSetDigest: String
    public var gaps: [JazzArchiveSequenceGap]
    public var supersedesCommitId: String?
    public var supersedesArchiveId: String?
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        schemaVersion: Int = 1,
        commitId: String = Identifiers.newCaptureCommitId(),
        captureId: String,
        revision: Int,
        endedAt: String,
        streamSummaries: [JazzArchiveStreamSummary],
        orderedObservationDigest: String,
        artifactCount: Int,
        artifactSetDigest: String,
        gaps: [JazzArchiveSequenceGap],
        supersedesCommitId: String? = nil,
        supersedesArchiveId: String? = nil,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.commitId = commitId
        self.captureId = captureId
        self.revision = revision
        self.endedAt = endedAt
        self.streamSummaries = streamSummaries
        self.orderedObservationDigest = orderedObservationDigest
        self.artifactCount = artifactCount
        self.artifactSetDigest = artifactSetDigest
        self.gaps = gaps
        self.supersedesCommitId = supersedesCommitId
        self.supersedesArchiveId = supersedesArchiveId
        self.extensions = extensions
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw JazzArchiveError.unsupportedSchemaVersion(
                type: "capture commit", version: schemaVersion)
        }
        try JazzArchiveValidation.commitId(commitId)
        try JazzArchiveValidation.captureId(captureId)
        guard revision >= 1 else { throw JazzArchiveError.invalidCount(revision) }
        try JazzArchiveValidation.timestamp(endedAt, field: "captureCommit.endedAt")
        guard !streamSummaries.isEmpty else {
            throw JazzArchiveError.invalidField("captureCommit.streamSummaries")
        }
        try JazzArchiveValidation.unique(
            streamSummaries.map(\.streamId), kind: "capture commit stream")
        for summary in streamSummaries { try summary.validate() }
        try JazzArchiveValidation.sha256(
            orderedObservationDigest, field: "captureCommit.orderedObservationDigest")
        guard artifactCount >= 0 else { throw JazzArchiveError.invalidCount(artifactCount) }
        try JazzArchiveValidation.sha256(
            artifactSetDigest, field: "captureCommit.artifactSetDigest")
        for gap in gaps { try gap.validate() }
        let summaries = Dictionary(uniqueKeysWithValues: streamSummaries.map { ($0.streamId, $0) })
        for gap in gaps where summaries[gap.streamId] == nil {
            throw JazzArchiveError.missingReference(kind: "commit stream", id: gap.streamId)
        }
        for summary in streamSummaries {
            let streamGaps = gaps.filter { $0.streamId == summary.streamId }.sorted {
                ($0.firstSequence, $0.lastSequence) < ($1.firstSequence, $1.lastSequence)
            }
            var previousEnd: Int?
            var missing = 0
            for gap in streamGaps {
                guard gap.firstSequence >= summary.firstSequence,
                    gap.lastSequence <= summary.lastSequence,
                    previousEnd.map({ gap.firstSequence > $0 }) ?? true
                else { throw JazzArchiveError.invalidField("captureCommit.gaps") }
                missing += gap.lastSequence - gap.firstSequence + 1
                previousEnd = gap.lastSequence
            }
            guard
                summary.observationCount + missing
                == summary.lastSequence - summary.firstSequence + 1
            else { throw JazzArchiveError.invalidField("captureCommit.gap coverage") }
        }
        if let supersedesCommitId { try JazzArchiveValidation.commitId(supersedesCommitId) }
        if let supersedesArchiveId { try JazzArchiveValidation.archiveId(supersedesArchiveId) }
    }

    public static func make<Payload: Codable & Sendable>(
        commitId: String = Identifiers.newCaptureCommitId(),
        captureId: String,
        revision: Int,
        endedAt: String,
        records: [ArchiveRecord<Payload>],
        artifactDigests: [String: String] = [:],
        declaredGaps: [JazzArchiveSequenceGap] = [],
        gapReason: JazzArchiveGapReason = .unknown
    ) throws -> JazzArchiveCaptureCommit {
        guard !records.isEmpty else {
            throw JazzArchiveError.invalidField("captureCommit records")
        }
        try JazzArchiveValidation.unique(records.map(\.observationId), kind: "observation")
        var streamKeys = Set<String>()
        for record in records {
            guard record.captureId == captureId else {
                throw JazzArchiveError.referenceMismatch(
                    field: "captureCommit.captureId",
                    expected: captureId,
                    actual: record.captureId)
            }
            let key = "\(record.streamId):\(record.streamSequence)"
            guard streamKeys.insert(key).inserted else {
                throw JazzArchiveError.duplicateIdentifier(kind: "stream sequence", id: key)
            }
        }

        let grouped = Dictionary(grouping: records, by: \.streamId)
        let declaredByStream = Dictionary(grouping: declaredGaps, by: \.streamId)
        for gap in declaredGaps {
            try gap.validate()
            guard grouped[gap.streamId] != nil else {
                throw JazzArchiveError.missingReference(
                    kind: "commit stream", id: gap.streamId)
            }
        }
        var summaries: [JazzArchiveStreamSummary] = []
        var gaps: [JazzArchiveSequenceGap] = []
        for streamId in grouped.keys.sorted() {
            let sorted = grouped[streamId]!.sorted { $0.streamSequence < $1.streamSequence }
            let declared = (declaredByStream[streamId] ?? []).sorted {
                ($0.firstSequence, $0.lastSequence) < ($1.firstSequence, $1.lastSequence)
            }
            var previousDeclaredEnd: Int?
            for gap in declared {
                guard previousDeclaredEnd.map({ gap.firstSequence > $0 }) ?? true else {
                    throw JazzArchiveError.invalidField("captureCommit.declaredGaps")
                }
                guard
                    !sorted.contains(where: {
                    gap.firstSequence <= $0.streamSequence
                        && $0.streamSequence <= gap.lastSequence
                    })
                else {
                    throw JazzArchiveError.invalidField("captureCommit.declaredGaps")
                }
                previousDeclaredEnd = gap.lastSequence
            }

            let first = min(sorted[0].streamSequence, declared.first?.firstSequence ?? Int.max)
            let last = max(
                sorted[sorted.count - 1].streamSequence,
                declared.last?.lastSequence ?? Int.min)
            summaries.append(
                JazzArchiveStreamSummary(
                streamId: streamId,
                firstSequence: first,
                lastSequence: last,
                observationCount: sorted.count))

            let coverage =
                sorted.map {
                    (
                        first: $0.streamSequence, last: $0.streamSequence,
                        gap: Optional<JazzArchiveSequenceGap>.none
                    )
                }
                + declared.map {
                    (
                        first: $0.firstSequence, last: $0.lastSequence,
                        gap: Optional($0)
                    )
            }
            var cursor: Int? = first
            for segment in coverage.sorted(by: {
                ($0.first, $0.last) < ($1.first, $1.last)
            }) {
                if let expected = cursor, expected < segment.first {
                    gaps.append(
                        JazzArchiveSequenceGap(
                        streamId: streamId,
                        firstSequence: expected,
                        lastSequence: segment.first - 1,
                        reason: gapReason))
                }
                if let declaredGap = segment.gap { gaps.append(declaredGap) }
                cursor = segment.last == Int.max ? nil : segment.last + 1
            }
            if let expected = cursor, expected <= last {
                gaps.append(
                    JazzArchiveSequenceGap(
                    streamId: streamId,
                    firstSequence: expected,
                    lastSequence: last,
                    reason: gapReason))
            }
        }
        let orderedRecords = records.sorted {
            ($0.streamId, $0.streamSequence, $0.observationId)
                < ($1.streamId, $1.streamSequence, $1.observationId)
        }
        let orderedLines = try orderedRecords.map { record in
            let digest = JazzArchiveDigest.sha256Hex(
                try JazzArchiveCanonicalJSON.encode(record))
            return "\(record.streamId):\(record.streamSequence):\(record.observationId):\(digest)\n"
        }.joined()

        for (artifactId, digest) in artifactDigests {
            try JazzArchiveValidation.artifactId(artifactId)
            try JazzArchiveValidation.sha256(digest, field: "captureCommit artifact digest")
        }
        let referencedArtifacts = Set(records.flatMap { $0.artifactRefs.map(\.artifactId) })
        for artifactId in referencedArtifacts where artifactDigests[artifactId] == nil {
            throw JazzArchiveError.missingReference(kind: "committed artifact", id: artifactId)
        }
        let artifactLines = artifactDigests.keys.sorted().map {
            "\($0):\(artifactDigests[$0]!)\n"
        }.joined()
        let commit = JazzArchiveCaptureCommit(
            commitId: commitId,
            captureId: captureId,
            revision: revision,
            endedAt: endedAt,
            streamSummaries: summaries,
            orderedObservationDigest: JazzArchiveDigest.sha256Hex(Data(orderedLines.utf8)),
            artifactCount: artifactDigests.count,
            artifactSetDigest: JazzArchiveDigest.sha256Hex(Data(artifactLines.utf8)),
            gaps: gaps)
        try commit.validate()
        return commit
    }
}

// MARK: - Canonical inventory

/// Cross-file inventory document described by the archive contract. It lists canonical files and
/// blobs, excluding manifest, inventory itself, and mutable sync state.
public struct JazzArchiveInventory: Codable, Equatable, Sendable {
    public var algorithm: String
    public var entries: [JazzArchiveInventoryEntry]

    public init(algorithm: String = "sha256", entries: [JazzArchiveInventoryEntry]) {
        self.algorithm = algorithm
        self.entries = entries
    }

    public func validate() throws {
        guard algorithm == "sha256" else {
            throw JazzArchiveError.invalidConstant(field: "inventory.algorithm", value: algorithm)
        }
        try JazzArchiveValidation.unique(entries.map(\.path), kind: "inventory path")
        for entry in entries { try entry.validate() }
    }
}

public struct JazzArchiveInventoryEntry: Codable, Equatable, Sendable {
    public var path: String
    public var byteLength: Int64
    public var sha256: String

    public init(path: String, byteLength: Int64, sha256: String) {
        self.path = path
        self.byteLength = byteLength
        self.sha256 = sha256
    }

    fileprivate func validate() throws {
        try JazzArchiveValidation.relativePath(path)
        guard path != "manifest.json", path != "inventory.json", !path.hasPrefix("sync/") else {
            throw JazzArchiveError.invalidInventoryPath(path)
        }
        guard byteLength >= 0 else { throw JazzArchiveError.invalidNumber(field: "byteLength") }
        try JazzArchiveValidation.sha256(sha256, field: "inventory.entry.sha256")
    }
}

// MARK: - Errors

public enum JazzArchiveError: Error, Equatable, CustomStringConvertible {
    case invalidConstant(field: String, value: String)
    case unsupportedFormatVersion(Int)
    case unsupportedSchemaVersion(type: String, version: Int)
    case invalidIdentifier(kind: String, id: String)
    case duplicateIdentifier(kind: String, id: String)
    case missingReference(kind: String, id: String)
    case referenceMismatch(field: String, expected: String, actual: String)
    case invalidField(String)
    case invalidState(String)
    case invalidURI(field: String, value: String)
    case invalidTimestamp(field: String, value: String)
    case invalidRelativePath(String)
    case invalidInventoryPath(String)
    case invalidDigest(field: String, value: String)
    case invalidJSONPointer(String)
    case invalidNumber(field: String)
    case invalidCount(Int)
    case sequenceMismatch(expected: Int?, actual: Int)
    case archiveAlreadyExists(String)
    case archiveNotFound(String)
    case archiveFinalized(String)
    case sessionNotOpen(String)
    case sessionEndConflict(String)
    case batchAlreadyExists(String)
    case transactionConflict(String)
    case transactionCorrupt(String)
    case digestMismatch(path: String)
    case corruptRecord(path: String, line: Int)

    public var description: String {
        switch self {
        case .invalidConstant(let field, let value): return "Invalid \(field): \(value)"
        case .unsupportedFormatVersion(let version):
            return "Unsupported archive format version: \(version)"
        case .unsupportedSchemaVersion(let type, let version):
            return "Unsupported \(type) schema version: \(version)"
        case .invalidIdentifier(let kind, let id): return "Invalid \(kind) id: \(id)"
        case .duplicateIdentifier(let kind, let id): return "Duplicate \(kind) id: \(id)"
        case .missingReference(let kind, let id): return "Missing \(kind) reference: \(id)"
        case .referenceMismatch(let field, let expected, let actual):
            return "\(field) mismatch: expected \(expected), got \(actual)"
        case .invalidField(let field): return "Invalid or empty field: \(field)"
        case .invalidState(let detail): return "Invalid archive state: \(detail)"
        case .invalidURI(let field, let value): return "Invalid \(field) URI: \(value)"
        case .invalidTimestamp(let field, let value): return "Invalid \(field): \(value)"
        case .invalidRelativePath(let path): return "Invalid relative path: \(path)"
        case .invalidInventoryPath(let path): return "Invalid inventory path: \(path)"
        case .invalidDigest(let field, let value): return "Invalid \(field) digest: \(value)"
        case .invalidJSONPointer(let path): return "Invalid JSON pointer: \(path)"
        case .invalidNumber(let field): return "Invalid numeric field: \(field)"
        case .invalidCount(let count): return "Invalid count: \(count)"
        case .sequenceMismatch(let expected, let actual):
            return "Sequence mismatch: payload \(String(describing: expected)), archive \(actual)"
        case .archiveAlreadyExists(let id): return "Archive already exists: \(id)"
        case .archiveNotFound(let id): return "Archive not found: \(id)"
        case .archiveFinalized(let id): return "Archive is finalized: \(id)"
        case .sessionNotOpen(let id): return "Archive session is not open: \(id)"
        case .sessionEndConflict(let id): return "Archive session end conflicts: \(id)"
        case .batchAlreadyExists(let id): return "Archive batch exists: \(id)"
        case .transactionConflict(let detail): return "Archive transaction conflicts: \(detail)"
        case .transactionCorrupt(let detail): return "Archive transaction is corrupt: \(detail)"
        case .digestMismatch(let path): return "Archive digest mismatch: \(path)"
        case .corruptRecord(let path, let line): return "Corrupt archive record: \(path):\(line)"
        }
    }
}

// MARK: - Draft store

/// Internal deterministic crash points used by the Foundation-only process-kill tests. Each case
/// sits immediately after one durable file write or atomic directory publication.
enum JazzArchiveDraftStoreWriteBoundary: String, CaseIterable, Sendable {
    case createStagedSession
    case createStagedInventory
    case createStagedManifest
    case createStagedIntent
    case createIntentPublished
    case createArchivePublished
    case appendStagedBatch
    case appendStagedInventory
    case appendStagedManifest
    case appendStagedIntent
    case appendIntentPublished
    case appendBatchPublished
    case appendInventoryPublished
    case appendManifestPublished
    case artifactStagedBlob
    case artifactStagedDocument
    case artifactStagedInventory
    case artifactStagedManifest
    case artifactStagedIntent
    case artifactIntentPublished
    case artifactBlobPublished
    case artifactDocumentPublished
    case artifactInventoryPublished
    case artifactManifestPublished
    case endStagedCommit
    case endStagedSession
    case endStagedInventory
    case endStagedManifest
    case endStagedIntent
    case endIntentPublished
    case endCommitPublished
    case endSessionPublished
    case endInventoryPublished
    case endManifestPublished

    static let createBoundaries: [Self] = [
        .createStagedSession,
        .createStagedInventory,
        .createStagedManifest,
        .createStagedIntent,
        .createIntentPublished,
        .createArchivePublished,
    ]

    static let endBoundaries: [Self] = [
        .endStagedCommit,
        .endStagedSession,
        .endStagedInventory,
        .endStagedManifest,
        .endStagedIntent,
        .endIntentPublished,
        .endCommitPublished,
        .endSessionPublished,
        .endInventoryPublished,
        .endManifestPublished,
    ]

    static let appendBoundaries: [Self] = [
        .appendStagedBatch,
        .appendStagedInventory,
        .appendStagedManifest,
        .appendStagedIntent,
        .appendIntentPublished,
        .appendBatchPublished,
        .appendInventoryPublished,
        .appendManifestPublished,
    ]

    static let artifactBoundaries: [Self] = [
        .artifactStagedBlob,
        .artifactStagedDocument,
        .artifactStagedInventory,
        .artifactStagedManifest,
        .artifactStagedIntent,
        .artifactIntentPublished,
        .artifactBlobPublished,
        .artifactDocumentPublished,
        .artifactInventoryPublished,
        .artifactManifestPublished,
    ]
}

enum JazzArchiveDraftStoreSimulatedCrash: Error, Equatable {
    case after(JazzArchiveDraftStoreWriteBoundary)
}

/// Deterministic counters for regression tests that protect the live capture path from accidentally
/// reintroducing whole-archive work. These are deliberately internal: production behavior does not
/// depend on metrics collection, while `@testable` tests can count logical work without wall clocks.
enum JazzArchiveDraftStoreWorkUnit: Equatable, Sendable {
    case inventoryEntryFingerprint
    case historicalRecordDecode
    case targetedFileFingerprint
    case deferredPayloadBytes(Int)
    case checkpointBytes(Int)
}

/// Foundation-only, single-writer store for the live archive layout. Each append creates one
/// complete atomic NDJSON batch under `sessions/<id>/records/`; no live OTLP behavior changes.
public actor JazzArchiveDraftStore {
    private struct LiveCaptureIndex: Sendable {
        var inventoryDigest: String
        var observationIds: Set<String>
        var streamKeys: Set<String>
    }

    private enum TransactionOperation: String, Codable, Sendable {
        case create
        case append
        case artifact
        case end
    }

    private enum TransactionFileRole: String, Codable, CaseIterable, Hashable, Sendable {
        case batch
        case blob
        case artifact
        case commit
        case session
        case inventory
        case manifest
    }

    private struct TransactionFile: Codable, Equatable, Sendable {
        var role: TransactionFileRole
        var targetPath: String
        var stagedPath: String
        var beforeSHA256: String?
        var targetSHA256: String
        var byteLength: Int64
    }

    private struct TransactionIntent: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var operation: TransactionOperation
        var archiveId: String
        var captureId: String
        var batchId: String?
        var artifactId: String?
        var recordsPath: String?
        var files: [TransactionFile]
    }

    private struct PreparedCreate {
        var manifest: JazzArchiveManifest
        var sessionRef: JazzArchiveSessionRef
        var intent: TransactionIntent
        var dataByRole: [TransactionFileRole: Data]
    }

    private struct PreparedEnd {
        var session: JazzArchiveSession
        var intent: TransactionIntent
        var dataByRole: [TransactionFileRole: Data]
    }

    private struct PreparedAppend {
        var entry: JazzArchiveInventoryEntry
        var intent: TransactionIntent
        var dataByRole: [TransactionFileRole: Data]
    }

    private struct PreparedArtifact {
        var artifact: JazzArchiveArtifact
        var intent: TransactionIntent
        var blobSource: ArtifactBlobSource
        var dataByRole: [TransactionFileRole: Data]
    }

    private enum ArtifactBlobSource {
        case bytes(Data, JazzArchiveFileFingerprint)
        case claimed(JazzArchiveClaimedFile, JazzArchiveFileFingerprint)

        var fingerprint: JazzArchiveFileFingerprint {
            switch self {
            case .bytes(_, let fingerprint), .claimed(_, let fingerprint): return fingerprint
            }
        }
    }

    public nonisolated let root: URL

    private let fileManager: FileManager
    private let durability: JazzArchiveFilesystemDurability
    private let simulatedCrashAfter: JazzArchiveDraftStoreWriteBoundary?
    private let workObserver: (@Sendable (JazzArchiveDraftStoreWorkUnit) -> Void)?
    private var liveCaptureIndexes: [String: LiveCaptureIndex] = [:]
    private static let manifestName = "manifest.json"
    private static let transactionRootName = ".jazz-transactions"
    private static let transactionIntentName = "intent.json"
    private static let stagedArchiveName = "staged-archive"
    private static let stagedPayloadName = "staged-payload"

    public init(
        root: URL,
        durability: JazzArchiveFilesystemDurability,
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.fileManager = fileManager
        self.durability = durability
        self.simulatedCrashAfter = nil
        self.workObserver = nil
    }

    init(
        root: URL,
        durability: JazzArchiveFilesystemDurability,
        fileManager: FileManager = .default,
        workObserver: @escaping @Sendable (JazzArchiveDraftStoreWorkUnit) -> Void
    ) {
        self.root = root
        self.fileManager = fileManager
        self.durability = durability
        self.simulatedCrashAfter = nil
        self.workObserver = workObserver
    }

    init(
        root: URL,
        fileManager: FileManager = .default,
        durability: JazzArchiveFilesystemDurability,
        simulatedCrashAfter: JazzArchiveDraftStoreWriteBoundary
    ) {
        self.root = root
        self.fileManager = fileManager
        self.durability = durability
        self.simulatedCrashAfter = simulatedCrashAfter
        self.workObserver = nil
    }

    /// Create one live, single-capture draft. The data model remains multi-stream, while a draft
    /// directory has one exclusive archive identity and can never be reused or overwritten.
    @discardableResult
    public func create(
        manifest inputManifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws -> JazzArchiveManifest {
        let prepared = try prepareCreate(manifest: inputManifest, session: session)
        let transactionURL = createTransactionURL(prepared.manifest.archiveId)
        if fileManager.fileExists(atPath: transactionURL.path) {
            let pending = try loadTransaction(
                at: transactionURL,
                expectedOperation: .create,
                archiveId: prepared.manifest.archiveId)
            guard pending == prepared.intent else {
                throw JazzArchiveError.transactionConflict(
                    "create \(prepared.manifest.archiveId)")
            }
            try recoverCreateTransaction(at: transactionURL, intent: pending)
            let manifest = try readManifest(prepared.manifest.archiveId)
            rememberEmptyCapture(
                archiveId: prepared.manifest.archiveId,
                captureId: session.captureId,
                inventoryDigest: manifest.inventory.digest)
            return manifest
        }

        guard !fileManager.fileExists(atPath: archiveDirectory(prepared.manifest.archiveId).path)
        else { throw JazzArchiveError.archiveAlreadyExists(prepared.manifest.archiveId) }
        try stageAndPublishCreate(prepared)
        try recoverCreateTransaction(at: transactionURL, intent: prepared.intent)
        let manifest = try readManifest(prepared.manifest.archiveId)
        rememberEmptyCapture(
            archiveId: prepared.manifest.archiveId,
            captureId: session.captureId,
            inventoryDigest: manifest.inventory.digest)
        return manifest
    }

    /// Append one complete NDJSON batch after checking observation identity and the producer-local
    /// `(streamId, streamSequence)` key against both the batch and the durable draft.
    @discardableResult
    public func append<Payload: Codable & Sendable>(
        archiveId: String,
        captureId: String,
        records inputRecords: [ArchiveRecord<Payload>],
        batchId: String = Identifiers.newArchiveBatchId()
    ) throws -> JazzArchiveInventoryEntry? {
        guard !inputRecords.isEmpty else { return nil }
        let newRecords = try inputRecords.map { try JazzArchiveRecord(erasing: $0) }
        try JazzArchiveValidation.archiveId(archiveId)
        try JazzArchiveValidation.captureId(captureId)
        try JazzArchiveValidation.prefixedUUIDv7(batchId, prefix: "batch")
        try recoverTransactions(archiveId: archiveId)
        let manifest = try readManifest(archiveId)
        guard manifest.state == .live else { throw JazzArchiveError.archiveFinalized(archiveId) }
        let session = try readSession(archiveId, captureId)
        guard session.status == .open else { throw JazzArchiveError.sessionNotOpen(captureId) }
        let sessionRef = try captureRef(in: manifest, captureId: captureId)

        var incomingObservationIds = Set<String>()
        var incomingStreamKeys = Set<String>()
        for record in newRecords {
            try record.validateRecord(manifest: manifest, session: session)
            guard incomingObservationIds.insert(record.observationId).inserted else {
                throw JazzArchiveError.duplicateIdentifier(
                    kind: "observation", id: record.observationId)
            }
            let key = streamKey(record)
            guard incomingStreamKeys.insert(key).inserted else {
                throw JazzArchiveError.duplicateIdentifier(kind: "stream sequence", id: key)
            }
        }

        let relativePath = pathBesideSession(
            sessionRef, child: "records/\(batchId).ndjson")
        let lines = try newRecords.map {
            String(decoding: try Self.encode($0), as: UTF8.self)
        }
        let batchData = Data((lines.joined(separator: "\n") + "\n").utf8)
        let batchURL = archiveDirectory(archiveId).appendingPathComponent(relativePath)
        var inventory = try readInventory(archiveId, manifest: manifest, verifyFiles: false)
        if let existingEntry = inventory.entries.first(where: { $0.path == relativePath }) {
            guard existingEntry == inventoryEntry(path: relativePath, data: batchData),
                fileManager.fileExists(atPath: batchURL.path),
                try Data(contentsOf: batchURL) == batchData
            else { throw JazzArchiveError.batchAlreadyExists(batchId) }
            return existingEntry
        }
        guard !fileManager.fileExists(atPath: batchURL.path) else {
            throw JazzArchiveError.batchAlreadyExists(batchId)
        }

        var liveIndex = try liveCaptureIndex(
            archiveId: archiveId,
            captureId: captureId,
            manifest: manifest)
        if let collision = incomingObservationIds.first(where: liveIndex.observationIds.contains) {
            throw JazzArchiveError.duplicateIdentifier(kind: "observation", id: collision)
        }
        if let collision = incomingStreamKeys.first(where: liveIndex.streamKeys.contains) {
            throw JazzArchiveError.duplicateIdentifier(kind: "stream sequence", id: collision)
        }

        let oldInventoryData = try Data(contentsOf: inventoryURL(archiveId))
        let entry = inventoryEntry(path: relativePath, data: batchData)
        inventory.entries.append(entry)
        let newInventoryData = try Self.encodeCanonicalInventory(inventory)
        var updatedManifest = manifest
        updatedManifest.inventory.digest = JazzArchiveDigest.sha256Hex(newInventoryData)
        try updatedManifest.validate()
        let newManifestData = try Self.encode(updatedManifest)
        let dataByRole: [TransactionFileRole: Data] = [
            .batch: batchData,
            .inventory: newInventoryData,
            .manifest: newManifestData,
        ]
        let files = try [
            transactionFile(
                role: .batch,
                targetPath: relativePath,
                stagedPath: "\(Self.stagedPayloadName)/batch.ndjson",
                beforeData: nil,
                targetData: batchData),
            transactionFile(
                role: .inventory,
                targetPath: manifest.inventory.path,
                stagedPath: "\(Self.stagedPayloadName)/inventory.json",
                beforeData: oldInventoryData,
                targetData: newInventoryData),
            transactionFile(
                role: .manifest,
                targetPath: Self.manifestName,
                stagedPath: "\(Self.stagedPayloadName)/manifest.json",
                beforeData: try Data(contentsOf: manifestURL(archiveId)),
                targetData: newManifestData),
        ]
        let intent = TransactionIntent(
            schemaVersion: 1,
            operation: .append,
            archiveId: archiveId,
            captureId: captureId,
            batchId: batchId,
            artifactId: nil,
            recordsPath: nil,
            files: files)
        try validateTransaction(intent)
        let prepared = PreparedAppend(entry: entry, intent: intent, dataByRole: dataByRole)
        try stageAndPublishAppend(prepared)
        try recoverAppendTransaction(
            at: appendTransactionURL(archiveId, captureId: captureId, batchId: batchId),
            intent: intent)
        liveIndex.inventoryDigest = updatedManifest.inventory.digest
        liveIndex.observationIds.formUnion(incomingObservationIds)
        liveIndex.streamKeys.formUnion(incomingStreamKeys)
        liveCaptureIndexes[liveCaptureKey(archiveId: archiveId, captureId: captureId)] =
            liveIndex
        return entry
    }

    /// Journal-owned append path. The immutable batch is canonical and durable immediately, while
    /// the portable inventory/manifest pair is checkpointed once by `end`. This avoids rewriting a
    /// growing inventory for every observation without changing finalized archive bytes.
    @discardableResult
    func appendJournalRecords(
        archiveId: String,
        captureId: String,
        records newRecords: [JazzArchiveRecord],
        batchId: String
    ) throws -> JazzArchiveInventoryEntry? {
        guard !newRecords.isEmpty else { return nil }
        try JazzArchiveValidation.archiveId(archiveId)
        try JazzArchiveValidation.captureId(captureId)
        try JazzArchiveValidation.prefixedUUIDv7(batchId, prefix: "batch")
        try recoverTransactions(archiveId: archiveId)
        let manifest = try readManifest(archiveId)
        guard manifest.state == .live else { throw JazzArchiveError.archiveFinalized(archiveId) }
        let session = try readSession(archiveId, captureId)
        guard session.status == .open else { throw JazzArchiveError.sessionNotOpen(captureId) }
        let sessionRef = try captureRef(in: manifest, captureId: captureId)

        var incomingObservationIds = Set<String>()
        var incomingStreamKeys = Set<String>()
        for record in newRecords {
            try record.validateRecord(manifest: manifest, session: session)
            guard incomingObservationIds.insert(record.observationId).inserted else {
                throw JazzArchiveError.duplicateIdentifier(
                    kind: "observation", id: record.observationId)
            }
            let key = streamKey(record)
            guard incomingStreamKeys.insert(key).inserted else {
                throw JazzArchiveError.duplicateIdentifier(kind: "stream sequence", id: key)
            }
        }

        let relativePath = pathBesideSession(
            sessionRef, child: "records/\(batchId).ndjson")
        let batchData = Data(
            (try newRecords.map {
                String(decoding: try Self.encode($0), as: UTF8.self)
            }.joined(separator: "\n") + "\n").utf8)
        let entry = inventoryEntry(path: relativePath, data: batchData)
        let batchURL = archiveDirectory(archiveId).appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: batchURL.path) {
            guard try JazzArchiveFileIO.fingerprint(batchURL)
                == JazzArchiveFileFingerprint(
                    sha256: entry.sha256, byteLength: entry.byteLength),
                try Data(contentsOf: batchURL) == batchData
            else { throw JazzArchiveError.batchAlreadyExists(batchId) }
            try synchronizeDeferredTarget(batchURL, archiveId: archiveId)
            return entry
        }

        var liveIndex = try liveCaptureIndex(
            archiveId: archiveId,
            captureId: captureId,
            manifest: manifest)
        if let collision = incomingObservationIds.first(where: liveIndex.observationIds.contains) {
            throw JazzArchiveError.duplicateIdentifier(kind: "observation", id: collision)
        }
        if let collision = incomingStreamKeys.first(where: liveIndex.streamKeys.contains) {
            throw JazzArchiveError.duplicateIdentifier(kind: "stream sequence", id: collision)
        }

        try publishDeferredData(
            batchData,
            to: batchURL,
            archiveId: archiveId)
        workObserver?(.deferredPayloadBytes(batchData.count))
        liveIndex.observationIds.formUnion(incomingObservationIds)
        liveIndex.streamKeys.formUnion(incomingStreamKeys)
        liveCaptureIndexes[liveCaptureKey(archiveId: archiveId, captureId: captureId)] =
            liveIndex
        return entry
    }

    /// Atomically add captured bytes and their canonical artifact document to a live draft.
    /// The blob is content-addressed and may be shared by several artifact identities. The
    /// operation is idempotent for the same artifact id and bytes, and never overwrites a
    /// conflicting document or blob.
    @discardableResult
    public func ingestArtifact(
        archiveId: String,
        captureId: String,
        artifact: JazzArchiveArtifact,
        bytes: Data
    ) throws -> JazzArchiveArtifact {
        let fingerprint = JazzArchiveFileFingerprint(
            sha256: JazzArchiveDigest.sha256Hex(bytes), byteLength: Int64(bytes.count))
        return try ingestArtifact(
            archiveId: archiveId,
            captureId: captureId,
            artifact: artifact,
            blobSource: .bytes(bytes, fingerprint))
    }

    /// Large-artifact path. The only accepted file is a sealed claim created under the archive
    /// root; it is checked before and after hashing and again around transaction staging.
    @discardableResult
    public func ingestArtifact(
        archiveId: String,
        captureId: String,
        artifact: JazzArchiveArtifact,
        claimedFile: JazzArchiveClaimedFile
    ) throws -> JazzArchiveArtifact {
        try claimedFile.validate(fileManager: fileManager)
        let fingerprint = try JazzArchiveFileIO.fingerprint(claimedFile.url)
        try claimedFile.validate(fileManager: fileManager)
        return try ingestArtifact(
            archiveId: archiveId,
            captureId: captureId,
            artifact: artifact,
            blobSource: .claimed(claimedFile, fingerprint))
    }

    @discardableResult
    func ingestJournalArtifact(
        archiveId: String,
        captureId: String,
        artifact: JazzArchiveArtifact,
        bytes: Data
    ) throws -> JazzArchiveArtifact {
        let fingerprint = JazzArchiveFileFingerprint(
            sha256: JazzArchiveDigest.sha256Hex(bytes),
            byteLength: Int64(bytes.count))
        return try ingestDeferredArtifact(
            archiveId: archiveId,
            captureId: captureId,
            artifact: artifact,
            blobSource: .bytes(bytes, fingerprint))
    }

    @discardableResult
    func ingestJournalArtifact(
        archiveId: String,
        captureId: String,
        artifact: JazzArchiveArtifact,
        claimedFile: JazzArchiveClaimedFile
    ) throws -> JazzArchiveArtifact {
        try claimedFile.validate(fileManager: fileManager)
        let fingerprint = try JazzArchiveFileIO.fingerprint(claimedFile.url)
        try claimedFile.validate(fileManager: fileManager)
        return try ingestDeferredArtifact(
            archiveId: archiveId,
            captureId: captureId,
            artifact: artifact,
            blobSource: .claimed(claimedFile, fingerprint))
    }

    /// Journal-owned artifact publication. Content-addressed bytes are made durable before the
    /// document that references them. Both are immutable and inventory materialization is deferred
    /// to the end checkpoint.
    private func ingestDeferredArtifact(
        archiveId: String,
        captureId: String,
        artifact: JazzArchiveArtifact,
        blobSource: ArtifactBlobSource
    ) throws -> JazzArchiveArtifact {
        try JazzArchiveValidation.archiveId(archiveId)
        try JazzArchiveValidation.captureId(captureId)
        try recoverTransactions(archiveId: archiveId)
        let manifest = try readManifest(archiveId)
        guard manifest.state == .live else { throw JazzArchiveError.archiveFinalized(archiveId) }
        let session = try readSession(archiveId, captureId)
        guard session.status == .open else { throw JazzArchiveError.sessionNotOpen(captureId) }
        try artifact.validate(manifest: manifest, session: session)
        let fingerprint = blobSource.fingerprint
        guard artifact.captureId == captureId,
            artifact.content.sha256 == fingerprint.sha256,
            artifact.content.byteLength == fingerprint.byteLength
        else { throw JazzArchiveError.digestMismatch(path: artifact.content.path) }

        let sessionRef = try captureRef(in: manifest, captureId: captureId)
        let documentPath = pathBesideSession(
            sessionRef, child: "artifacts/\(artifact.artifactId).json")
        let documentData = try Self.encode(artifact)
        let archiveURL = archiveDirectory(archiveId)
        let documentURL = archiveURL.appendingPathComponent(documentPath)
        let blobURL = archiveURL.appendingPathComponent(artifact.content.path)

        if fileManager.fileExists(atPath: documentURL.path) {
            guard try Data(contentsOf: documentURL) == documentData,
                fileManager.fileExists(atPath: blobURL.path),
                try JazzArchiveFileIO.fingerprint(blobURL) == fingerprint
            else {
                throw JazzArchiveError.duplicateIdentifier(
                    kind: "artifact", id: artifact.artifactId)
            }
            try synchronizeDeferredTarget(blobURL, archiveId: archiveId)
            try synchronizeDeferredTarget(documentURL, archiveId: archiveId)
            return artifact
        }

        if fileManager.fileExists(atPath: blobURL.path) {
            guard try JazzArchiveFileIO.fingerprint(blobURL) == fingerprint else {
                throw JazzArchiveError.digestMismatch(path: artifact.content.path)
            }
            try synchronizeDeferredTarget(blobURL, archiveId: archiveId)
        } else {
            switch blobSource {
            case .bytes(let bytes, _):
                try publishDeferredData(bytes, to: blobURL, archiveId: archiveId)
                workObserver?(.deferredPayloadBytes(bytes.count))
            case .claimed(let claim, _):
                try claim.validate(fileManager: fileManager)
                _ = try JazzArchiveFileIO.copyAtomically(
                    claim.url,
                    to: blobURL,
                    expected: fingerprint,
                    fileManager: fileManager)
                try claim.validate(fileManager: fileManager)
                try synchronizeDeferredTarget(blobURL, archiveId: archiveId)
                workObserver?(.deferredPayloadBytes(Int(fingerprint.byteLength)))
            }
        }
        try publishDeferredData(
            documentData,
            to: documentURL,
            archiveId: archiveId)
        workObserver?(.deferredPayloadBytes(documentData.count))
        return artifact
    }

    private func ingestArtifact(
        archiveId: String,
        captureId: String,
        artifact: JazzArchiveArtifact,
        blobSource: ArtifactBlobSource
    ) throws -> JazzArchiveArtifact {
        try JazzArchiveValidation.archiveId(archiveId)
        try JazzArchiveValidation.captureId(captureId)
        try recoverTransactions(archiveId: archiveId)
        let manifest = try readManifest(archiveId)
        guard manifest.state == .live else { throw JazzArchiveError.archiveFinalized(archiveId) }
        let session = try readSession(archiveId, captureId)
        guard session.status == .open else { throw JazzArchiveError.sessionNotOpen(captureId) }
        try artifact.validate(manifest: manifest, session: session)
        let blobFingerprint = blobSource.fingerprint
        guard artifact.captureId == captureId,
            artifact.content.byteLength == blobFingerprint.byteLength,
            artifact.content.sha256 == blobFingerprint.sha256
        else { throw JazzArchiveError.digestMismatch(path: artifact.content.path) }

        let sessionRef = try captureRef(in: manifest, captureId: captureId)
        let documentPath = pathBesideSession(
            sessionRef, child: "artifacts/\(artifact.artifactId).json")
        let documentData = try Self.encode(artifact)
        let archiveURL = archiveDirectory(archiveId)
        let documentURL = archiveURL.appendingPathComponent(documentPath)
        let blobURL = archiveURL.appendingPathComponent(artifact.content.path)
        var inventory = try readInventory(archiveId, manifest: manifest, verifyFiles: false)
        let expectedDocumentEntry = inventoryEntry(path: documentPath, data: documentData)
        let expectedBlobEntry = inventoryEntry(
            path: artifact.content.path, fingerprint: blobFingerprint)

        if let existingDocument = inventory.entries.first(where: { $0.path == documentPath }) {
            guard existingDocument == expectedDocumentEntry,
                fileManager.fileExists(atPath: documentURL.path),
                try Data(contentsOf: documentURL) == documentData,
                inventory.entries.contains(expectedBlobEntry),
                fileManager.fileExists(atPath: blobURL.path),
                try JazzArchiveFileIO.fingerprint(blobURL) == blobFingerprint
            else {
                throw JazzArchiveError.duplicateIdentifier(
                    kind: "artifact", id: artifact.artifactId)
            }
            return artifact
        }
        guard !fileManager.fileExists(atPath: documentURL.path) else {
            throw JazzArchiveError.duplicateIdentifier(kind: "artifact", id: artifact.artifactId)
        }
        if let existingBlob = inventory.entries.first(where: {
            $0.path == artifact.content.path
        }) {
            guard existingBlob == expectedBlobEntry,
                fileManager.fileExists(atPath: blobURL.path),
                try JazzArchiveFileIO.fingerprint(blobURL) == blobFingerprint
            else { throw JazzArchiveError.digestMismatch(path: artifact.content.path) }
        } else if fileManager.fileExists(atPath: blobURL.path) {
            throw JazzArchiveError.transactionConflict(artifact.content.path)
        }

        let oldInventoryData = try Data(contentsOf: inventoryURL(archiveId))
        if !inventory.entries.contains(expectedBlobEntry) {
            inventory.entries.append(expectedBlobEntry)
        }
        inventory.entries.append(expectedDocumentEntry)
        let newInventoryData = try Self.encodeCanonicalInventory(inventory)
        var updatedManifest = manifest
        updatedManifest.inventory.digest = JazzArchiveDigest.sha256Hex(newInventoryData)
        try updatedManifest.validate()
        let newManifestData = try Self.encode(updatedManifest)
        let dataByRole: [TransactionFileRole: Data] = [
            .artifact: documentData,
            .inventory: newInventoryData,
            .manifest: newManifestData,
        ]
        let files = try [
            transactionFile(
                role: .blob,
                targetPath: artifact.content.path,
                stagedPath: "\(Self.stagedPayloadName)/blob",
                beforeSHA256: nil,
                targetFingerprint: blobFingerprint),
            transactionFile(
                role: .artifact,
                targetPath: documentPath,
                stagedPath: "\(Self.stagedPayloadName)/artifact.json",
                beforeData: nil,
                targetData: documentData),
            transactionFile(
                role: .inventory,
                targetPath: manifest.inventory.path,
                stagedPath: "\(Self.stagedPayloadName)/inventory.json",
                beforeData: oldInventoryData,
                targetData: newInventoryData),
            transactionFile(
                role: .manifest,
                targetPath: Self.manifestName,
                stagedPath: "\(Self.stagedPayloadName)/manifest.json",
                beforeData: try Data(contentsOf: manifestURL(archiveId)),
                targetData: newManifestData),
        ]
        let intent = TransactionIntent(
            schemaVersion: 1,
            operation: .artifact,
            archiveId: archiveId,
            captureId: captureId,
            batchId: nil,
            artifactId: artifact.artifactId,
            recordsPath: nil,
            files: files)
        try validateTransaction(intent)
        let prepared = PreparedArtifact(
            artifact: artifact,
            intent: intent,
            blobSource: blobSource,
            dataByRole: dataByRole)
        let transactionURL = artifactTransactionURL(
            archiveId, captureId: captureId, artifactId: artifact.artifactId)
        if fileManager.fileExists(atPath: transactionURL.path) {
            let pending = try loadTransaction(
                at: transactionURL, expectedOperation: .artifact, archiveId: archiveId)
            guard pending == intent else {
                throw JazzArchiveError.transactionConflict("artifact \(artifact.artifactId)")
            }
        } else {
            try stageAndPublishArtifact(prepared)
        }
        try recoverArtifactTransaction(at: transactionURL, intent: intent)
        updateCachedInventoryDigest(
            archiveId: archiveId,
            captureId: captureId,
            inventoryDigest: updatedManifest.inventory.digest)
        return try readArtifactTargeted(
            archiveId: archiveId,
            captureId: captureId,
            artifactId: artifact.artifactId)
    }

    /// End a capture and persist its immutable reconciliation commit. The archive remains live;
    /// snapshot/export is the later step that compacts batches and finalizes contentDigest.
    @discardableResult
    public func end(
        archiveId: String,
        captureId: String,
        endedAt: String,
        status: JazzArchiveSessionStatus = .closed,
        artifactDigests: [String: String] = [:],
        declaredGaps: [JazzArchiveSequenceGap] = [],
        gapReason: JazzArchiveGapReason = .unknown
    ) throws -> JazzArchiveSession {
        try JazzArchiveValidation.timestamp(endedAt, field: "session.endedAt")
        guard status != .open else { throw JazzArchiveError.invalidState("end status is open") }
        try recoverTransactions(archiveId: archiveId)
        let manifest = try readManifest(archiveId)
        guard manifest.state == .live else { throw JazzArchiveError.archiveFinalized(archiveId) }
        let session = try readSession(archiveId, captureId)
        if session.status != .open {
            guard session.status == status, session.endedAt == endedAt else {
                throw JazzArchiveError.sessionEndConflict(captureId)
            }
            guard let commitRef = session.captureCommit else {
                throw JazzArchiveError.sessionEndConflict(captureId)
            }
            let commitData = try Data(
                contentsOf: archiveDirectory(archiveId).appendingPathComponent(commitRef.path))
            guard JazzArchiveDigest.sha256Hex(commitData) == commitRef.digest else {
                throw JazzArchiveError.digestMismatch(path: commitRef.path)
            }
            let existingCommit = try Self.decoder.decode(
                JazzArchiveCaptureCommit.self, from: commitData)
            let expectedCommit = try JazzArchiveCaptureCommit.make(
                commitId: existingCommit.commitId,
                captureId: captureId,
                revision: manifest.revision,
                endedAt: endedAt,
                records: readRecords(archiveId: archiveId, captureId: captureId),
                artifactDigests: artifactDigests,
                declaredGaps: declaredGaps,
                gapReason: gapReason)
            guard existingCommit == expectedCommit else {
                throw JazzArchiveError.sessionEndConflict(captureId)
            }
            return session
        }
        let prepared = try prepareEnd(
            manifest: manifest,
            session: session,
            endedAt: endedAt,
            status: status,
            artifactDigests: artifactDigests,
            declaredGaps: declaredGaps,
            gapReason: gapReason)
        let transactionURL = endTransactionURL(archiveId, captureId: captureId)
        guard !fileManager.fileExists(atPath: transactionURL.path) else {
            throw JazzArchiveError.transactionConflict("end \(archiveId)/\(captureId)")
        }
        try stageAndPublishEnd(prepared)
        try recoverEndTransaction(at: transactionURL, intent: prepared.intent)
        return try readSession(archiveId, captureId)
    }

    public func manifest(archiveId: String) throws -> JazzArchiveManifest {
        try recoverTransactions(archiveId: archiveId)
        return try readManifest(archiveId)
    }

    public func session(archiveId: String, captureId: String) throws -> JazzArchiveSession {
        try recoverTransactions(archiveId: archiveId)
        return try readSession(archiveId, captureId)
    }

    public func captureCommit(
        archiveId: String,
        captureId: String
    ) throws -> JazzArchiveCaptureCommit {
        try recoverTransactions(archiveId: archiveId)
        let session = try readSession(archiveId, captureId)
        guard let ref = session.captureCommit else {
            throw JazzArchiveError.missingReference(kind: "capture commit", id: captureId)
        }
        let data = try Data(
            contentsOf: archiveDirectory(archiveId).appendingPathComponent(ref.path))
        guard JazzArchiveDigest.sha256Hex(data) == ref.digest else {
            throw JazzArchiveError.digestMismatch(path: ref.path)
        }
        let commit = try Self.decoder.decode(JazzArchiveCaptureCommit.self, from: data)
        try commit.validate()
        return commit
    }

    /// Strict reader ordered by stream and stream-local sequence; filenames never define order.
    public func records(
        archiveId: String,
        captureId: String
    ) throws -> [ArchiveRecord<ActivityEvent>] {
        try recoverTransactions(archiveId: archiveId)
        let records = try readRecords(archiveId: archiveId, captureId: captureId)
        try rememberStrictlyVerifiedRecords(
            records, archiveId: archiveId, captureId: captureId)
        return
            try records
            .filter { $0.recordType == ArchiveRecord<ActivityEvent>.activityRecordType }
            .map { try $0.activityRecord() }
    }

    /// Strict mixed-contract reader used by replay, commit reconciliation, and durable journals.
    /// Ordering is shared across activity and coach records through `(streamId, streamSequence)`.
    public func allRecords(
        archiveId: String,
        captureId: String
    ) throws -> [JazzArchiveRecord] {
        try recoverTransactions(archiveId: archiveId)
        let records = try readRecords(archiveId: archiveId, captureId: captureId)
        try rememberStrictlyVerifiedRecords(
            records, archiveId: archiveId, captureId: captureId)
        return records
    }

    /// Recovery-only targeted lookup. `CaptureJournal.reopen` performs one strict `allRecords`
    /// verification first, then uses this method to reconcile any artifact intents without
    /// fingerprinting the complete inventory again for every pending artifact.
    func recoveredArtifact(
        archiveId: String,
        captureId: String,
        artifactId: String
    ) throws -> JazzArchiveArtifact {
        try recoverTransactions(archiveId: archiveId)
        return try readArtifactTargeted(
            archiveId: archiveId,
            captureId: captureId,
            artifactId: artifactId)
    }

    public func artifact(
        archiveId: String,
        captureId: String,
        artifactId: String
    ) throws -> JazzArchiveArtifact {
        try recoverTransactions(archiveId: archiveId)
        return try readArtifact(
            archiveId: archiveId, captureId: captureId, artifactId: artifactId)
    }

    /// Canonical artifact documents for one capture, independent of mutable delivery state.
    public func artifacts(
        archiveId: String,
        captureId: String
    ) throws -> [JazzArchiveArtifact] {
        try recoverTransactions(archiveId: archiveId)
        let manifest = try readManifest(archiveId)
        let sessionRef = try captureRef(in: manifest, captureId: captureId)
        let directory = archiveDirectory(archiveId).appendingPathComponent(
            pathBesideSession(sessionRef, child: "artifacts"),
            isDirectory: true)
        let documents =
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))?
            .filter {
                $0.pathExtension == "json"
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            ?? []
        return try documents
            .map { document in
                let id = document.deletingPathExtension().lastPathComponent
                return try readArtifact(
                    archiveId: archiveId, captureId: captureId, artifactId: id)
            }
            .sorted { $0.artifactId < $1.artifactId }
    }

    /// Archive drafts owned by this store. The filename is only an index; every returned id is
    /// validated again by reading its manifest before consumers trust it.
    public func draftArchiveIds() -> [String] {
        guard
            let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        let suffix = ".jazz-archive.draft"
        return entries.compactMap { url -> String? in
            guard url.lastPathComponent.hasSuffix(suffix),
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            let id = String(url.lastPathComponent.dropLast(suffix.count))
            guard (try? JazzArchiveValidation.archiveId(id)) != nil,
                let manifest = try? readManifest(id), manifest.archiveId == id
            else { return nil }
            return id
        }.sorted()
    }

    /// Verified local bytes for a canonical artifact. Upload adapters read this path; they never
    /// own or delete it.
    public func artifactBytes(
        archiveId: String,
        captureId: String,
        artifactId: String
    ) throws -> Data {
        let file = try artifactFile(
            archiveId: archiveId, captureId: captureId, artifactId: artifactId)
        return try Data(contentsOf: file.url)
    }

    /// Verified canonical file for streaming upload/playback. The path remains archive-owned;
    /// consumers may read it but must never mutate or delete it.
    public func artifactFile(
        archiveId: String,
        captureId: String,
        artifactId: String
    ) throws -> JazzArchiveVerifiedArtifactFile {
        try recoverTransactions(archiveId: archiveId)
        let document = try readArtifact(
            archiveId: archiveId, captureId: captureId, artifactId: artifactId)
        let url = archiveDirectory(archiveId).appendingPathComponent(document.content.path)
        let fingerprint = try JazzArchiveFileIO.fingerprint(url)
        guard fingerprint.byteLength == document.content.byteLength,
            fingerprint.sha256 == document.content.sha256
        else { throw JazzArchiveError.digestMismatch(path: document.content.path) }
        return JazzArchiveVerifiedArtifactFile(url: url, artifact: document)
    }

    /// Complete every published transaction for one archive. Staging directories that were never
    /// atomically published are intentionally ignored: no canonical file could have changed yet.
    public func recover(archiveId: String) throws {
        try recoverTransactions(archiveId: archiveId)
    }

    private func readRecords(
        archiveId: String,
        captureId: String
    ) throws -> [JazzArchiveRecord] {
        let manifest = try readManifest(archiveId)
        let session = try readSession(archiveId, captureId)
        let inventory = try readInventory(archiveId, manifest: manifest, verifyFiles: true)
        let sessionRef = try captureRef(in: manifest, captureId: captureId)
        let prefix = pathBesideSession(sessionRef, child: "records/")
        let inventoryByPath = Dictionary(
            uniqueKeysWithValues: inventory.entries.map { ($0.path, $0) })
        let directory = recordsDirectory(archiveId, sessionRef)
        let batchURLs =
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))?
            .filter {
                $0.pathExtension == "ndjson"
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            ?? []
        var result: [JazzArchiveRecord] = []
        for url in batchURLs {
            let relativePath = prefix + url.lastPathComponent
            let fingerprint = try JazzArchiveFileIO.fingerprint(url)
            if let entry = inventoryByPath[relativePath] {
                guard entry.byteLength == fingerprint.byteLength,
                    entry.sha256 == fingerprint.sha256
                else { throw JazzArchiveError.digestMismatch(path: relativePath) }
            } else if session.status != .open {
                throw JazzArchiveError.missingReference(
                    kind: "inventory record batch", id: relativePath)
            }
            let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
            for (index, line) in lines.enumerated() {
                workObserver?(.historicalRecordDecode)
                guard
                    let record = try? Self.decoder.decode(
                        JazzArchiveRecord.self, from: Data(line.utf8))
                else {
                    throw JazzArchiveError.corruptRecord(path: relativePath, line: index + 1)
                }
                try record.validateRecord(manifest: manifest, session: session)
                result.append(record)
            }
        }
        try JazzArchiveValidation.unique(result.map(\.observationId), kind: "observation")
        try JazzArchiveValidation.unique(result.map(streamKey), kind: "stream sequence")
        return result.sorted {
            ($0.streamId, $0.streamSequence, $0.observationId)
                < ($1.streamId, $1.streamSequence, $1.observationId)
        }
    }

    private func readArtifact(
        archiveId: String,
        captureId: String,
        artifactId: String
    ) throws -> JazzArchiveArtifact {
        try readArtifact(
            archiveId: archiveId,
            captureId: captureId,
            artifactId: artifactId,
            verifyInventoryFiles: true)
    }

    private func readArtifactTargeted(
        archiveId: String,
        captureId: String,
        artifactId: String
    ) throws -> JazzArchiveArtifact {
        let artifact = try readArtifact(
            archiveId: archiveId,
            captureId: captureId,
            artifactId: artifactId,
            verifyInventoryFiles: false)
        let manifest = try readManifest(archiveId)
        let sessionRef = try captureRef(in: manifest, captureId: captureId)
        let documentPath = pathBesideSession(
            sessionRef, child: "artifacts/\(artifactId).json")
        let inventory = try readInventory(
            archiveId, manifest: manifest, verifyFiles: false)
        if let documentEntry = inventory.entries.first(where: {
            $0.path == documentPath
        }) {
            try verifyTargetFile(
                archiveId: archiveId,
                path: documentPath,
                expected: documentEntry)
        } else {
            let session = try readSession(archiveId, captureId)
            guard session.status == .open else {
                throw JazzArchiveError.missingReference(kind: "artifact", id: artifactId)
            }
            workObserver?(.targetedFileFingerprint)
            _ = try JazzArchiveFileIO.fingerprint(
                archiveDirectory(archiveId).appendingPathComponent(documentPath))
        }
        let expectedBlob = JazzArchiveInventoryEntry(
            path: artifact.content.path,
            byteLength: artifact.content.byteLength,
            sha256: artifact.content.sha256)
        try verifyTargetFile(
            archiveId: archiveId,
            path: artifact.content.path,
            expected: expectedBlob)
        return artifact
    }

    private func readArtifact(
        archiveId: String,
        captureId: String,
        artifactId: String,
        verifyInventoryFiles: Bool
    ) throws -> JazzArchiveArtifact {
        try JazzArchiveValidation.artifactId(artifactId)
        let manifest = try readManifest(archiveId)
        let session = try readSession(archiveId, captureId)
        let sessionRef = try captureRef(in: manifest, captureId: captureId)
        let path = pathBesideSession(sessionRef, child: "artifacts/\(artifactId).json")
        let inventory = try readInventory(
            archiveId, manifest: manifest, verifyFiles: verifyInventoryFiles)
        let isIndexed = inventory.entries.contains(where: { $0.path == path })
        guard isIndexed || session.status == .open else {
            throw JazzArchiveError.missingReference(kind: "artifact", id: artifactId)
        }
        let documentURL = archiveDirectory(archiveId).appendingPathComponent(path)
        guard fileManager.fileExists(atPath: documentURL.path) else {
            throw JazzArchiveError.missingReference(kind: "artifact", id: artifactId)
        }
        let data = try Data(contentsOf: documentURL)
        let artifact = try Self.decoder.decode(JazzArchiveArtifact.self, from: data)
        guard artifact.artifactId == artifactId else {
            throw JazzArchiveError.referenceMismatch(
                field: "artifact.artifactId", expected: artifactId, actual: artifact.artifactId)
        }
        try artifact.validate(manifest: manifest, session: session)
        let contentIndexed = inventory.entries.contains(where: {
            $0.path == artifact.content.path
                && $0.byteLength == artifact.content.byteLength
                && $0.sha256 == artifact.content.sha256
        })
        guard contentIndexed || session.status == .open else {
            throw JazzArchiveError.missingReference(
                kind: "artifact content", id: artifact.artifactId)
        }
        let actualContent = try JazzArchiveFileIO.fingerprint(
            archiveDirectory(archiveId).appendingPathComponent(artifact.content.path))
        guard actualContent.byteLength == artifact.content.byteLength,
            actualContent.sha256 == artifact.content.sha256
        else { throw JazzArchiveError.digestMismatch(path: artifact.content.path) }
        return artifact
    }

    public func inventory(archiveId: String) throws -> JazzArchiveInventory {
        try recoverTransactions(archiveId: archiveId)
        let manifest = try readManifest(archiveId)
        return try readInventory(archiveId, manifest: manifest, verifyFiles: true)
    }

    // MARK: - Crash-recoverable transactions

    private func prepareCreate(
        manifest inputManifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws -> PreparedCreate {
        var manifest = inputManifest
        guard manifest.state == .live else {
            throw JazzArchiveError.archiveFinalized(manifest.archiveId)
        }
        guard manifest.sessions.count == 1,
            let sessionRef = manifest.sessions.first,
            sessionRef.captureId == session.captureId,
            sessionRef.legacySessionId == session.legacySessionId,
            manifest.captureCommits == nil
        else { throw JazzArchiveError.invalidField("manifest.sessions") }
        guard session.archiveId == manifest.archiveId, session.status == .open else {
            throw JazzArchiveError.referenceMismatch(
                field: "session.archiveId", expected: manifest.archiveId, actual: session.archiveId)
        }
        try validate(session: session, in: manifest)
        guard manifest.inventory.path == "inventory.json" else {
            throw JazzArchiveError.invalidInventoryPath(manifest.inventory.path)
        }

        let sessionData = try Self.encode(session)
        let inventory = JazzArchiveInventory(entries: [
            inventoryEntry(path: sessionRef.path, data: sessionData)
        ])
        let inventoryData = try Self.encodeCanonicalInventory(inventory)
        manifest.inventory.digest = JazzArchiveDigest.sha256Hex(inventoryData)
        try manifest.validate()
        let manifestData = try Self.encode(manifest)
        let dataByRole: [TransactionFileRole: Data] = [
            .session: sessionData,
            .inventory: inventoryData,
            .manifest: manifestData,
        ]
        let files = try [
            transactionFile(
                role: .session,
                targetPath: sessionRef.path,
                stagedPath: "\(Self.stagedArchiveName)/\(sessionRef.path)",
                beforeData: nil,
                targetData: sessionData),
            transactionFile(
                role: .inventory,
                targetPath: manifest.inventory.path,
                stagedPath: "\(Self.stagedArchiveName)/\(manifest.inventory.path)",
                beforeData: nil,
                targetData: inventoryData),
            transactionFile(
                role: .manifest,
                targetPath: Self.manifestName,
                stagedPath: "\(Self.stagedArchiveName)/\(Self.manifestName)",
                beforeData: nil,
                targetData: manifestData),
        ]
        let intent = TransactionIntent(
            schemaVersion: 1,
            operation: .create,
            archiveId: manifest.archiveId,
            captureId: session.captureId,
            batchId: nil,
            artifactId: nil,
            recordsPath: pathBesideSession(sessionRef, child: "records"),
            files: files)
        try validateTransaction(intent)
        return PreparedCreate(
            manifest: manifest,
            sessionRef: sessionRef,
            intent: intent,
            dataByRole: dataByRole)
    }

    private func prepareEnd(
        manifest: JazzArchiveManifest,
        session inputSession: JazzArchiveSession,
        endedAt: String,
        status: JazzArchiveSessionStatus,
        artifactDigests: [String: String],
        declaredGaps: [JazzArchiveSequenceGap],
        gapReason: JazzArchiveGapReason
    ) throws -> PreparedEnd {
        let archiveId = manifest.archiveId
        let captureId = inputSession.captureId
        let sessionRef = try captureRef(in: manifest, captureId: captureId)
        let captureRecords = try readRecords(archiveId: archiveId, captureId: captureId)
        let commit = try JazzArchiveCaptureCommit.make(
            captureId: captureId,
            revision: manifest.revision,
            endedAt: endedAt,
            records: captureRecords,
            artifactDigests: artifactDigests,
            declaredGaps: declaredGaps,
            gapReason: gapReason)
        let commitPath = pathBesideSession(sessionRef, child: "commit.json")
        let commitURL = archiveDirectory(archiveId).appendingPathComponent(commitPath)
        guard !fileManager.fileExists(atPath: commitURL.path) else {
            throw JazzArchiveError.duplicateIdentifier(
                kind: "capture commit path", id: commitPath)
        }
        let commitData = try Self.encode(commit)
        let commitRef = JazzArchiveCaptureCommitRef(
            commitId: commit.commitId,
            captureId: captureId,
            path: commitPath,
            digest: JazzArchiveDigest.sha256Hex(commitData))

        var session = inputSession
        session.status = status
        session.endedAt = endedAt
        session.captureCommit = commitRef
        var updatedManifest = try JazzCaptureCapabilitySourceSummary.materialize(
            manifest: manifest,
            records: captureRecords)
        updatedManifest.captureCommits = (updatedManifest.captureCommits ?? []) + [commitRef]
        session.quality = JazzCaptureCapabilitySourceSummary.materializeQuality(
            session: session,
            manifest: updatedManifest)
        try validate(session: session, in: updatedManifest)

        let sessionPath = sessionRef.path
        let oldSessionData = try Data(contentsOf: sessionURL(archiveId, sessionRef))
        let oldInventoryData = try Data(contentsOf: inventoryURL(archiveId))
        let oldManifestData = try Data(contentsOf: manifestURL(archiveId))
        let newSessionData = try Self.encode(session)
        var inventory = try materializedInventory(
            archiveId: archiveId,
            captureId: captureId,
            manifest: manifest)
        guard let index = inventory.entries.firstIndex(where: { $0.path == sessionPath }) else {
            throw JazzArchiveError.missingReference(kind: "inventory capture", id: captureId)
        }
        guard !inventory.entries.contains(where: { $0.path == commitPath }) else {
            throw JazzArchiveError.duplicateIdentifier(
                kind: "inventory capture commit", id: commitPath)
        }
        inventory.entries[index] = inventoryEntry(path: sessionPath, data: newSessionData)
        inventory.entries.append(inventoryEntry(path: commitPath, data: commitData))
        let newInventoryData = try Self.encodeCanonicalInventory(inventory)
        updatedManifest.inventory.digest = JazzArchiveDigest.sha256Hex(newInventoryData)
        try updatedManifest.validate()
        let newManifestData = try Self.encode(updatedManifest)
        workObserver?(.checkpointBytes(newInventoryData.count + newManifestData.count))
        let dataByRole: [TransactionFileRole: Data] = [
            .commit: commitData,
            .session: newSessionData,
            .inventory: newInventoryData,
            .manifest: newManifestData,
        ]
        let files = try [
            transactionFile(
                role: .commit,
                targetPath: commitPath,
                stagedPath: "\(Self.stagedPayloadName)/commit.json",
                beforeData: nil,
                targetData: commitData),
            transactionFile(
                role: .session,
                targetPath: sessionPath,
                stagedPath: "\(Self.stagedPayloadName)/session.json",
                beforeData: oldSessionData,
                targetData: newSessionData),
            transactionFile(
                role: .inventory,
                targetPath: manifest.inventory.path,
                stagedPath: "\(Self.stagedPayloadName)/inventory.json",
                beforeData: oldInventoryData,
                targetData: newInventoryData),
            transactionFile(
                role: .manifest,
                targetPath: Self.manifestName,
                stagedPath: "\(Self.stagedPayloadName)/manifest.json",
                beforeData: oldManifestData,
                targetData: newManifestData),
        ]
        let intent = TransactionIntent(
            schemaVersion: 1,
            operation: .end,
            archiveId: archiveId,
            captureId: captureId,
            batchId: nil,
            artifactId: nil,
            recordsPath: nil,
            files: files)
        try validateTransaction(intent)
        return PreparedEnd(session: session, intent: intent, dataByRole: dataByRole)
    }

    private func transactionFile(
        role: TransactionFileRole,
        targetPath: String,
        stagedPath: String,
        beforeData: Data?,
        targetData: Data
    ) throws -> TransactionFile {
        try JazzArchiveValidation.relativePath(targetPath)
        try JazzArchiveValidation.relativePath(stagedPath)
        return TransactionFile(
            role: role,
            targetPath: targetPath,
            stagedPath: stagedPath,
            beforeSHA256: beforeData.map(JazzArchiveDigest.sha256Hex),
            targetSHA256: JazzArchiveDigest.sha256Hex(targetData),
            byteLength: Int64(targetData.count))
    }

    private func transactionFile(
        role: TransactionFileRole,
        targetPath: String,
        stagedPath: String,
        beforeSHA256: String?,
        targetFingerprint: JazzArchiveFileFingerprint
    ) throws -> TransactionFile {
        try JazzArchiveValidation.relativePath(targetPath)
        try JazzArchiveValidation.relativePath(stagedPath)
        return TransactionFile(
            role: role,
            targetPath: targetPath,
            stagedPath: stagedPath,
            beforeSHA256: beforeSHA256,
            targetSHA256: targetFingerprint.sha256,
            byteLength: targetFingerprint.byteLength)
    }

    private func stageAndPublishCreate(_ prepared: PreparedCreate) throws {
        let temporaryURL = try newTemporaryTransactionDirectory()
        let stagedArchiveURL = temporaryURL.appendingPathComponent(
            Self.stagedArchiveName, isDirectory: true)
        try fileManager.createDirectory(
            at: stagedArchiveURL.appendingPathComponent(
                try requiredPath(prepared.intent.recordsPath), isDirectory: true),
            withIntermediateDirectories: true)
        for role in [TransactionFileRole.session, .inventory, .manifest] {
            try stage(
                role: role,
                intent: prepared.intent,
                data: try transactionData(role, in: prepared.dataByRole),
                transactionURL: temporaryURL)
            try hit(createStagingBoundary(role))
        }
        try writeIntent(prepared.intent, to: temporaryURL)
        try hit(.createStagedIntent)
        let publishedURL = createTransactionURL(prepared.intent.archiveId)
        try publishTransaction(temporaryURL, to: publishedURL, intent: prepared.intent)
        try hit(.createIntentPublished)
    }

    private func stageAndPublishEnd(_ prepared: PreparedEnd) throws {
        let temporaryURL = try newTemporaryTransactionDirectory()
        for role in [
            TransactionFileRole.commit, .session, .inventory, .manifest,
        ] {
            try stage(
                role: role,
                intent: prepared.intent,
                data: try transactionData(role, in: prepared.dataByRole),
                transactionURL: temporaryURL)
            try hit(endStagingBoundary(role))
        }
        try writeIntent(prepared.intent, to: temporaryURL)
        try hit(.endStagedIntent)
        let publishedURL = endTransactionURL(
            prepared.intent.archiveId, captureId: prepared.intent.captureId)
        try publishTransaction(temporaryURL, to: publishedURL, intent: prepared.intent)
        try hit(.endIntentPublished)
    }

    private func stageAndPublishAppend(_ prepared: PreparedAppend) throws {
        let temporaryURL = try newTemporaryTransactionDirectory()
        for role in [TransactionFileRole.batch, .inventory, .manifest] {
            try stage(
                role: role,
                intent: prepared.intent,
                data: try transactionData(role, in: prepared.dataByRole),
                transactionURL: temporaryURL)
            try hit(appendStagingBoundary(role))
        }
        try writeIntent(prepared.intent, to: temporaryURL)
        try hit(.appendStagedIntent)
        let publishedURL = appendTransactionURL(
            prepared.intent.archiveId,
            captureId: prepared.intent.captureId,
            batchId: try requiredPath(prepared.intent.batchId))
        try publishTransaction(temporaryURL, to: publishedURL, intent: prepared.intent)
        try hit(.appendIntentPublished)
    }

    private func stageAndPublishArtifact(_ prepared: PreparedArtifact) throws {
        let temporaryURL = try newTemporaryTransactionDirectory()
        try stageArtifactBlob(
            prepared.blobSource, intent: prepared.intent, transactionURL: temporaryURL)
        try hit(.artifactStagedBlob)
        for role in [TransactionFileRole.artifact, .inventory, .manifest] {
            try stage(
                role: role,
                intent: prepared.intent,
                data: try transactionData(role, in: prepared.dataByRole),
                transactionURL: temporaryURL)
            try hit(artifactStagingBoundary(role))
        }
        try writeIntent(prepared.intent, to: temporaryURL)
        try hit(.artifactStagedIntent)
        let publishedURL = artifactTransactionURL(
            prepared.intent.archiveId,
            captureId: prepared.intent.captureId,
            artifactId: prepared.artifact.artifactId)
        try publishTransaction(temporaryURL, to: publishedURL, intent: prepared.intent)
        try hit(.artifactIntentPublished)
    }

    private func stageArtifactBlob(
        _ source: ArtifactBlobSource,
        intent: TransactionIntent,
        transactionURL: URL
    ) throws {
        let file = try transactionFile(.blob, in: intent)
        let destination = transactionURL.appendingPathComponent(file.stagedPath)
        let expected = source.fingerprint
        switch source {
        case .bytes(let data, _):
            try stage(role: .blob, intent: intent, data: data, transactionURL: transactionURL)
        case .claimed(let claim, _):
            try claim.validate(fileManager: fileManager)
            _ = try JazzArchiveFileIO.copyAtomically(
                claim.url,
                to: destination,
                expected: expected,
                fileManager: fileManager)
            try claim.validate(fileManager: fileManager)
        }
    }

    private func newTemporaryTransactionDirectory() throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
        let url = transactionRoot.appendingPathComponent(
            ".prepare-\(Identifiers.newUUIDv7().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func stage(
        role: TransactionFileRole,
        intent: TransactionIntent,
        data: Data,
        transactionURL: URL
    ) throws {
        guard let file = intent.files.first(where: { $0.role == role }) else {
            throw JazzArchiveError.transactionCorrupt("missing staged role \(role.rawValue)")
        }
        guard JazzArchiveDigest.sha256Hex(data) == file.targetSHA256,
            Int64(data.count) == file.byteLength
        else { throw JazzArchiveError.transactionCorrupt("staged role \(role.rawValue)") }
        let url = transactionURL.appendingPathComponent(file.stagedPath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func writeIntent(_ intent: TransactionIntent, to transactionURL: URL) throws {
        try Self.encode(intent).write(
            to: transactionURL.appendingPathComponent(Self.transactionIntentName),
            options: .atomic)
    }

    private func publishTransaction(
        _ temporaryURL: URL,
        to publishedURL: URL,
        intent: TransactionIntent
    ) throws {
        if fileManager.fileExists(atPath: publishedURL.path) {
            let existing = try loadTransaction(
                at: publishedURL,
                expectedOperation: intent.operation,
                archiveId: intent.archiveId)
            guard existing == intent else {
                throw JazzArchiveError.transactionConflict(publishedURL.lastPathComponent)
            }
            try synchronizePublishedTransaction(publishedURL)
            return
        }
        try durability.synchronizeTree(temporaryURL, fileManager: fileManager)
        do {
            try fileManager.moveItem(at: temporaryURL, to: publishedURL)
        } catch {
            if fileManager.fileExists(atPath: publishedURL.path) {
                let existing = try loadTransaction(
                    at: publishedURL,
                    expectedOperation: intent.operation,
                    archiveId: intent.archiveId)
                guard existing == intent else {
                    throw JazzArchiveError.transactionConflict(publishedURL.lastPathComponent)
                }
                try synchronizePublishedTransaction(publishedURL)
                return
            }
            throw error
        }
        try synchronizePublishedTransaction(publishedURL)
    }

    private func recoverTransactions(archiveId: String) throws {
        try JazzArchiveValidation.archiveId(archiveId)
        let createURL = createTransactionURL(archiveId)
        if fileManager.fileExists(atPath: createURL.path) {
            let intent = try loadTransaction(
                at: createURL, expectedOperation: .create, archiveId: archiveId)
            try recoverCreateTransaction(at: createURL, intent: intent)
        }
        guard fileManager.fileExists(atPath: transactionRoot.path) else { return }
        let transactionURLs = try fileManager.contentsOfDirectory(
            at: transactionRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        let appendPrefix = "append-\(archiveId)-"
        for transactionURL
            in transactionURLs
            .filter({ $0.lastPathComponent.hasPrefix(appendPrefix) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        {
            let intent = try loadTransaction(
                at: transactionURL, expectedOperation: .append, archiveId: archiveId)
            try recoverAppendTransaction(at: transactionURL, intent: intent)
        }
        let artifactPrefix = "artifact-\(archiveId)-"
        for transactionURL
            in transactionURLs
            .filter({ $0.lastPathComponent.hasPrefix(artifactPrefix) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        {
            let intent = try loadTransaction(
                at: transactionURL, expectedOperation: .artifact, archiveId: archiveId)
            try recoverArtifactTransaction(at: transactionURL, intent: intent)
        }
        let endPrefix = "end-\(archiveId)-"
        for transactionURL
            in transactionURLs
            .filter({ $0.lastPathComponent.hasPrefix(endPrefix) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        {
            let intent = try loadTransaction(
                at: transactionURL, expectedOperation: .end, archiveId: archiveId)
            try recoverEndTransaction(at: transactionURL, intent: intent)
        }
    }

    private func recoverCreateTransaction(
        at transactionURL: URL,
        intent: TransactionIntent
    ) throws {
        let archiveURL = archiveDirectory(intent.archiveId)
        if fileManager.fileExists(atPath: archiveURL.path) {
            try synchronizeCanonicalArchive(archiveURL)
            try verifyCreatedArchive(archiveURL, intent: intent)
            retireTransaction(at: transactionURL)
            return
        }
        try verifyStagedFiles(at: transactionURL, intent: intent)
        try verifyTransactionSemantics(at: transactionURL, intent: intent)
        let stagedArchiveURL = transactionURL.appendingPathComponent(
            Self.stagedArchiveName, isDirectory: true)
        guard fileManager.fileExists(atPath: stagedArchiveURL.path) else {
            throw JazzArchiveError.transactionCorrupt("missing staged archive")
        }
        do {
            try fileManager.moveItem(at: stagedArchiveURL, to: archiveURL)
            try hit(.createArchivePublished)
        } catch let error as JazzArchiveDraftStoreSimulatedCrash {
            throw error
        } catch {
            guard fileManager.fileExists(atPath: archiveURL.path) else { throw error }
        }
        try synchronizeCanonicalArchive(archiveURL)
        try verifyCreatedArchive(archiveURL, intent: intent)
        retireTransaction(at: transactionURL)
    }

    private func recoverEndTransaction(
        at transactionURL: URL,
        intent: TransactionIntent
    ) throws {
        try verifyStagedFiles(at: transactionURL, intent: intent)
        try verifyTransactionSemantics(at: transactionURL, intent: intent)
        let archiveURL = archiveDirectory(intent.archiveId)
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw JazzArchiveError.transactionConflict("missing archive \(intent.archiveId)")
        }
        // Validate every compare-and-swap precondition before changing any canonical file. A
        // foreign edit therefore aborts the whole roll-forward without partially applying it.
        let filesToPublish = try intent.files.filter {
            try targetNeedsPublication($0, in: archiveURL)
        }
        for file in filesToPublish {
            let targetURL = archiveURL.appendingPathComponent(file.targetPath)
            let stagedURL = transactionURL.appendingPathComponent(file.stagedPath)
            let targetData = try Data(contentsOf: stagedURL)
            guard try targetNeedsPublication(file, in: archiveURL) else { continue }
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try targetData.write(to: targetURL, options: .atomic)
            try hit(endPublicationBoundary(file.role))
        }
        try synchronizeCanonicalTargets(intent, in: archiveURL)
        try verifyEndedArchive(intent)
        retireTransaction(at: transactionURL)
    }

    private func recoverAppendTransaction(
        at transactionURL: URL,
        intent: TransactionIntent
    ) throws {
        try verifyStagedFiles(at: transactionURL, intent: intent)
        try verifyTransactionSemantics(at: transactionURL, intent: intent)
        let archiveURL = archiveDirectory(intent.archiveId)
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw JazzArchiveError.transactionConflict("missing archive \(intent.archiveId)")
        }
        // Preflight every compare-and-swap before publishing the batch. A conflicting manifest or
        // inventory therefore cannot leave a newly visible, unindexed records file.
        let filesToPublish = try intent.files.filter {
            try targetNeedsPublication($0, in: archiveURL)
        }
        for file in filesToPublish {
            let targetURL = archiveURL.appendingPathComponent(file.targetPath)
            let stagedURL = transactionURL.appendingPathComponent(file.stagedPath)
            let targetData = try Data(contentsOf: stagedURL)
            guard try targetNeedsPublication(file, in: archiveURL) else { continue }
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try targetData.write(to: targetURL, options: .atomic)
            try hit(appendPublicationBoundary(file.role))
        }
        try synchronizeCanonicalTargets(intent, in: archiveURL)
        try verifyAppendedArchive(intent)
        retireTransaction(at: transactionURL)
    }

    private func recoverArtifactTransaction(
        at transactionURL: URL,
        intent: TransactionIntent
    ) throws {
        try verifyStagedFiles(at: transactionURL, intent: intent)
        try verifyTransactionSemantics(at: transactionURL, intent: intent)
        let archiveURL = archiveDirectory(intent.archiveId)
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw JazzArchiveError.transactionConflict("missing archive \(intent.archiveId)")
        }
        let filesToPublish = try intent.files.filter {
            try targetNeedsPublication($0, in: archiveURL)
        }
        for file in filesToPublish {
            let targetURL = archiveURL.appendingPathComponent(file.targetPath)
            let stagedURL = transactionURL.appendingPathComponent(file.stagedPath)
            guard try targetNeedsPublication(file, in: archiveURL) else { continue }
            if file.role == .blob {
                _ = try JazzArchiveFileIO.copyAtomically(
                    stagedURL,
                    to: targetURL,
                    expected: JazzArchiveFileFingerprint(
                        sha256: file.targetSHA256, byteLength: file.byteLength),
                    fileManager: fileManager)
            } else {
                let targetData = try Data(contentsOf: stagedURL)
                try fileManager.createDirectory(
                    at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try targetData.write(to: targetURL, options: .atomic)
            }
            try hit(artifactPublicationBoundary(file.role))
        }
        try synchronizeCanonicalTargets(intent, in: archiveURL)
        try verifyArtifactArchive(intent)
        retireTransaction(at: transactionURL)
    }

    private func synchronizePublishedTransaction(_ transactionURL: URL) throws {
        try durability.synchronizeTree(transactionURL, fileManager: fileManager)
        try durability.synchronizeDirectory(transactionRoot)
        try durability.synchronizeDirectory(root)
        try durability.synchronizeDirectory(root.deletingLastPathComponent())
    }

    private func synchronizeCanonicalArchive(_ archiveURL: URL) throws {
        try durability.synchronizeTree(archiveURL, fileManager: fileManager)
        try durability.synchronizeDirectory(root)
        try durability.synchronizeDirectory(root.deletingLastPathComponent())
    }

    private func synchronizeCanonicalTargets(
        _ intent: TransactionIntent,
        in archiveURL: URL
    ) throws {
        var directories = Set<String>()
        for file in intent.files {
            let target = archiveURL.appendingPathComponent(file.targetPath)
            try durability.synchronizeRegularFile(target)
            var directory = target.deletingLastPathComponent().standardizedFileURL
            let archivePath = archiveURL.standardizedFileURL.path
            while directory.path.hasPrefix(archivePath) {
                directories.insert(directory.path)
                guard directory.path != archivePath else { break }
                directory = directory.deletingLastPathComponent().standardizedFileURL
            }
        }
        for path in directories.sorted(by: {
            let left = URL(fileURLWithPath: $0).pathComponents.count
            let right = URL(fileURLWithPath: $1).pathComponents.count
            return left == right ? $0 > $1 : left > right
        }) {
            try durability.synchronizeDirectory(URL(fileURLWithPath: path))
        }
        try durability.synchronizeDirectory(root)
        try durability.synchronizeDirectory(root.deletingLastPathComponent())
    }

    private func publishDeferredData(
        _ data: Data,
        to target: URL,
        archiveId: String
    ) throws {
        guard !fileManager.fileExists(atPath: target.path) else {
            throw JazzArchiveError.transactionConflict(target.lastPathComponent)
        }
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        try synchronizeDeferredTarget(target, archiveId: archiveId)
    }

    private func synchronizeDeferredTarget(
        _ target: URL,
        archiveId: String
    ) throws {
        try durability.synchronizeRegularFile(target, permissions: Int16(0o600))
        let archiveURL = archiveDirectory(archiveId).standardizedFileURL
        var directory = target.deletingLastPathComponent().standardizedFileURL
        while directory.path.hasPrefix(archiveURL.path) {
            try durability.synchronizeDirectory(directory)
            guard directory.path != archiveURL.path else { break }
            directory = directory.deletingLastPathComponent().standardizedFileURL
        }
        try durability.synchronizeDirectory(root)
        try durability.synchronizeDirectory(root.deletingLastPathComponent())
    }

    private func targetNeedsPublication(
        _ file: TransactionFile,
        in archiveURL: URL
    ) throws -> Bool {
        let targetURL = archiveURL.appendingPathComponent(file.targetPath)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            guard file.beforeSHA256 == nil else {
                throw JazzArchiveError.transactionConflict(file.targetPath)
            }
            return true
        }
        let current: JazzArchiveFileFingerprint
        do {
            current = try JazzArchiveFileIO.fingerprint(targetURL)
        } catch {
            throw JazzArchiveError.transactionConflict(file.targetPath)
        }
        if current.sha256 == file.targetSHA256,
            current.byteLength == file.byteLength
        {
            return false
        }
        guard current.sha256 == file.beforeSHA256 else {
            throw JazzArchiveError.transactionConflict(file.targetPath)
        }
        return true
    }

    private func loadTransaction(
        at transactionURL: URL,
        expectedOperation: TransactionOperation,
        archiveId: String
    ) throws -> TransactionIntent {
        do {
            let data = try Data(
                contentsOf: transactionURL.appendingPathComponent(Self.transactionIntentName))
            let intent = try Self.decoder.decode(TransactionIntent.self, from: data)
            try validateTransaction(intent)
            guard intent.operation == expectedOperation, intent.archiveId == archiveId else {
                throw JazzArchiveError.transactionCorrupt(transactionURL.lastPathComponent)
            }
            let expectedURL: URL
            switch intent.operation {
            case .create:
                expectedURL = createTransactionURL(intent.archiveId)
            case .append:
                guard let batchId = intent.batchId else {
                    throw JazzArchiveError.transactionCorrupt("append batch id")
                }
                expectedURL = appendTransactionURL(
                    intent.archiveId, captureId: intent.captureId, batchId: batchId)
            case .artifact:
                guard let artifactId = intent.artifactId else {
                    throw JazzArchiveError.transactionCorrupt("artifact id")
                }
                expectedURL = artifactTransactionURL(
                    intent.archiveId,
                    captureId: intent.captureId,
                    artifactId: artifactId)
            case .end:
                expectedURL = endTransactionURL(
                    intent.archiveId, captureId: intent.captureId)
            }
            guard
                expectedURL.standardizedFileURL.path
                == transactionURL.standardizedFileURL.path
            else { throw JazzArchiveError.transactionCorrupt(transactionURL.lastPathComponent) }
            return intent
        } catch let error as JazzArchiveError {
            throw error
        } catch {
            throw JazzArchiveError.transactionCorrupt(transactionURL.lastPathComponent)
        }
    }

    private func validateTransaction(_ intent: TransactionIntent) throws {
        guard intent.schemaVersion == 1 else {
            throw JazzArchiveError.transactionCorrupt("schema version")
        }
        try JazzArchiveValidation.archiveId(intent.archiveId)
        try JazzArchiveValidation.captureId(intent.captureId)
        let expectedRoles: [TransactionFileRole]
        switch intent.operation {
        case .create:
            expectedRoles = [.session, .inventory, .manifest]
            guard intent.batchId == nil, intent.artifactId == nil,
                let recordsPath = intent.recordsPath
            else {
                throw JazzArchiveError.transactionCorrupt("create records path")
            }
            try JazzArchiveValidation.relativePath(recordsPath)
            guard intent.files.allSatisfy({ $0.beforeSHA256 == nil }) else {
                throw JazzArchiveError.transactionCorrupt("create precondition")
            }
        case .append:
            expectedRoles = [.batch, .inventory, .manifest]
            guard let batchId = intent.batchId,
                intent.artifactId == nil,
                intent.recordsPath == nil,
                intent.files.first?.beforeSHA256 == nil,
                intent.files.dropFirst().allSatisfy({ $0.beforeSHA256 != nil })
            else { throw JazzArchiveError.transactionCorrupt("append precondition") }
            try JazzArchiveValidation.prefixedUUIDv7(batchId, prefix: "batch")
        case .artifact:
            expectedRoles = [.blob, .artifact, .inventory, .manifest]
            guard intent.batchId == nil, let artifactId = intent.artifactId,
                intent.recordsPath == nil,
                intent.files.prefix(2).allSatisfy({ $0.beforeSHA256 == nil }),
                intent.files.dropFirst(2).allSatisfy({ $0.beforeSHA256 != nil })
            else { throw JazzArchiveError.transactionCorrupt("artifact precondition") }
            try JazzArchiveValidation.artifactId(artifactId)
        case .end:
            expectedRoles = [.commit, .session, .inventory, .manifest]
            guard intent.batchId == nil, intent.artifactId == nil, intent.recordsPath == nil,
                intent.files.first?.beforeSHA256 == nil,
                intent.files.dropFirst().allSatisfy({ $0.beforeSHA256 != nil })
            else {
                throw JazzArchiveError.transactionCorrupt("end records path")
            }
        }
        guard intent.files.map(\.role) == expectedRoles,
            Set(intent.files.map(\.targetPath)).count == intent.files.count,
            Set(intent.files.map(\.stagedPath)).count == intent.files.count
        else { throw JazzArchiveError.transactionCorrupt("file registry") }
        for file in intent.files {
            try JazzArchiveValidation.relativePath(file.targetPath)
            try JazzArchiveValidation.relativePath(file.stagedPath)
            if let beforeSHA256 = file.beforeSHA256 {
                try JazzArchiveValidation.sha256(
                    beforeSHA256, field: "transaction.beforeSHA256")
            }
            try JazzArchiveValidation.sha256(
                file.targetSHA256, field: "transaction.targetSHA256")
            guard file.byteLength >= 0 else {
                throw JazzArchiveError.transactionCorrupt("file length")
            }
        }
    }

    private func verifyStagedFiles(
        at transactionURL: URL,
        intent: TransactionIntent
    ) throws {
        for file in intent.files {
            let fingerprint: JazzArchiveFileFingerprint
            do {
                fingerprint = try JazzArchiveFileIO.fingerprint(
                    transactionURL.appendingPathComponent(file.stagedPath))
            } catch {
                throw JazzArchiveError.transactionCorrupt("missing \(file.stagedPath)")
            }
            guard fingerprint.byteLength == file.byteLength,
                fingerprint.sha256 == file.targetSHA256
            else { throw JazzArchiveError.transactionCorrupt(file.stagedPath) }
        }
    }

    private func verifyTransactionSemantics(
        at transactionURL: URL,
        intent: TransactionIntent
    ) throws {
        do {
            switch intent.operation {
            case .append:
                try verifyAppendTransactionSemantics(at: transactionURL, intent: intent)
                return
            case .artifact:
                try verifyArtifactTransactionSemantics(at: transactionURL, intent: intent)
                return
            case .create, .end:
                break
            }
            let manifestData = try stagedData(.manifest, at: transactionURL, intent: intent)
            let sessionData = try stagedData(.session, at: transactionURL, intent: intent)
            let inventoryData = try stagedData(.inventory, at: transactionURL, intent: intent)
            let manifest = try Self.decoder.decode(JazzArchiveManifest.self, from: manifestData)
            let session = try Self.decoder.decode(JazzArchiveSession.self, from: sessionData)
            let inventory = try Self.decoder.decode(JazzArchiveInventory.self, from: inventoryData)
            try validate(session: session, in: manifest)
            try inventory.validate()
            let manifestFile = try transactionFile(.manifest, in: intent)
            let inventoryFile = try transactionFile(.inventory, in: intent)
            let sessionFile = try transactionFile(.session, in: intent)
            guard manifest.archiveId == intent.archiveId,
                session.archiveId == intent.archiveId,
                session.captureId == intent.captureId,
                manifest.inventory.digest == JazzArchiveDigest.sha256Hex(inventoryData),
                let sessionRef = manifest.sessions.first(where: {
                    $0.captureId == intent.captureId
                }),
                manifestFile.targetPath == Self.manifestName,
                inventoryFile.targetPath == manifest.inventory.path,
                sessionFile.targetPath == sessionRef.path
            else { throw JazzArchiveError.transactionCorrupt("transaction identity") }

            let expectedSessionEntry = inventoryEntry(path: sessionRef.path, data: sessionData)
            guard inventory.entries.contains(expectedSessionEntry) else {
                throw JazzArchiveError.transactionCorrupt("session inventory entry")
            }
            switch intent.operation {
            case .create:
                guard session.status == .open,
                    session.captureCommit == nil,
                    manifest.captureCommits == nil,
                    intent.recordsPath == pathBesideSession(sessionRef, child: "records"),
                    inventory.entries == [expectedSessionEntry],
                    intent.files.allSatisfy({
                        $0.stagedPath.hasPrefix("\(Self.stagedArchiveName)/")
                    })
                else { throw JazzArchiveError.transactionCorrupt("create semantics") }
            case .append:
                throw JazzArchiveError.transactionCorrupt("append semantic dispatch")
            case .artifact:
                throw JazzArchiveError.transactionCorrupt("artifact semantic dispatch")
            case .end:
                let commitData = try stagedData(.commit, at: transactionURL, intent: intent)
                let commit = try Self.decoder.decode(
                    JazzArchiveCaptureCommit.self, from: commitData)
                try commit.validate()
                let commitFile = try transactionFile(.commit, in: intent)
                guard session.status != .open,
                    let commitRef = session.captureCommit,
                    commitRef.commitId == commit.commitId,
                    commitRef.captureId == intent.captureId,
                    commit.captureId == intent.captureId,
                    commitRef.digest == JazzArchiveDigest.sha256Hex(commitData),
                    commitFile.targetPath == commitRef.path,
                    inventory.entries.contains(
                        inventoryEntry(path: commitRef.path, data: commitData)),
                    intent.files.allSatisfy({
                        $0.stagedPath.hasPrefix("\(Self.stagedPayloadName)/")
                    })
                else { throw JazzArchiveError.transactionCorrupt("end semantics") }
            }
        } catch let error as JazzArchiveError {
            switch error {
            case .transactionCorrupt, .transactionConflict:
                throw error
            default:
                throw JazzArchiveError.transactionCorrupt(error.description)
            }
        } catch {
            throw JazzArchiveError.transactionCorrupt("semantic decode")
        }
    }

    private func verifyAppendTransactionSemantics(
        at transactionURL: URL,
        intent: TransactionIntent
    ) throws {
        let manifestData = try stagedData(.manifest, at: transactionURL, intent: intent)
        let inventoryData = try stagedData(.inventory, at: transactionURL, intent: intent)
        let batchData = try stagedData(.batch, at: transactionURL, intent: intent)
        let manifest = try Self.decoder.decode(JazzArchiveManifest.self, from: manifestData)
        let inventory = try Self.decoder.decode(JazzArchiveInventory.self, from: inventoryData)
        let session = try readSession(intent.archiveId, intent.captureId)
        try validate(session: session, in: manifest)
        try inventory.validate()
        guard let batchId = intent.batchId,
            manifest.archiveId == intent.archiveId,
            manifest.state == .live,
            session.status == .open,
            manifest.inventory.digest == JazzArchiveDigest.sha256Hex(inventoryData),
            let sessionRef = manifest.sessions.first(where: {
                $0.captureId == intent.captureId
            })
        else { throw JazzArchiveError.transactionCorrupt("append identity") }
        let expectedBatchPath = pathBesideSession(
            sessionRef, child: "records/\(batchId).ndjson")
        let batchFile = try transactionFile(.batch, in: intent)
        let inventoryFile = try transactionFile(.inventory, in: intent)
        let manifestFile = try transactionFile(.manifest, in: intent)
        guard batchFile.targetPath == expectedBatchPath,
            inventoryFile.targetPath == manifest.inventory.path,
            manifestFile.targetPath == Self.manifestName,
            inventory.entries.contains(inventoryEntry(path: expectedBatchPath, data: batchData)),
            intent.files.allSatisfy({
                $0.stagedPath.hasPrefix("\(Self.stagedPayloadName)/")
            })
        else { throw JazzArchiveError.transactionCorrupt("append paths") }

        let lines = String(decoding: batchData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty, batchData.last == Character("\n").asciiValue else {
            throw JazzArchiveError.transactionCorrupt("append batch framing")
        }
        var records: [JazzArchiveRecord] = []
        for line in lines {
            let record = try Self.decoder.decode(JazzArchiveRecord.self, from: Data(line.utf8))
            try record.validateRecord(manifest: manifest, session: session)
            records.append(record)
        }
        try JazzArchiveValidation.unique(records.map(\.observationId), kind: "observation")
        try JazzArchiveValidation.unique(records.map(streamKey), kind: "stream sequence")
    }

    private func verifyArtifactTransactionSemantics(
        at transactionURL: URL,
        intent: TransactionIntent
    ) throws {
        let manifestData = try stagedData(.manifest, at: transactionURL, intent: intent)
        let inventoryData = try stagedData(.inventory, at: transactionURL, intent: intent)
        let artifactData = try stagedData(.artifact, at: transactionURL, intent: intent)
        let manifest = try Self.decoder.decode(JazzArchiveManifest.self, from: manifestData)
        let inventory = try Self.decoder.decode(JazzArchiveInventory.self, from: inventoryData)
        let artifact = try Self.decoder.decode(JazzArchiveArtifact.self, from: artifactData)
        let session = try readSession(intent.archiveId, intent.captureId)
        try artifact.validate(manifest: manifest, session: session)
        try inventory.validate()
        guard let artifactId = intent.artifactId,
            artifact.artifactId == artifactId,
            artifact.captureId == intent.captureId,
            manifest.archiveId == intent.archiveId,
            manifest.state == .live,
            session.status == .open,
            manifest.inventory.digest == JazzArchiveDigest.sha256Hex(inventoryData),
            let sessionRef = manifest.sessions.first(where: {
                $0.captureId == intent.captureId
            })
        else { throw JazzArchiveError.transactionCorrupt("artifact identity") }
        let expectedDocumentPath = pathBesideSession(
            sessionRef, child: "artifacts/\(artifactId).json")
        let blobFile = try transactionFile(.blob, in: intent)
        let artifactFile = try transactionFile(.artifact, in: intent)
        let inventoryFile = try transactionFile(.inventory, in: intent)
        let manifestFile = try transactionFile(.manifest, in: intent)
        guard blobFile.targetPath == artifact.content.path,
            blobFile.byteLength == artifact.content.byteLength,
            blobFile.targetSHA256 == artifact.content.sha256,
            artifactFile.targetPath == expectedDocumentPath,
            inventoryFile.targetPath == manifest.inventory.path,
            manifestFile.targetPath == Self.manifestName,
            inventory.entries.contains(
                JazzArchiveInventoryEntry(
                path: artifact.content.path,
                byteLength: blobFile.byteLength,
                sha256: blobFile.targetSHA256)),
            inventory.entries.contains(inventoryEntry(path: expectedDocumentPath, data: artifactData)),
            intent.files.allSatisfy({
                $0.stagedPath.hasPrefix("\(Self.stagedPayloadName)/")
            })
        else { throw JazzArchiveError.transactionCorrupt("artifact paths") }
    }

    private func stagedData(
        _ role: TransactionFileRole,
        at transactionURL: URL,
        intent: TransactionIntent
    ) throws -> Data {
        let file = try transactionFile(role, in: intent)
        return try Data(contentsOf: transactionURL.appendingPathComponent(file.stagedPath))
    }

    private func transactionFile(
        _ role: TransactionFileRole,
        in intent: TransactionIntent
    ) throws -> TransactionFile {
        guard let file = intent.files.first(where: { $0.role == role }) else {
            throw JazzArchiveError.transactionCorrupt("missing role \(role.rawValue)")
        }
        return file
    }

    private func verifyCreatedArchive(
        _ archiveURL: URL,
        intent: TransactionIntent
    ) throws {
        for file in intent.files {
            let fingerprint: JazzArchiveFileFingerprint
            do {
                fingerprint = try JazzArchiveFileIO.fingerprint(
                    archiveURL.appendingPathComponent(file.targetPath))
            } catch {
                throw JazzArchiveError.transactionConflict(file.targetPath)
            }
            guard fingerprint.byteLength == file.byteLength,
                fingerprint.sha256 == file.targetSHA256
            else { throw JazzArchiveError.transactionConflict(file.targetPath) }
        }
        let expectedFiles = Set(intent.files.map(\.targetPath))
        guard try regularFilePaths(below: archiveURL) == expectedFiles,
            let recordsPath = intent.recordsPath,
            isDirectory(archiveURL.appendingPathComponent(recordsPath))
        else { throw JazzArchiveError.transactionConflict(intent.archiveId) }
        let manifest = try readManifest(intent.archiveId)
        _ = try readSession(intent.archiveId, intent.captureId)
        _ = try readInventory(intent.archiveId, manifest: manifest, verifyFiles: true)
    }

    private func verifyEndedArchive(_ intent: TransactionIntent) throws {
        let manifest = try readManifest(intent.archiveId)
        let session = try readSession(intent.archiveId, intent.captureId)
        guard session.status != .open, let commitRef = session.captureCommit else {
            throw JazzArchiveError.transactionConflict("end state \(intent.captureId)")
        }
        let commitData = try Data(
            contentsOf: archiveDirectory(intent.archiveId).appendingPathComponent(commitRef.path))
        guard JazzArchiveDigest.sha256Hex(commitData) == commitRef.digest else {
            throw JazzArchiveError.transactionConflict(commitRef.path)
        }
        let commit = try Self.decoder.decode(JazzArchiveCaptureCommit.self, from: commitData)
        try commit.validate()
        _ = try readInventory(intent.archiveId, manifest: manifest, verifyFiles: true)
    }

    private func verifyAppendedArchive(_ intent: TransactionIntent) throws {
        let manifest = try readManifest(intent.archiveId)
        let session = try readSession(intent.archiveId, intent.captureId)
        guard manifest.state == .live, session.status == .open,
            let batchFile = intent.files.first(where: { $0.role == .batch })
        else { throw JazzArchiveError.transactionConflict("append state \(intent.captureId)") }
        let inventory = try readInventory(
            intent.archiveId, manifest: manifest, verifyFiles: false)
        guard
            let entry = inventory.entries.first(where: {
            $0.path == batchFile.targetPath
                && $0.byteLength == batchFile.byteLength
                && $0.sha256 == batchFile.targetSHA256
            })
        else { throw JazzArchiveError.transactionConflict(batchFile.targetPath) }
        try verifyTargetFile(
            archiveId: intent.archiveId,
            path: batchFile.targetPath,
            expected: entry)
    }

    private func verifyArtifactArchive(_ intent: TransactionIntent) throws {
        guard let artifactId = intent.artifactId else {
            throw JazzArchiveError.transactionCorrupt("artifact id")
        }
        let manifest = try readManifest(intent.archiveId)
        let inventory = try readInventory(
            intent.archiveId, manifest: manifest, verifyFiles: false)
        for role in [TransactionFileRole.blob, .artifact] {
            let file = try transactionFile(role, in: intent)
            guard
                let entry = inventory.entries.first(where: {
                $0.path == file.targetPath
                    && $0.byteLength == file.byteLength
                    && $0.sha256 == file.targetSHA256
                })
            else { throw JazzArchiveError.transactionConflict(file.targetPath) }
            try verifyTargetFile(
                archiveId: intent.archiveId,
                path: file.targetPath,
                expected: entry)
                }
        let artifact = try readArtifact(
            archiveId: intent.archiveId,
            captureId: intent.captureId,
            artifactId: artifactId,
            verifyInventoryFiles: false)
        guard artifact.artifactId == artifactId else {
            throw JazzArchiveError.transactionConflict(artifactId)
        }
    }

    private func regularFilePaths(below directory: URL) throws -> Set<String> {
        guard let enumerator = fileManager.enumerator(atPath: directory.path)
        else { throw JazzArchiveError.transactionConflict(directory.lastPathComponent) }
        var result = Set<String>()
        for case let relativePath as String in enumerator {
            let url = directory.appendingPathComponent(relativePath)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            result.insert(relativePath)
        }
        return result
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func retireTransaction(at transactionURL: URL) {
        guard fileManager.fileExists(atPath: transactionURL.path) else { return }
        let retiredURL = transactionRoot.appendingPathComponent(
            ".retired-\(Identifiers.newUUIDv7().uuidString.lowercased())", isDirectory: true)
        do {
            try fileManager.moveItem(at: transactionURL, to: retiredURL)
            try? fileManager.removeItem(at: retiredURL)
        } catch {
            // Canonical state is already complete. Leaving the published marker makes the next
            // recovery verify it again instead of risking deletion of evidence.
        }
    }

    private func transactionData(
        _ role: TransactionFileRole,
        in values: [TransactionFileRole: Data]
    ) throws -> Data {
        guard let value = values[role] else {
            throw JazzArchiveError.transactionCorrupt("missing data \(role.rawValue)")
        }
        return value
    }

    private func createStagingBoundary(
        _ role: TransactionFileRole
    ) throws -> JazzArchiveDraftStoreWriteBoundary {
        switch role {
        case .session: return .createStagedSession
        case .inventory: return .createStagedInventory
        case .manifest: return .createStagedManifest
        case .batch, .blob, .artifact, .commit:
            throw JazzArchiveError.transactionCorrupt("create \(role.rawValue) role")
        }
    }

    private func appendStagingBoundary(
        _ role: TransactionFileRole
    ) throws -> JazzArchiveDraftStoreWriteBoundary {
        switch role {
        case .batch: return .appendStagedBatch
        case .inventory: return .appendStagedInventory
        case .manifest: return .appendStagedManifest
        case .blob, .artifact, .commit, .session:
            throw JazzArchiveError.transactionCorrupt("append \(role.rawValue) role")
        }
    }

    private func appendPublicationBoundary(
        _ role: TransactionFileRole
    ) throws -> JazzArchiveDraftStoreWriteBoundary {
        switch role {
        case .batch: return .appendBatchPublished
        case .inventory: return .appendInventoryPublished
        case .manifest: return .appendManifestPublished
        case .blob, .artifact, .commit, .session:
            throw JazzArchiveError.transactionCorrupt("append \(role.rawValue) role")
        }
    }

    private func endStagingBoundary(
        _ role: TransactionFileRole
    ) throws -> JazzArchiveDraftStoreWriteBoundary {
        switch role {
        case .commit: return .endStagedCommit
        case .session: return .endStagedSession
        case .inventory: return .endStagedInventory
        case .manifest: return .endStagedManifest
        case .batch, .blob, .artifact:
            throw JazzArchiveError.transactionCorrupt("end \(role.rawValue) role")
        }
    }

    private func endPublicationBoundary(
        _ role: TransactionFileRole
    ) throws -> JazzArchiveDraftStoreWriteBoundary {
        switch role {
        case .commit: return .endCommitPublished
        case .session: return .endSessionPublished
        case .inventory: return .endInventoryPublished
        case .manifest: return .endManifestPublished
        case .batch, .blob, .artifact:
            throw JazzArchiveError.transactionCorrupt("end \(role.rawValue) role")
        }
    }

    private func artifactStagingBoundary(
        _ role: TransactionFileRole
    ) throws -> JazzArchiveDraftStoreWriteBoundary {
        switch role {
        case .blob: return .artifactStagedBlob
        case .artifact: return .artifactStagedDocument
        case .inventory: return .artifactStagedInventory
        case .manifest: return .artifactStagedManifest
        case .batch, .commit, .session:
            throw JazzArchiveError.transactionCorrupt("artifact \(role.rawValue) role")
        }
    }

    private func artifactPublicationBoundary(
        _ role: TransactionFileRole
    ) throws -> JazzArchiveDraftStoreWriteBoundary {
        switch role {
        case .blob: return .artifactBlobPublished
        case .artifact: return .artifactDocumentPublished
        case .inventory: return .artifactInventoryPublished
        case .manifest: return .artifactManifestPublished
        case .batch, .commit, .session:
            throw JazzArchiveError.transactionCorrupt("artifact \(role.rawValue) role")
        }
    }

    private func hit(_ boundary: JazzArchiveDraftStoreWriteBoundary) throws {
        if simulatedCrashAfter == boundary {
            throw JazzArchiveDraftStoreSimulatedCrash.after(boundary)
        }
    }

    private var transactionRoot: URL {
        root.appendingPathComponent(Self.transactionRootName, isDirectory: true)
    }

    private func createTransactionURL(_ archiveId: String) -> URL {
        transactionRoot.appendingPathComponent("create-\(archiveId)", isDirectory: true)
    }

    private func endTransactionURL(_ archiveId: String, captureId: String) -> URL {
        transactionRoot.appendingPathComponent(
            "end-\(archiveId)-\(captureId)", isDirectory: true)
    }

    private func appendTransactionURL(
        _ archiveId: String,
        captureId: String,
        batchId: String
    ) -> URL {
        transactionRoot.appendingPathComponent(
            "append-\(archiveId)-\(captureId)-\(batchId)", isDirectory: true)
    }

    private func artifactTransactionURL(
        _ archiveId: String,
        captureId: String,
        artifactId: String
    ) -> URL {
        transactionRoot.appendingPathComponent(
            "artifact-\(archiveId)-\(captureId)-\(artifactId)", isDirectory: true)
    }

    private func requiredPath(_ value: String?) throws -> String {
        guard let value else {
            throw JazzArchiveError.transactionCorrupt("missing path")
        }
        return value
    }

    private func validate(session: JazzArchiveSession, in manifest: JazzArchiveManifest) throws {
        try manifest.validate()
        try session.validate()
        guard session.archiveId == manifest.archiveId else {
            throw JazzArchiveError.referenceMismatch(
                field: "session.archiveId", expected: manifest.archiveId, actual: session.archiveId)
        }
        guard
            manifest.sessions.contains(where: {
            $0.captureId == session.captureId
                && $0.legacySessionId == session.legacySessionId
            })
        else {
            throw JazzArchiveError.missingReference(
                kind: "manifest capture", id: session.captureId)
        }
        let actorIds = Set(manifest.actors.map(\.actorId))
        guard actorIds.contains(session.recorderActorId) else {
            throw JazzArchiveError.missingReference(kind: "actor", id: session.recorderActorId)
        }
        let sourceIds = Set(manifest.sources.map(\.sourceId))
        for sourceId in session.sourceIds where !sourceIds.contains(sourceId) {
            throw JazzArchiveError.missingReference(kind: "source", id: sourceId)
        }
        if let commitRef = session.captureCommit,
            !(manifest.captureCommits ?? []).contains(commitRef)
        {
            throw JazzArchiveError.missingReference(
                kind: "manifest capture commit", id: commitRef.commitId)
        }
    }

    private func readManifest(_ archiveId: String) throws -> JazzArchiveManifest {
        try JazzArchiveValidation.archiveId(archiveId)
        let url = manifestURL(archiveId)
        guard fileManager.fileExists(atPath: url.path) else {
            throw JazzArchiveError.archiveNotFound(archiveId)
        }
        let manifest = try Self.decoder.decode(
            JazzArchiveManifest.self, from: Data(contentsOf: url))
        try manifest.validate()
        guard manifest.archiveId == archiveId else {
            throw JazzArchiveError.referenceMismatch(
                field: "archiveId", expected: archiveId, actual: manifest.archiveId)
        }
        return manifest
    }

    private func readSession(_ archiveId: String, _ captureId: String) throws -> JazzArchiveSession {
        let manifest = try readManifest(archiveId)
        let ref = try captureRef(in: manifest, captureId: captureId)
        let session = try Self.decoder.decode(
            JazzArchiveSession.self, from: Data(contentsOf: sessionURL(archiveId, ref)))
        try validate(session: session, in: manifest)
        return session
    }

    private func readInventory(
        _ archiveId: String,
        manifest: JazzArchiveManifest,
        verifyFiles: Bool
    ) throws -> JazzArchiveInventory {
        let data = try Data(contentsOf: inventoryURL(archiveId))
        guard JazzArchiveDigest.sha256Hex(data) == manifest.inventory.digest else {
            throw JazzArchiveError.digestMismatch(path: manifest.inventory.path)
        }
        let inventory = try Self.decoder.decode(JazzArchiveInventory.self, from: data)
        try inventory.validate()
        if verifyFiles {
            for entry in inventory.entries {
                workObserver?(.inventoryEntryFingerprint)
                let fingerprint = try JazzArchiveFileIO.fingerprint(
                    archiveDirectory(archiveId).appendingPathComponent(entry.path))
                guard fingerprint.byteLength == entry.byteLength,
                    fingerprint.sha256 == entry.sha256
                else { throw JazzArchiveError.digestMismatch(path: entry.path) }
            }
        }
        return inventory
    }

    /// Merge immutable journal-published files into the next portable inventory checkpoint.
    /// Existing entries remain compare-and-swap protected; an unindexed record/artifact is accepted
    /// only while its session is open and every referenced byte is fingerprinted here.
    private func materializedInventory(
        archiveId: String,
        captureId: String,
        manifest: JazzArchiveManifest
    ) throws -> JazzArchiveInventory {
        var inventory = try readInventory(
            archiveId, manifest: manifest, verifyFiles: true)
        let session = try readSession(archiveId, captureId)
        guard session.status == .open else {
            throw JazzArchiveError.sessionNotOpen(captureId)
        }
        let sessionRef = try captureRef(in: manifest, captureId: captureId)
        var entriesByPath = Dictionary(
            uniqueKeysWithValues: inventory.entries.map { ($0.path, $0) })

        func merge(_ entry: JazzArchiveInventoryEntry) throws {
            if let existing = entriesByPath[entry.path] {
                guard existing == entry else {
                    throw JazzArchiveError.digestMismatch(path: entry.path)
                }
            } else {
                entriesByPath[entry.path] = entry
            }
        }

        let recordPrefix = pathBesideSession(sessionRef, child: "records/")
        let recordURLs =
            (try? fileManager.contentsOfDirectory(
                at: recordsDirectory(archiveId, sessionRef),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))?
            .filter {
                $0.pathExtension == "ndjson"
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            ?? []
        for url in recordURLs {
            let fingerprint = try JazzArchiveFileIO.fingerprint(url)
            try merge(inventoryEntry(
                path: recordPrefix + url.lastPathComponent,
                fingerprint: fingerprint))
        }

        let artifactPrefix = pathBesideSession(sessionRef, child: "artifacts/")
        let artifactDirectory = archiveDirectory(archiveId).appendingPathComponent(
            pathBesideSession(sessionRef, child: "artifacts"),
            isDirectory: true)
        let artifactURLs =
            (try? fileManager.contentsOfDirectory(
                at: artifactDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))?
            .filter {
                $0.pathExtension == "json"
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            ?? []
        var artifactIds = Set<String>()
        for url in artifactURLs {
            let documentData = try Data(contentsOf: url)
            let artifact = try Self.decoder.decode(
                JazzArchiveArtifact.self, from: documentData)
            try artifact.validate(manifest: manifest, session: session)
            guard artifactIds.insert(artifact.artifactId).inserted,
                url.deletingPathExtension().lastPathComponent == artifact.artifactId
            else {
                throw JazzArchiveError.duplicateIdentifier(
                    kind: "artifact", id: artifact.artifactId)
            }
            try merge(inventoryEntry(
                path: artifactPrefix + url.lastPathComponent,
                data: documentData))
            let blobURL = archiveDirectory(archiveId).appendingPathComponent(
                artifact.content.path)
            let blob = try JazzArchiveFileIO.fingerprint(blobURL)
            guard blob.byteLength == artifact.content.byteLength,
                blob.sha256 == artifact.content.sha256
            else { throw JazzArchiveError.digestMismatch(path: artifact.content.path) }
            try merge(inventoryEntry(
                path: artifact.content.path,
                fingerprint: blob))
        }

        inventory.entries = entriesByPath.values.sorted { $0.path < $1.path }
        try inventory.validate()
        return inventory
    }

    private func liveCaptureKey(archiveId: String, captureId: String) -> String {
        "\(archiveId)/\(captureId)"
    }

    private func rememberEmptyCapture(
        archiveId: String,
        captureId: String,
        inventoryDigest: String
    ) {
        liveCaptureIndexes[liveCaptureKey(archiveId: archiveId, captureId: captureId)] =
            LiveCaptureIndex(
                inventoryDigest: inventoryDigest,
                observationIds: [],
                streamKeys: [])
    }

    private func liveCaptureIndex(
        archiveId: String,
        captureId: String,
        manifest: JazzArchiveManifest
    ) throws -> LiveCaptureIndex {
        let key = liveCaptureKey(archiveId: archiveId, captureId: captureId)
        if let cached = liveCaptureIndexes[key],
            cached.inventoryDigest == manifest.inventory.digest
        {
            return cached
        }

        // A fresh process, explicit recovery, or a foreign writer invalidates the in-memory index.
        // Pay one strict O(n) verification/read, then keep subsequent appends targeted.
        let records = try readRecords(archiveId: archiveId, captureId: captureId)
        let currentManifest = try readManifest(archiveId)
        guard currentManifest.inventory.digest == manifest.inventory.digest else {
            throw JazzArchiveError.transactionConflict(manifest.inventory.path)
        }
        let index = LiveCaptureIndex(
            inventoryDigest: manifest.inventory.digest,
            observationIds: Set(records.map(\.observationId)),
            streamKeys: Set(records.map(streamKey)))
        liveCaptureIndexes[key] = index
        return index
    }

    private func rememberStrictlyVerifiedRecords(
        _ records: [JazzArchiveRecord],
        archiveId: String,
        captureId: String
    ) throws {
        let manifest = try readManifest(archiveId)
        liveCaptureIndexes[liveCaptureKey(archiveId: archiveId, captureId: captureId)] =
            LiveCaptureIndex(
                inventoryDigest: manifest.inventory.digest,
                observationIds: Set(records.map(\.observationId)),
                streamKeys: Set(records.map(streamKey)))
    }

    private func updateCachedInventoryDigest(
        archiveId: String,
        captureId: String,
        inventoryDigest: String
    ) {
        let key = liveCaptureKey(archiveId: archiveId, captureId: captureId)
        guard var cached = liveCaptureIndexes[key] else { return }
        cached.inventoryDigest = inventoryDigest
        liveCaptureIndexes[key] = cached
    }

    private func verifyTargetFile(
        archiveId: String,
        path: String,
        expected: JazzArchiveInventoryEntry
    ) throws {
        guard expected.path == path else {
            throw JazzArchiveError.transactionConflict(path)
        }
        workObserver?(.targetedFileFingerprint)
        let actual = try JazzArchiveFileIO.fingerprint(
            archiveDirectory(archiveId).appendingPathComponent(path))
        guard actual.byteLength == expected.byteLength,
            actual.sha256 == expected.sha256
        else { throw JazzArchiveError.digestMismatch(path: path) }
    }

    private func inventoryEntry(path: String, data: Data) -> JazzArchiveInventoryEntry {
        JazzArchiveInventoryEntry(
            path: path,
            byteLength: Int64(data.count),
            sha256: JazzArchiveDigest.sha256Hex(data))
    }

    private func inventoryEntry(
        path: String,
        fingerprint: JazzArchiveFileFingerprint
    ) -> JazzArchiveInventoryEntry {
        JazzArchiveInventoryEntry(
            path: path,
            byteLength: fingerprint.byteLength,
            sha256: fingerprint.sha256)
    }

    private func streamKey(_ record: JazzArchiveRecord) -> String {
        "\(record.streamId):\(record.streamSequence)"
    }

    private func archiveDirectory(_ archiveId: String) -> URL {
        root.appendingPathComponent("\(archiveId).jazz-archive.draft", isDirectory: true)
    }

    private func manifestURL(_ archiveId: String) -> URL {
        archiveDirectory(archiveId).appendingPathComponent(Self.manifestName)
    }

    private func inventoryURL(_ archiveId: String) -> URL {
        archiveDirectory(archiveId).appendingPathComponent("inventory.json")
    }

    private func captureRef(
        in manifest: JazzArchiveManifest,
        captureId: String
    ) throws -> JazzArchiveSessionRef {
        guard let ref = manifest.sessions.first(where: { $0.captureId == captureId }) else {
            throw JazzArchiveError.missingReference(kind: "capture", id: captureId)
        }
        return ref
    }

    private func pathBesideSession(_ ref: JazzArchiveSessionRef, child: String) -> String {
        let parent = ref.path.split(separator: "/").dropLast().joined(separator: "/")
        return parent.isEmpty ? child : "\(parent)/\(child)"
    }

    private func sessionURL(_ archiveId: String, _ ref: JazzArchiveSessionRef) -> URL {
        archiveDirectory(archiveId).appendingPathComponent(ref.path)
    }

    private func recordsDirectory(_ archiveId: String, _ ref: JazzArchiveSessionRef) -> URL {
        archiveDirectory(archiveId)
            .appendingPathComponent(pathBesideSession(ref, child: "records"), isDirectory: true)
    }

    private static let decoder = JSONDecoder()

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JazzArchiveCanonicalJSON.encode(value)
    }

    private static func encodeCanonicalInventory(_ value: JazzArchiveInventory) throws -> Data {
        var sorted = value
        sorted.entries.sort { $0.path < $1.path }
        return try encode(sorted)
    }
}

// MARK: - RFC 8785 canonical JSON

/// Minimal Foundation-only RFC 8785 encoder for archive hashing. Values first pass through their
/// Codable representation; object keys are then ordered by UTF-16 code units and primitives are
/// emitted without insignificant whitespace or optional escaping.
public enum JazzArchiveCanonicalJSON {
    private static let maximumSafeInteger: UInt64 = 9_007_199_254_740_991

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        var output = ""
        try append(object, to: &output)
        return Data(output.utf8)
    }

    private static func append(_ value: Any, to output: inout String) throws {
        if value is NSNull {
            output += "null"
        } else if let dictionary = value as? [String: Any] {
            output += "{"
            let keys = dictionary.keys.sorted { left, right in
                left.utf16.lexicographicallyPrecedes(right.utf16)
            }
            for (index, key) in keys.enumerated() {
                if index > 0 { output += "," }
                appendString(key, to: &output)
                output += ":"
                try append(dictionary[key]!, to: &output)
            }
            output += "}"
        } else if let array = value as? [Any] {
            output += "["
            for (index, element) in array.enumerated() {
                if index > 0 { output += "," }
                try append(element, to: &output)
            }
            output += "]"
        } else if let string = value as? String {
            appendString(string, to: &output)
        } else if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            if type == "c" {
                output += number.boolValue ? "true" : "false"
            } else if "CSILQ".contains(type) {
                guard number.uint64Value <= maximumSafeInteger else {
                    throw JazzArchiveError.invalidNumber(field: "JSON safe integer")
                }
                output += number.stringValue
            } else if "silq".contains(type) {
                let integer = number.int64Value
                guard
                    integer >= -Int64(maximumSafeInteger)
                    && integer <= Int64(maximumSafeInteger)
                else {
                    throw JazzArchiveError.invalidNumber(field: "JSON safe integer")
                }
                output += number.stringValue
            } else {
                output += try canonicalNumber(number.doubleValue)
            }
        } else {
            throw JazzArchiveError.invalidField("canonical JSON value")
        }
    }

    private static func appendString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: output += "\\b"
            case 0x09: output += "\\t"
            case 0x0a: output += "\\n"
            case 0x0c: output += "\\f"
            case 0x0d: output += "\\r"
            case 0x22: output += "\\\""
            case 0x5c: output += "\\\\"
            case 0x00...0x1f:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    private static func canonicalNumber(_ value: Double) throws -> String {
        guard value.isFinite,
            Swift.abs(value) < Double(maximumSafeInteger) + 1
        else {
            throw JazzArchiveError.invalidNumber(field: "JSON number")
        }
        if value == 0 { return "0" }

        let negative = value < 0
        var representation = String(negative ? -value : value).lowercased()
        let exponent: Int
        if let marker = representation.firstIndex(of: "e") {
            exponent = Int(representation[representation.index(after: marker)...]) ?? 0
            representation = String(representation[..<marker])
        } else {
            exponent = 0
        }
        let pieces = representation.split(separator: ".", omittingEmptySubsequences: false)
        var digits = pieces.joined()
        var point = pieces[0].count + exponent
        while digits.first == "0", digits.count > 1 {
            digits.removeFirst()
            point -= 1
        }
        while digits.last == "0", digits.count > 1, point < digits.count {
            digits.removeLast()
        }

        let magnitude = Swift.abs(value)
        let body: String
        if magnitude >= 1e-6 && magnitude < 1e21 {
            if point <= 0 {
                body = "0." + String(repeating: "0", count: -point) + digits
            } else if point >= digits.count {
                body = digits + String(repeating: "0", count: point - digits.count)
            } else {
                let split = digits.index(digits.startIndex, offsetBy: point)
                body = String(digits[..<split]) + "." + String(digits[split...])
            }
        } else {
            let rest = digits.dropFirst()
            let mantissa = String(digits.first!) + (rest.isEmpty ? "" : "." + rest)
            let scientificExponent = point - 1
            body =
                mantissa + "e" + (scientificExponent >= 0 ? "+" : "")
                + String(scientificExponent)
        }
        return (negative ? "-" : "") + body
    }
}

// MARK: - Foundation-only SHA-256 for inventory integrity

/// Small dependency-free SHA-256 used only for archive integrity. This is hashing, not archive
/// encryption; no key material or CryptoKit dependency is introduced into the Foundation core.
public enum JazzArchiveDigest {
    public static func sha256Hex(_ data: Data) -> String {
        var hasher = JazzArchiveSHA256()
        hasher.update(data)
        return hasher.finalizeHex()
    }

    public static func sha256File(_ url: URL) throws -> JazzArchiveFileFingerprint {
        try JazzArchiveFileIO.fingerprint(url)
    }
}

// MARK: - Validation helpers

private enum JazzArchiveValidation {
    static func archiveId(_ value: String) throws { try prefixedUUIDv7(value, prefix: "ar") }
    static func originId(_ value: String) throws { try prefixedUUIDv7(value, prefix: "origin") }
    static func commitId(_ value: String) throws { try prefixedUUIDv7(value, prefix: "cmt") }
    static func sessionId(_ value: String) throws { try prefixedUUID(value, prefix: "s") }
    static func captureId(_ value: String) throws { try prefixedUUIDv7(value, prefix: "cap") }
    static func streamId(_ value: String) throws { try prefixedUUIDv7(value, prefix: "stream") }
    static func observationId(_ value: String) throws { try prefixedUUIDv7(value, prefix: "obs") }
    static func actorId(_ value: String) throws { try prefixedUUIDv7(value, prefix: "actor") }
    static func sourceId(_ value: String) throws { try prefixedUUIDv7(value, prefix: "src") }
    static func artifactId(_ value: String) throws { try prefixedUUIDv7(value, prefix: "art") }
    static func assertionId(_ value: String) throws { try prefixedUUIDv7(value, prefix: "asrt") }
    static func labelId(_ value: String) throws { try prefixedUUIDv7(value, prefix: "l") }

    static func eventId(_ value: String) throws {
        guard let split = value.lastIndex(of: "-"),
            Int(value[value.index(after: split)...]) != nil
        else { throw JazzArchiveError.invalidIdentifier(kind: "event", id: value) }
        try sessionId(String(value[..<split]))
    }

    static func prefixedUUID(_ value: String, prefix: String) throws {
        let marker = prefix + "-"
        guard value.hasPrefix(marker) else {
            throw JazzArchiveError.invalidIdentifier(kind: prefix, id: value)
        }
        let raw = String(value.dropFirst(marker.count))
        guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw else {
            throw JazzArchiveError.invalidIdentifier(kind: prefix, id: value)
        }
        let chars = Array(raw)
        guard chars.count == 36,
            "12345678".contains(chars[14]),
            "89ab".contains(chars[19])
        else { throw JazzArchiveError.invalidIdentifier(kind: prefix, id: value) }
    }

    static func prefixedUUIDv7(_ value: String, prefix: String) throws {
        try prefixedUUID(value, prefix: prefix)
        let raw = String(value.dropFirst(prefix.count + 1))
        guard Array(raw)[14] == "7" else {
            throw JazzArchiveError.invalidIdentifier(kind: prefix, id: value)
        }
    }

    static func nonempty(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JazzArchiveError.invalidField(field)
        }
    }

    static func token(_ value: String, field: String) throws {
        guard let first = value.first, first.isLowercase,
            value.allSatisfy({ $0.isLowercase || $0.isNumber || "._-".contains($0) })
        else { throw JazzArchiveError.invalidField(field) }
    }

    static func timestamp(_ value: String, field: String) throws {
        guard Timestamps.parse(value) != nil else {
            throw JazzArchiveError.invalidTimestamp(field: field, value: value)
        }
    }

    static func sha256(_ value: String, field: String) throws {
        guard value.count == 64,
            value.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw JazzArchiveError.invalidDigest(field: field, value: value) }
    }

    static func relativePath(_ path: String) throws {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
            !path.hasPrefix("/"),
            path.unicodeScalars.allSatisfy(allowed.contains),
            !components.contains(where: { $0.isEmpty || $0 == ".." })
        else { throw JazzArchiveError.invalidRelativePath(path) }
    }

    static func unique(_ values: [String], kind: String) throws {
        var seen = Set<String>()
        for value in values where !seen.insert(value).inserted {
            throw JazzArchiveError.duplicateIdentifier(kind: kind, id: value)
        }
    }

    static func provenanceSources(
        _ provenance: JazzArchiveProvenance,
        sourceIds: Set<String>
    ) throws {
        for sourceId in provenance.sources where !sourceIds.contains(sourceId) {
            throw JazzArchiveError.missingReference(kind: "provenance source", id: sourceId)
        }
    }
}
