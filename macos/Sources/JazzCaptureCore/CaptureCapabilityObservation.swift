import Foundation

public enum JazzCaptureCapability:
    String, Codable, CaseIterable, Equatable, Hashable, Sendable
{
    case pointerCapture = "pointer.capture"
    case keyboardCapture = "keyboard.capture"
    case accessibilityContext = "accessibility.context"
    case screenCapture = "screen.capture"
    case audioCapture = "audio.capture"
}

public enum JazzCaptureCapabilityAuthorization: String, Codable, Equatable, Sendable {
    case granted
    case denied
    case notDetermined = "not_determined"
}

public enum JazzCaptureCapabilityAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
}

public enum JazzCaptureCapabilityTransition: String, Codable, Equatable, Sendable {
    case initial
    case granted
    case revoked
    case restored
    case temporarilyDisabled = "temporarily_disabled"
    case sourceFailed = "source_failed"
    case authorizationChanged = "authorization_changed"
}

public enum JazzCaptureCapabilityReason: String, Codable, Equatable, Sendable {
    case permissionGranted = "permission_granted"
    case permissionDenied = "permission_denied"
    case permissionNotDetermined = "permission_not_determined"
    case eventTapTimeout = "event_tap_timeout"
    case eventTapUserInput = "event_tap_user_input"
    case secureInput = "secure_input"
    case sourceFailure = "source_failure"
    case sourceRecovered = "source_recovered"
    case captureDisabledByPolicy = "capture_disabled_by_policy"
}

public struct JazzCaptureCapabilityState: Codable, Equatable, Sendable {
    public var authorization: JazzCaptureCapabilityAuthorization
    public var availability: JazzCaptureCapabilityAvailability

    public init(
        authorization: JazzCaptureCapabilityAuthorization,
        availability: JazzCaptureCapabilityAvailability
    ) {
        self.authorization = authorization
        self.availability = availability
    }

    fileprivate func validate(field: String) throws {
        if authorization != .granted, availability != .unavailable {
            throw JazzArchiveError.invalidField(field)
        }
    }
}

public struct JazzCaptureCapabilitySample: Equatable, Sendable {
    public var capability: JazzCaptureCapability
    public var state: JazzCaptureCapabilityState
    public var reason: JazzCaptureCapabilityReason
    public var detail: String?

    public init(
        capability: JazzCaptureCapability,
        authorization: JazzCaptureCapabilityAuthorization,
        availability: JazzCaptureCapabilityAvailability,
        reason: JazzCaptureCapabilityReason,
        detail: String? = nil
    ) {
        self.capability = capability
        self.state = JazzCaptureCapabilityState(
            authorization: authorization,
            availability: availability)
        self.reason = reason
        self.detail = detail
    }
}

