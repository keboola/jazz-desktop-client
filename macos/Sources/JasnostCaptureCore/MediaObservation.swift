import Foundation

/// Typed canonical payload for source-neutral screen-share, meeting-audio, and transcript evidence.
/// It deliberately carries no application-specific event or inferred causal relationship.
public struct JazzMediaObservation: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var segmentId: String
    public var trackId: String
    public var mediaKind: JazzMediaKind
    public var artifactId: String
    public var artifactRole: JazzMediaArtifactRole
    public var sourceTime: JazzMediaSourceInterval
    public var attribution: JazzMediaParticipantAttribution
    public var transcript: JazzMediaTranscript?
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        schemaVersion: Int = 1,
        segmentId: String,
        trackId: String,
        mediaKind: JazzMediaKind,
        artifactId: String,
        artifactRole: JazzMediaArtifactRole,
        sourceTime: JazzMediaSourceInterval,
        attribution: JazzMediaParticipantAttribution,
        transcript: JazzMediaTranscript? = nil,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.segmentId = segmentId
        self.trackId = trackId
        self.mediaKind = mediaKind
        self.artifactId = artifactId
        self.artifactRole = artifactRole
        self.sourceTime = sourceTime
        self.attribution = attribution
        self.transcript = transcript
        self.extensions = extensions
    }
}

public enum JazzMediaKind: String, Codable, Equatable, Sendable {
    case screenShareVideo = "screen_share_video"
    case meetingAudio = "meeting_audio"
    case transcript
}

public enum JazzMediaArtifactRole: String, Codable, Equatable, Sendable {
    case screenShareVideo = "screen_share_video"
    case meetingAudio = "meeting_audio"
    case transcript
}

public struct JazzMediaSourceInterval: Codable, Equatable, Sendable {
    public var startTicks: String
    public var endTicks: String
    public var unit: String
    public var clockId: String
    public var clockDomainId: String
    public var bootId: String
    public var uncertaintyMillis: Double

    public init(
        startTicks: String,
        endTicks: String,
        unit: String,
        clockId: String,
        clockDomainId: String,
        bootId: String,
        uncertaintyMillis: Double
    ) {
        self.startTicks = startTicks
        self.endTicks = endTicks
        self.unit = unit
        self.clockId = clockId
        self.clockDomainId = clockDomainId
        self.bootId = bootId
        self.uncertaintyMillis = uncertaintyMillis
    }

    fileprivate func validate() throws {
        guard let start = UInt64(startTicks), let end = UInt64(endTicks), end >= start else {
            throw JazzArchiveError.invalidField("media.sourceTime")
        }
        guard !unit.isEmpty, !clockId.isEmpty, !clockDomainId.isEmpty, !bootId.isEmpty else {
            throw JazzArchiveError.invalidField("media.sourceTime clock domain")
        }
        guard uncertaintyMillis.isFinite, uncertaintyMillis >= 0 else {
            throw JazzArchiveError.invalidNumber(field: "media.sourceTime.uncertaintyMillis")
        }
    }
}

public enum JazzMediaAttributionStatus: String, Codable, Equatable, Sendable {
    case identified
    case anonymous
    case unknown
    case notApplicable = "not_applicable"
}

public enum JazzMediaAttributionMethod: String, Codable, Equatable, Sendable {
    case providerParticipantId = "provider_participant_id"
    case speakerSelfDeclaration = "speaker_self_declaration"
}

public struct JazzMediaParticipantAttribution: Codable, Equatable, Sendable {
    public var status: JazzMediaAttributionStatus
    public var actorId: String?
    public var basis: JazzArchiveActorRefBasis?
    public var method: JazzMediaAttributionMethod?
    public var reason: String?

    public init(
        status: JazzMediaAttributionStatus,
        actorId: String? = nil,
        basis: JazzArchiveActorRefBasis? = nil,
        method: JazzMediaAttributionMethod? = nil,
        reason: String? = nil
    ) {
        self.status = status
        self.actorId = actorId
        self.basis = basis
        self.method = method
        self.reason = reason
    }

    func validate(
        manifest: JazzArchiveManifest,
        actorRefs: [JazzArchiveActorRef],
        field: String
    ) throws {
        let identityRoles = Set(["performer", "participant", "speaker"])
        let identityRefs = actorRefs.filter { identityRoles.contains($0.role) }
        switch status {
        case .identified, .anonymous:
            guard let actorId, let basis, method != nil, reason == nil else {
                throw JazzArchiveError.invalidField(field)
            }
            let expectedStatus: JazzArchiveIdentityStatus =
                status == .identified ? .identified : .anonymous
            guard (method == .providerParticipantId && basis == .observed)
                || (method == .speakerSelfDeclaration && basis == .declared)
            else {
                throw JazzArchiveError.invalidField("\(field) method/basis")
            }
            guard manifest.actors.contains(where: {
                $0.actorId == actorId && $0.identityStatus == expectedStatus
            }) else {
                throw JazzArchiveError.invalidField("\(field) actor identity")
            }
            guard identityRefs.contains(where: { $0.actorId == actorId && $0.basis == basis }) else {
                throw JazzArchiveError.missingReference(
                    kind: "\(field) actor attribution", id: actorId)
            }
        case .unknown, .notApplicable:
            guard actorId == nil, basis == nil, method == nil,
                !(reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw JazzArchiveError.invalidField("\(field) unknown attribution") }
            if status == .unknown {
                let actors = Dictionary(
                    uniqueKeysWithValues: manifest.actors.map { ($0.actorId, $0) })
                guard identityRefs.allSatisfy({
                    actors[$0.actorId]?.identityStatus == .unknown
                }) else {
                    throw JazzArchiveError.invalidField("\(field) unknown attribution was guessed")
                }
            }
        }
    }
}

