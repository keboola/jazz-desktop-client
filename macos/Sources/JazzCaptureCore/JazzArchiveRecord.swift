import Foundation

/// Payload-erased archive record used by durable infrastructure that must preserve one ordered
/// stream containing records from more than one declared contract. The JSON payload remains
/// lossless and typed validation is restored for every contract understood by this client.
public typealias JazzArchiveRecord = ArchiveRecord<JazzArchiveJSONValue>

extension ArchiveRecord where Payload == JazzArchiveJSONValue {
    /// Erase only the payload's Swift type. The encoded archive envelope and payload JSON shape are
    /// unchanged, so an existing activity-only journal document remains decodable.
    public init<SourcePayload: Codable & Sendable>(
        erasing record: ArchiveRecord<SourcePayload>
    ) throws {
        let data = try JSONEncoder().encode(record)
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    /// Restore a typed record after checking the envelope discriminator. Callers cannot decode a
    /// coach interaction as an activity event merely because both payloads happen to be JSON.
    public func decoded<DecodedPayload: Codable & Sendable>(
        as type: DecodedPayload.Type,
        recordType expectedRecordType: String,
        payloadSchema expectedPayloadSchema: String
    ) throws -> ArchiveRecord<DecodedPayload> {
        guard recordType == expectedRecordType, payloadSchema == expectedPayloadSchema else {
            throw JazzArchiveError.invalidConstant(field: "recordType", value: recordType)
        }
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(ArchiveRecord<DecodedPayload>.self, from: data)
    }

    public func activityRecord() throws -> ArchiveRecord<ActivityEvent> {
        try decoded(
            as: ActivityEvent.self,
            recordType: ArchiveRecord<ActivityEvent>.activityRecordType,
            payloadSchema: ArchiveRecord<ActivityEvent>.activityPayloadSchema)
    }

    public func coachInteractionRecord() throws -> ArchiveRecord<CaptureCoachInteraction> {
        try decoded(
            as: CaptureCoachInteraction.self,
            recordType: ArchiveRecord<CaptureCoachInteraction>.coachRecordType,
            payloadSchema: ArchiveRecord<CaptureCoachInteraction>.coachPayloadSchema)
    }

    public func mediaObservationRecord() throws -> ArchiveRecord<JazzMediaObservation> {
        try decoded(
            as: JazzMediaObservation.self,
            recordType: ArchiveRecord<JazzMediaObservation>.mediaRecordType,
            payloadSchema: ArchiveRecord<JazzMediaObservation>.mediaPayloadSchema)
    }

    public func meetingControlObservationRecord()
        throws -> ArchiveRecord<JazzMeetingControlObservation>
    {
        try decoded(
            as: JazzMeetingControlObservation.self,
            recordType: ArchiveRecord<JazzMeetingControlObservation>.meetingControlRecordType,
            payloadSchema:
                ArchiveRecord<JazzMeetingControlObservation>.meetingControlPayloadSchema)
    }

    public func captureCapabilityObservationRecord()
        throws -> ArchiveRecord<JazzCaptureCapabilityObservation>
    {
        try decoded(
            as: JazzCaptureCapabilityObservation.self,
            recordType:
                ArchiveRecord<JazzCaptureCapabilityObservation>
                .captureCapabilityRecordType,
            payloadSchema:
                ArchiveRecord<JazzCaptureCapabilityObservation>
                .captureCapabilityPayloadSchema)
    }

    /// Validate the common envelope for future declared contracts and invoke the stronger typed
    /// validator for contracts currently emitted by this client.
    public func validateRecord(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws {
        switch recordType {
        case ArchiveRecord<ActivityEvent>.activityRecordType:
            try activityRecord().validate(manifest: manifest, session: session)
        case ArchiveRecord<CaptureCoachInteraction>.coachRecordType:
            try coachInteractionRecord().validate(manifest: manifest, session: session)
        case ArchiveRecord<JazzMediaObservation>.mediaRecordType:
            try mediaObservationRecord().validate(manifest: manifest, session: session)
        case ArchiveRecord<JazzMeetingControlObservation>.meetingControlRecordType:
            try meetingControlObservationRecord().validate(manifest: manifest, session: session)
        case ArchiveRecord<JazzCaptureCapabilityObservation>.captureCapabilityRecordType:
            try captureCapabilityObservationRecord().validate(
                manifest: manifest,
                session: session)
        default:
            try validateEnvelope(manifest: manifest, session: session)
        }
    }
}