public struct JazzCaptureCapabilityObservation: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var capability: JazzCaptureCapability
    public var authorizationStatus: JazzCaptureCapabilityAuthorization
    public var availability: JazzCaptureCapabilityAvailability
    public var transition: JazzCaptureCapabilityTransition
    public var reason: JazzCaptureCapabilityReason
    public var observedAt: String
    public var previousAuthorization: JazzCaptureCapabilityAuthorization?
    public var previousAvailability: JazzCaptureCapabilityAvailability?
    public var detail: String?

    public init(
        schemaVersion: Int = 1,
        capability: JazzCaptureCapability,
        authorizationStatus: JazzCaptureCapabilityAuthorization,
        availability: JazzCaptureCapabilityAvailability,
        transition: JazzCaptureCapabilityTransition,
        reason: JazzCaptureCapabilityReason,
        observedAt: String,
        previousAuthorization: JazzCaptureCapabilityAuthorization? = nil,
        previousAvailability: JazzCaptureCapabilityAvailability? = nil,
        detail: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.capability = capability
        self.authorizationStatus = authorizationStatus
        self.availability = availability
        self.transition = transition
        self.reason = reason
        self.observedAt = observedAt
        self.previousAuthorization = previousAuthorization
        self.previousAvailability = previousAvailability
        self.detail = detail
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw JazzArchiveError.unsupportedSchemaVersion(
                type: "capture capability observation",
                version: schemaVersion)
        }
        guard Timestamps.parse(observedAt) != nil else {
            throw JazzArchiveError.invalidTimestamp(
                field: "captureCapability.observedAt",
                value: observedAt)
        }
        let state = JazzCaptureCapabilityState(
            authorization: authorizationStatus,
            availability: availability)
        try state.validate(field: "captureCapability.state")
        let hasPrevious = previousAuthorization != nil && previousAvailability != nil
        guard
            (transition == .initial && !hasPrevious)
                || (transition != .initial && hasPrevious)
        else {
            throw JazzArchiveError.invalidField("captureCapability.previousState")
        }
        if let previousAuthorization, let previousAvailability {
            guard
                previousAuthorization != authorizationStatus
                    || previousAvailability != availability
            else {
                throw JazzArchiveError.invalidField(
                    "captureCapability.previousState")
            }
        }
        if let detail {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 512 else {
                throw JazzArchiveError.invalidField("captureCapability.detail")
            }
        }
        switch transition {
        case .initial:
            let valid =
                authorizationStatus == .granted
                    && availability == .available
                    && reason == .permissionGranted
                || authorizationStatus == .granted
                    && availability == .unavailable
                    && (reason == .sourceFailure
                        || reason == .captureDisabledByPolicy)
                || authorizationStatus == .denied
                    && availability == .unavailable
                    && reason == .permissionDenied
                || authorizationStatus == .notDetermined
                    && availability == .unavailable
                    && reason == .permissionNotDetermined
            guard valid else {
                throw JazzArchiveError.invalidField("captureCapability.transition")
            }
        case .granted:
            guard authorizationStatus == .granted,
                availability == .available,
                reason == .permissionGranted
            else {
                throw JazzArchiveError.invalidField("captureCapability.transition")
            }
        case .restored:
            guard authorizationStatus == .granted,
                availability == .available,
                reason == .permissionGranted || reason == .sourceRecovered
            else {
                throw JazzArchiveError.invalidField("captureCapability.transition")
            }
        case .revoked:
            let valid =
                authorizationStatus == .denied
                    && availability == .unavailable
                    && reason == .permissionDenied
                || authorizationStatus == .notDetermined
                    && availability == .unavailable
                    && reason == .permissionNotDetermined
            guard valid else {
                throw JazzArchiveError.invalidField("captureCapability.transition")
            }
        case .temporarilyDisabled:
            guard authorizationStatus == .granted, availability == .unavailable,
                reason == .eventTapTimeout || reason == .eventTapUserInput
                    || reason == .secureInput
            else {
                throw JazzArchiveError.invalidField("captureCapability.transition")
            }
        case .sourceFailed:
            guard authorizationStatus == .granted,
                availability == .unavailable,
                reason == .sourceFailure
            else {
                throw JazzArchiveError.invalidField("captureCapability.transition")
            }
        case .authorizationChanged:
            let valid =
                authorizationStatus == .denied
                    && availability == .unavailable
                    && reason == .permissionDenied
                || authorizationStatus == .notDetermined
                    && availability == .unavailable
                    && reason == .permissionNotDetermined
                || authorizationStatus == .granted
                    && availability == .unavailable
                    && (reason == .sourceFailure
                        || reason == .captureDisabledByPolicy)
            guard valid else {
                throw JazzArchiveError.invalidField("captureCapability.transition")
            }
        }
    }
}

/// Pure, per-capture transition reducer. Repeated permission polls are silent; only a changed
/// authorization/availability state becomes canonical evidence.
public struct JazzCaptureCapabilityStateMachine: Equatable, Sendable {
    private var states: [JazzCaptureCapability: JazzCaptureCapabilityState] = [:]

    public init() {}

    public mutating func reset() {
        states.removeAll(keepingCapacity: false)
    }

    public mutating func observe(
        _ sample: JazzCaptureCapabilitySample,
        at observedAt: String
    ) throws -> JazzCaptureCapabilityObservation? {
        try sample.state.validate(field: "captureCapability.sample")
        let previous = states[sample.capability]
        if previous == sample.state { return nil }

        let transition: JazzCaptureCapabilityTransition
        if let previous {
            if previous.authorization == .granted,
                sample.state.authorization != .granted
            {
                transition = .revoked
            } else if previous.authorization != .granted,
                sample.state.authorization == .granted,
                sample.state.availability == .available
            {
                transition =
                    previous.authorization == .notDetermined ? .granted : .restored
            } else if previous.availability == .available,
                sample.state.availability == .unavailable
            {
                transition =
                    sample.reason == .eventTapTimeout
                        || sample.reason == .eventTapUserInput
                        || sample.reason == .secureInput
                    ? .temporarilyDisabled : .sourceFailed
            } else if previous.availability == .unavailable,
                sample.state.availability == .available
            {
                transition = .restored
            } else {
                transition = .authorizationChanged
            }
        } else {
            transition = .initial
        }

        let observation = JazzCaptureCapabilityObservation(
            capability: sample.capability,
            authorizationStatus: sample.state.authorization,
            availability: sample.state.availability,
            transition: transition,
            reason: sample.reason,
            observedAt: observedAt,
            previousAuthorization: previous?.authorization,
            previousAvailability: previous?.availability,
            detail: sample.detail)
        try observation.validate()
        states[sample.capability] = sample.state
        return observation
    }
}

