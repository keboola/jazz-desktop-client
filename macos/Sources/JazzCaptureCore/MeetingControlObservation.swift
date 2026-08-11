import Foundation

private func meetingControlNonempty(_ value: String, field: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw JazzArchiveError.invalidField(field)
    }
}

private func meetingControlToken(_ value: String, field: String) throws {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty,
        bytes.count <= 512,
        (97...122).contains(bytes[0]),
        bytes.allSatisfy({
            (97...122).contains($0) || (48...57).contains($0)
                || $0 == 46 || $0 == 95 || $0 == 45
        })
    else {
        throw JazzArchiveError.invalidField(field)
    }
}

/// Canonical source-neutral evidence for meeting lifecycle boundaries that do not carry media.
/// These observations make consent, participant presence, screen-share state, and reconnect gaps
/// explicit without pretending that a meeting producer observed native keyboard, pointer, or AX.
public struct JazzMeetingControlObservation: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var controlEventId: String
    public var eventType: JazzMeetingControlEventType
    public var participantAttribution: JazzMediaParticipantAttribution?
    public var participantInstanceId: String?
    public var trackId: String?
    public var consent: JazzMeetingConsentObservation?
    public var connectionEpoch: Int?
    public var resumesEpoch: Int?

    public init(
        schemaVersion: Int = 1,
        controlEventId: String,
        eventType: JazzMeetingControlEventType,
        participantAttribution: JazzMediaParticipantAttribution? = nil,
        participantInstanceId: String? = nil,
        trackId: String? = nil,
        consent: JazzMeetingConsentObservation? = nil,
        connectionEpoch: Int? = nil,
        resumesEpoch: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.controlEventId = controlEventId
        self.eventType = eventType
        self.participantAttribution = participantAttribution
        self.participantInstanceId = participantInstanceId
        self.trackId = trackId
        self.consent = consent
        self.connectionEpoch = connectionEpoch
        self.resumesEpoch = resumesEpoch
    }
}

public enum JazzMeetingControlEventType: String, Codable, Equatable, Sendable {
    case consentGranted = "consent_granted"
    case consentRevoked = "consent_revoked"
    case participantJoined = "participant_joined"
    case participantLeft = "participant_left"
    case screenShareStarted = "screen_share_started"
    case screenShareStopped = "screen_share_stopped"
    case producerConnected = "producer_connected"
    case producerDisconnected = "producer_disconnected"
}

public enum JazzMeetingConsentStatus: String, Codable, Equatable, Sendable {
    case granted
    case revoked
}

public enum JazzMeetingCaptureModality: String, Codable, CaseIterable, Equatable, Sendable {
    case screenShareVideo = "screen_share_video"
    case meetingAudio = "meeting_audio"
    case meetingMetadata = "meeting_metadata"
    case transcript
}

public struct JazzMeetingConsentObservation: Codable, Equatable, Sendable {
    public var status: JazzMeetingConsentStatus
    public var policyVersion: String
    public var modalities: [JazzMeetingCaptureModality]

    public init(
        status: JazzMeetingConsentStatus,
        policyVersion: String,
        modalities: [JazzMeetingCaptureModality]
    ) {
        self.status = status
        self.policyVersion = policyVersion
        self.modalities = modalities
    }

    fileprivate func validate(
        expectedStatus: JazzMeetingConsentStatus,
        recordPrivacy: JazzArchivePrivacy,
        session: JazzArchiveSession
    ) throws {
        guard status == expectedStatus else {
            throw JazzArchiveError.invalidField("meetingControl.consent.status")
        }
        try meetingControlNonempty(
            policyVersion, field: "meetingControl.consent.policyVersion")
        guard policyVersion == recordPrivacy.policyVersion,
            policyVersion == session.capturePolicy.policyVersion
        else {
            throw JazzArchiveError.referenceMismatch(
                field: "meetingControl.consent.policyVersion",
                expected: session.capturePolicy.policyVersion,
                actual: policyVersion)
        }
        guard !modalities.isEmpty,
            modalities == modalities.sorted(by: { $0.rawValue < $1.rawValue }),
            Set(modalities).count == modalities.count
        else {
            throw JazzArchiveError.invalidField("meetingControl.consent.modalities")
        }
        let sessionModalities = Set(session.capturePolicy.modalities.map(\.rawValue))
        guard Set(modalities.map(\.rawValue)).isSubset(of: sessionModalities) else {
            throw JazzArchiveError.invalidField(
                "meetingControl.consent modalities outside capture policy")
        }
    }
}