public struct JazzMediaTranscript: Codable, Equatable, Sendable {
    public var text: String
    public var language: String?
    public var confidence: Double?

    public init(text: String, language: String? = nil, confidence: Double? = nil) {
        self.text = text
        self.language = language
        self.confidence = confidence
    }

    fileprivate func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JazzArchiveError.invalidField("media.transcript.text")
        }
        if let confidence, !confidence.isFinite || !(0...1).contains(confidence) {
            throw JazzArchiveError.invalidNumber(field: "media.transcript.confidence")
        }
    }
}

extension ArchiveRecord where Payload == JazzMediaObservation {
    public static let mediaRecordType = "jazz.media-observation"
    public static let mediaPayloadSchema =
        "https://jasnost.dev/schema/media-observation.schema.json"

    public func validate(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession,
        artifacts: [JazzArchiveArtifact] = []
    ) throws {
        guard recordType == Self.mediaRecordType else {
            throw JazzArchiveError.invalidConstant(field: "recordType", value: recordType)
        }
        guard payloadSchema == Self.mediaPayloadSchema else {
            throw JazzArchiveError.invalidConstant(field: "payloadSchema", value: payloadSchema)
        }
        try validateEnvelope(manifest: manifest, session: session)
        guard payload.schemaVersion == 1 else {
            throw JazzArchiveError.unsupportedSchemaVersion(
                type: "media observation", version: payload.schemaVersion)
        }
        guard !payload.segmentId.isEmpty, !payload.trackId.isEmpty else {
            throw JazzArchiveError.invalidField("media segment/track")
        }
        guard payload.mediaKind.rawValue == payload.artifactRole.rawValue else {
            throw JazzArchiveError.referenceMismatch(
                field: "media.artifactRole",
                expected: payload.mediaKind.rawValue,
                actual: payload.artifactRole.rawValue)
        }
        try payload.sourceTime.validate()
        switch payload.mediaKind {
        case .transcript:
            guard let transcript = payload.transcript else {
                throw JazzArchiveError.invalidField("media.transcript")
            }
            try transcript.validate()
        case .screenShareVideo, .meetingAudio:
            guard payload.transcript == nil else {
                throw JazzArchiveError.invalidField("media.transcript")
            }
        }

        let matchingArtifacts = artifactRefs.filter {
            $0.artifactId == payload.artifactId && $0.role == payload.artifactRole.rawValue
        }
        guard matchingArtifacts.count == 1 else {
            throw JazzArchiveError.referenceMismatch(
                field: "media.artifactRef",
                expected: "\(payload.artifactId):\(payload.artifactRole.rawValue)",
                actual: artifactRefs.map { "\($0.artifactId):\($0.role)" }.joined(separator: ","))
        }
        if !artifacts.isEmpty {
            guard let artifact = artifacts.first(where: { $0.artifactId == payload.artifactId }) else {
                throw JazzArchiveError.missingReference(kind: "artifact", id: payload.artifactId)
            }
            guard artifact.kind == payload.artifactRole.rawValue else {
                throw JazzArchiveError.referenceMismatch(
                    field: "media.artifact.kind",
                    expected: payload.artifactRole.rawValue,
                    actual: artifact.kind)
            }
        }

        guard let monotonicTime else {
            throw JazzArchiveError.invalidField("media monotonicTime")
        }
        let interval = payload.sourceTime
        guard monotonicTime.ticks == interval.startTicks,
            monotonicTime.unit == interval.unit,
            monotonicTime.clockId == interval.clockId,
            monotonicTime.clockDomainId == interval.clockDomainId,
            monotonicTime.bootId == interval.bootId
        else {
            throw JazzArchiveError.invalidField("media envelope/source clock mismatch")
        }
        let sourceIds = Set(sourceRefs.map(\.sourceId))
        guard manifest.sources.contains(where: { source in
            sourceIds.contains(source.sourceId)
                && source.clock?.monotonicClock == interval.clockId
                && source.clock?.clockDomainId == interval.clockDomainId
                && source.clock?.bootId == interval.bootId
        }) else {
            throw JazzArchiveError.missingReference(
                kind: "media source clock", id: interval.clockDomainId)
        }

        try payload.attribution.validate(
            manifest: manifest,
            actorRefs: actorRefs,
            field: "media.attribution")
    }
}