/// Materializes the archive-level, static source summary from canonical temporal capability
/// evidence. The summary answers "did this source ever supply this evidence during the capture?";
/// temporary/revoked intervals remain exclusively in the typed observations.
public enum JazzCaptureCapabilitySourceSummary {
    public static let qualityReasonPrefix = "capture_capability."

    private struct Evidence {
        var everAvailable = false
        var latest: JazzCaptureCapabilityObservation?
        var latestOrder: (Date, String, Int, String)?
    }

    public static func materialize(
        manifest input: JazzArchiveManifest,
        records: [JazzArchiveRecord]
    ) throws -> JazzArchiveManifest {
        guard input.contracts.contains(where: {
            $0.recordType
                == ArchiveRecord<JazzCaptureCapabilityObservation>
                .captureCapabilityRecordType
        }) else { return input }

        var manifest = input
        let known = Set(JazzCaptureCapability.allCases.map(\.rawValue))
        var evidenceBySource:
            [String: [JazzCaptureCapability: Evidence]] = [:]

        for record in records where
            record.recordType
                == ArchiveRecord<JazzCaptureCapabilityObservation>
                .captureCapabilityRecordType
        {
            let typed = try record.captureCapabilityObservationRecord()
            try typed.payload.validate()
            let monitorSources = Set(
                typed.sourceRefs
                    .filter { $0.role == "capability_monitor" }
                    .map(\.sourceId))
            guard monitorSources.count == 1, let sourceId = monitorSources.first else {
                throw JazzArchiveError.invalidField(
                    "captureCapability.capabilityMonitorSource")
            }
            guard manifest.sources.contains(where: { $0.sourceId == sourceId }) else {
                throw JazzArchiveError.missingReference(kind: "source", id: sourceId)
            }
            guard let observed = Timestamps.parse(typed.payload.observedAt) else {
                throw JazzArchiveError.invalidTimestamp(
                    field: "captureCapability.observedAt",
                    value: typed.payload.observedAt)
            }
            let order = (
                observed,
                typed.streamId,
                typed.streamSequence,
                typed.observationId
            )
            var evidence = evidenceBySource[sourceId]?[typed.payload.capability] ?? Evidence()
            if typed.payload.availability == .available {
                evidence.everAvailable = true
            }
            if evidence.latestOrder.map({ isEarlier($0, than: order) }) ?? true {
                evidence.latest = typed.payload
                evidence.latestOrder = order
            }
            evidenceBySource[sourceId, default: [:]][typed.payload.capability] = evidence
        }

        for index in manifest.sources.indices {
            let source = manifest.sources[index]
            let seededCapabilities = Set(source.capabilities.filter(known.contains))
            let seededUnavailable = Dictionary(
                uniqueKeysWithValues: source.unavailableCapabilities
                    .filter { known.contains($0.capability) }
                    .map { ($0.capability, $0) })
            let observations = evidenceBySource[source.sourceId] ?? [:]
            let candidates =
                seededCapabilities
                .union(seededUnavailable.keys)
                .union(observations.keys.map(\.rawValue))
            guard !candidates.isEmpty else { continue }

            var available = source.capabilities.filter { !known.contains($0) }
            var unavailable = source.unavailableCapabilities.filter {
                !known.contains($0.capability)
            }
            for rawCapability in candidates.sorted() {
                guard let capability = JazzCaptureCapability(rawValue: rawCapability) else {
                    continue
                }
                let evidence = observations[capability]
                let policyDisabled =
                    seededUnavailable[rawCapability]?.reason == .disabledByPolicy
                if evidence?.everAvailable == true {
                    guard !policyDisabled else {
                        throw JazzArchiveError.invalidField(
                            "policy-disabled source capability supplied evidence")
                    }
                    available.append(rawCapability)
                } else if policyDisabled {
                    unavailable.append(
                        seededUnavailable[rawCapability]!)
                } else if let latest = evidence?.latest {
                    unavailable.append(
                        JazzArchiveUnavailableCapability(
                            capability: rawCapability,
                            reason: unavailableReason(latest.reason),
                            detail: latest.detail))
                } else {
                    unavailable.append(
                        seededUnavailable[rawCapability]
                            ?? JazzArchiveUnavailableCapability(
                                capability: rawCapability,
                                reason: .unknown,
                                detail: "no canonical capability observation"))
                }
            }
            manifest.sources[index].capabilities = available.sorted()
            manifest.sources[index].unavailableCapabilities = unavailable.sorted {
                ($0.capability, $0.reason.rawValue, $0.detail ?? "")
                    < ($1.capability, $1.reason.rawValue, $1.detail ?? "")
            }
        }
        try manifest.validate()
        return manifest
    }