extension ArchiveRecord where Payload == JazzMeetingControlObservation {
    public static let meetingControlRecordType = "jazz.meeting-control-observation"
    public static let meetingControlPayloadSchema =
        "https://jazz.dev/schema/meeting-control-observation.schema.json"

    public func validate(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws {
        guard recordType == Self.meetingControlRecordType else {
            throw JazzArchiveError.invalidConstant(field: "recordType", value: recordType)
        }
        guard payloadSchema == Self.meetingControlPayloadSchema else {
            throw JazzArchiveError.invalidConstant(field: "payloadSchema", value: payloadSchema)
        }
        try validateEnvelope(manifest: manifest, session: session)
        guard payload.schemaVersion == 1 else {
            throw JazzArchiveError.unsupportedSchemaVersion(
                type: "meeting control observation", version: payload.schemaVersion)
        }
        try meetingControlToken(
            payload.controlEventId, field: "meetingControl.controlEventId")
        guard artifactRefs.isEmpty else {
            throw JazzArchiveError.invalidField("meetingControl.artifactRefs")
        }
        guard interactionContext == nil, legacyCorrelation == nil else {
            throw JazzArchiveError.invalidField("meetingControl desktop-only context")
        }
        guard let monotonicTime else {
            throw JazzArchiveError.invalidField("meetingControl.monotonicTime")
        }
        let sourceIds = Set(sourceRefs.map(\.sourceId))
        guard manifest.sources.contains(where: { source in
            sourceIds.contains(source.sourceId)
                && source.clock?.monotonicClock == monotonicTime.clockId
                && source.clock?.clockDomainId == monotonicTime.clockDomainId
                && source.clock?.bootId == monotonicTime.bootId
                && source.capabilities.contains("meeting.metadata")
        }) else {
            throw JazzArchiveError.missingReference(
                kind: "meeting metadata source clock", id: monotonicTime.clockDomainId)
        }

        switch payload.eventType {
        case .participantJoined, .participantLeft:
            guard let attribution = payload.participantAttribution,
                let participantInstanceId = payload.participantInstanceId,
                payload.trackId == nil,
                payload.consent == nil,
                payload.connectionEpoch == nil,
                payload.resumesEpoch == nil
            else {
                throw JazzArchiveError.invalidField("meetingControl participant event shape")
            }
            try meetingControlToken(
                participantInstanceId, field: "meetingControl.participantInstanceId")
            try attribution.validate(
                manifest: manifest,
                actorRefs: actorRefs,
                field: "meetingControl.participantAttribution")
        case .screenShareStarted, .screenShareStopped:
            guard let trackId = payload.trackId,
                payload.participantAttribution == nil,
                payload.participantInstanceId == nil,
                payload.consent == nil,
                payload.connectionEpoch == nil,
                payload.resumesEpoch == nil
            else {
                throw JazzArchiveError.invalidField("meetingControl screen-share event shape")
            }
            try meetingControlToken(trackId, field: "meetingControl.trackId")
        case .consentGranted, .consentRevoked:
            guard let consent = payload.consent,
                payload.participantAttribution == nil,
                payload.participantInstanceId == nil,
                payload.trackId == nil,
                payload.connectionEpoch == nil,
                payload.resumesEpoch == nil
            else {
                throw JazzArchiveError.invalidField("meetingControl consent event shape")
            }
            try consent.validate(
                expectedStatus: payload.eventType == .consentGranted ? .granted : .revoked,
                recordPrivacy: privacy,
                session: session)
        case .producerConnected, .producerDisconnected:
            guard let epoch = payload.connectionEpoch,
                epoch >= 1,
                payload.participantAttribution == nil,
                payload.participantInstanceId == nil,
                payload.trackId == nil,
                payload.consent == nil
            else {
                throw JazzArchiveError.invalidField("meetingControl producer event shape")
            }
            if payload.eventType == .producerDisconnected {
                guard payload.resumesEpoch == nil else {
                    throw JazzArchiveError.invalidField(
                        "meetingControl producer disconnect resume")
                }
            } else if let resumesEpoch = payload.resumesEpoch {
                guard resumesEpoch < epoch else {
                    throw JazzArchiveError.invalidField(
                        "meetingControl producer reconnect epoch")
                }
            }
        }
    }
}

/// Cross-record lifecycle validation for the one canonical meeting-control stream in a capture.
/// Identity attribution remains separate from the opaque presence ID used to pair joins/leaves.
public enum JazzMeetingControlTimeline {
    public static func validate(records: [JazzArchiveRecord]) throws {
        let controls = try records
            .filter {
                $0.recordType
                    == ArchiveRecord<JazzMeetingControlObservation>.meetingControlRecordType
            }
            .map { try $0.meetingControlObservationRecord() }
        guard !controls.isEmpty else { return }
        guard Set(controls.map(\.streamId)).count == 1 else {
            throw JazzArchiveError.invalidField("meetingControl.timeline.stream")
        }
        let ordered = controls.sorted {
            ($0.streamSequence, $0.observationId) < ($1.streamSequence, $1.observationId)
        }
        guard Set(ordered.map(\.payload.controlEventId)).count == ordered.count else {
            throw JazzArchiveError.invalidField("meetingControl.timeline.controlEventId")
        }

        var consentGranted = false
        var lastConnectionEpoch: Int?
        var connected = false
        var activeParticipants = Set<String>()
        var activeTracks = Set<String>()

        for record in ordered {
            let payload = record.payload
            switch payload.eventType {
            case .consentGranted:
                guard !consentGranted else {
                    throw JazzArchiveError.invalidField("meetingControl.timeline.consent")
                }
                consentGranted = true
            case .consentRevoked:
                guard consentGranted else {
                    throw JazzArchiveError.invalidField("meetingControl.timeline.consent")
                }
                consentGranted = false
            case .producerConnected:
                guard consentGranted, !connected, let epoch = payload.connectionEpoch else {
                    throw JazzArchiveError.invalidField("meetingControl.timeline.connection")
                }
                if let previous = lastConnectionEpoch {
                    guard epoch > previous, payload.resumesEpoch == previous else {
                        throw JazzArchiveError.invalidField(
                            "meetingControl.timeline.connectionEpoch")
                    }
                } else {
                    guard epoch == 1, payload.resumesEpoch == nil else {
                        throw JazzArchiveError.invalidField(
                            "meetingControl.timeline.initialConnection")
                    }
                }
                lastConnectionEpoch = epoch
                connected = true
            case .producerDisconnected:
                guard consentGranted, connected,
                    payload.connectionEpoch == lastConnectionEpoch
                else {
                    throw JazzArchiveError.invalidField("meetingControl.timeline.disconnect")
                }
                connected = false
            case .participantJoined:
                guard consentGranted, connected,
                    let participant = payload.participantInstanceId,
                    activeParticipants.insert(participant).inserted
                else {
                    throw JazzArchiveError.invalidField("meetingControl.timeline.participantJoin")
                }
            case .participantLeft:
                guard consentGranted, connected,
                    let participant = payload.participantInstanceId,
                    activeParticipants.remove(participant) != nil
                else {
                    throw JazzArchiveError.invalidField("meetingControl.timeline.participantLeave")
                }
            case .screenShareStarted:
                guard consentGranted, connected, let track = payload.trackId,
                    activeTracks.insert(track).inserted
                else {
                    throw JazzArchiveError.invalidField("meetingControl.timeline.shareStart")
                }
            case .screenShareStopped:
                guard consentGranted, connected, let track = payload.trackId,
                    activeTracks.remove(track) != nil
                else {
                    throw JazzArchiveError.invalidField("meetingControl.timeline.shareStop")
                }
            }
        }
        guard lastConnectionEpoch != nil, activeParticipants.isEmpty, activeTracks.isEmpty else {
            throw JazzArchiveError.invalidField("meetingControl.timeline.incomplete")
        }
    }
}

extension JazzArchiveContract {
    public static let meetingControlObservation = JazzArchiveContract(
        recordType: ArchiveRecord<JazzMeetingControlObservation>.meetingControlRecordType,
        schemaId: ArchiveRecord<JazzMeetingControlObservation>.meetingControlPayloadSchema,
        schemaVersion: 1)
}