    /// Session quality reflects only modalities the frozen capture policy requested. A capability
    /// that supplied evidence at least once keeps the session complete even if typed observations
    /// later record a temporary outage. Policy-disabled capabilities are intentional exclusions.
    public static func materializeQuality(
        session input: JazzArchiveSession,
        manifest: JazzArchiveManifest
    ) -> JazzArchiveQuality {
        let requested = Set(input.capturePolicy.modalities.compactMap {
            capability(for: $0)
        })
        let sources = manifest.sources.filter {
            input.sourceIds.contains($0.sourceId)
        }
        var reasons = input.quality.reasons.filter {
            !$0.hasPrefix(qualityReasonPrefix)
        }
        var capabilityReasons: [String] = []
        for capability in requested.sorted(by: { $0.rawValue < $1.rawValue }) {
            if sources.contains(where: {
                $0.capabilities.contains(capability.rawValue)
            }) {
                continue
            }
            let unavailable = sources.flatMap(\.unavailableCapabilities)
                .filter { $0.capability == capability.rawValue }
            if !unavailable.isEmpty,
                unavailable.allSatisfy({ $0.reason == .disabledByPolicy })
            {
                continue
            }
            let mappedReasons =
                unavailable
                .filter { $0.reason != .disabledByPolicy }
                .map(\.reason)
            let reason = mappedReasons.sorted {
                $0.rawValue < $1.rawValue
            }.first ?? .unknown
            capabilityReasons.append(
                qualityReasonPrefix
                    + capability.rawValue
                    + "."
                    + reason.rawValue)
        }
        reasons.append(contentsOf: capabilityReasons)
        reasons = Array(Set(reasons)).sorted()
        var quality = input.quality
        quality.reasons = reasons
        if !capabilityReasons.isEmpty, quality.status == .complete {
            quality.status = .partial
        }
        return quality
    }

    private static func unavailableReason(
        _ reason: JazzCaptureCapabilityReason
    ) -> JazzArchiveCapabilityUnavailableReason {
        switch reason {
        case .permissionDenied:
            return .permissionDenied
        case .permissionNotDetermined:
            return .notRequested
        case .captureDisabledByPolicy:
            return .disabledByPolicy
        case .eventTapTimeout, .eventTapUserInput, .secureInput, .sourceFailure:
            return .temporarilyUnavailable
        case .permissionGranted, .sourceRecovered:
            return .unknown
        }
    }

    private static func capability(
        for modality: JazzArchiveModality
    ) -> JazzCaptureCapability? {
        switch modality {
        case .pointer: return .pointerCapture
        case .keyboard: return .keyboardCapture
        case .accessibility: return .accessibilityContext
        case .screenshots: return .screenCapture
        case .narration: return .audioCapture
        case .screenShareVideo, .meetingAudio, .meetingMetadata, .transcript,
            .browserDOM:
            return nil
        }
    }

    private static func isEarlier(
        _ left: (Date, String, Int, String),
        than right: (Date, String, Int, String)
    ) -> Bool {
        if left.0 != right.0 { return left.0 < right.0 }
        return (left.1, left.2, left.3) < (right.1, right.2, right.3)
    }
}

extension JazzArchiveContract {
    public static let captureCapabilityObservation = JazzArchiveContract(
        recordType: ArchiveRecord<JazzCaptureCapabilityObservation>
            .captureCapabilityRecordType,
        schemaId: ArchiveRecord<JazzCaptureCapabilityObservation>
            .captureCapabilityPayloadSchema,
        schemaVersion: 1)
}

extension ArchiveRecord where Payload == JazzCaptureCapabilityObservation {
    public static let captureCapabilityRecordType =
        "jazz.capture-capability-observation"
    public static let captureCapabilityPayloadSchema =
        "https://jazz.dev/schema/capture-capability-observation.schema.json"

    public init(
        capabilityObservation: JazzCaptureCapabilityObservation,
        observationId: String = Identifiers.newObservationId(),
        context: CaptureJournalActivityContext,
        streamSequence: Int
    ) {
        self.init(
            observationId: observationId,
            recordType: Self.captureCapabilityRecordType,
            payloadSchema: Self.captureCapabilityPayloadSchema,
            originId: context.originId,
            captureId: context.captureId,
            streamId: context.streamId,
            streamSequence: streamSequence,
            capturedAt: capabilityObservation.observedAt,
            occurredAt: capabilityObservation.observedAt,
            sourceRefs: [
                JazzArchiveSourceRef(
                    sourceId: context.sourceId,
                    role: "capability_monitor")
            ],
            actorRefs: [],
            payload: capabilityObservation,
            provenance: JazzArchiveProvenance(
                factClass: .observed,
                sources: [context.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured,
                policyVersion: context.policyVersion))
    }

    public func validate(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws {
        guard recordType == Self.captureCapabilityRecordType else {
            throw JazzArchiveError.invalidConstant(
                field: "recordType",
                value: recordType)
        }
        guard payloadSchema == Self.captureCapabilityPayloadSchema else {
            throw JazzArchiveError.invalidConstant(
                field: "payloadSchema",
                value: payloadSchema)
        }
        try validateEnvelope(manifest: manifest, session: session)
        try payload.validate()
        guard capturedAt == payload.observedAt,
            occurredAt == nil || occurredAt == payload.observedAt
        else {
            throw JazzArchiveError.referenceMismatch(
                field: "captureCapability.observedAt",
                expected: capturedAt,
                actual: payload.observedAt)
        }
    }
}

/// Appends OS capability transitions through the same durable stream reservation protocol as
/// activity observations. A failed append resolves its reserved coordinate to an explicit gap, so
/// Stop can still reach a complete `CaptureCommit` without silently losing the transition.
public actor CaptureCapabilityJournalWriter {
    private let journal: CaptureJournal
    private let context: CaptureJournalActivityContext
    private let orderedLiveCompatibilityProjection:
        CaptureJournalOrderedProjection?
    private var stateMachine = JazzCaptureCapabilityStateMachine()
    private var stateTransitionInFlight = false

    public init(
        journal: CaptureJournal,
        context: CaptureJournalActivityContext,
        orderedLiveCompatibilityProjection:
            CaptureJournalOrderedProjection? = nil
    ) {
        self.journal = journal
        self.context = context
        self.orderedLiveCompatibilityProjection =
            orderedLiveCompatibilityProjection
    }

    /// Reduces and durably admits one OS sample as a single serialized operation. The reducer's
    /// accepted state advances only after the canonical observation has resolved. A failed reserve
    /// therefore leaves the same sample retryable instead of turning the next poll into silence.
    @discardableResult
    public func observe(
        _ sample: JazzCaptureCapabilitySample,
        at observedAt: String
    ) async throws -> String? {
        guard !stateTransitionInFlight else {
            throw CaptureJournalError.completionInProgress(
                "capture-capability-state")
        }
        var projected = stateMachine
        guard let observation = try projected.observe(sample, at: observedAt)
        else { return nil }
        stateTransitionInFlight = true
        defer { stateTransitionInFlight = false }
        let observationId = try await append(observation)
        stateMachine = projected
        return observationId
    }

    @discardableResult
    public func append(
        _ observation: JazzCaptureCapabilityObservation
    ) async throws -> String {
        try observation.validate()
        let token = try await journal.reserve(streamId: context.streamId)
        let observationId = Identifiers.newObservationId()
        let record = ArchiveRecord(
            capabilityObservation: observation,
            observationId: observationId,
            context: context,
            streamSequence: token.streamSequence)
        do {
            try await journal.resolveObservation(token, record: record)
            if let orderedLiveCompatibilityProjection {
                _ = await orderedLiveCompatibilityProjection.resolveObservation(
                    try JazzArchiveRecord(erasing: record))
            }
            return observationId
        } catch {
            try? await journal.resolveGap(
                token,
                reason: .captureLoss,
                detail: "capability observation persistence failed")
            throw error
        }
    }
}
