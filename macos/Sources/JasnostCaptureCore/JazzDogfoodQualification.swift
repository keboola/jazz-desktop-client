import Foundation

/// The physical/deployed release profile tracked by jazz-desktop-client issue #4. Case raw values
/// are stable evidence coordinates, not UI copy; changing the checklist requires a new profile
/// version instead of silently changing the meaning of an existing qualification bundle.
public enum JazzDogfoodScenario:
    String, Codable, CaseIterable, Equatable, Hashable, Sendable
{
    case localCompletedDoubleClick = "A01.completed_double_click"
    case localSeparatedSingleClicks = "A02.separated_single_clicks"
    case localCompletedDragSelect = "A03.completed_drag_select"
    case localFocusedCopyCut = "A04.focused_copy_cut"
    case localFocusedPaste = "A05.focused_paste"
    case localSecureDestination = "A06.secure_destination"
    case localActualOwnerDenylist = "A07.actual_owner_denylist"
    case localBrowserDocumentContext = "A08.browser_document_context"
    case localFileContext = "A09.local_file_context"
    case localCapabilityTransitions = "A10.capability_transitions"
    case localStopDuringInflightWork = "A11.stop_during_inflight_work"
    case localOfflineRestart = "A12.offline_restart"

    case coachLabelBaselines = "B01.label_baselines"
    case coachRecordedAnswerSemantics = "B02.recorded_answer_semantics"
    case coachAdvisoryActionsRelaunch = "B03.advisory_actions_relaunch"
    case coachPendingPromptFocusIsolation = "B04.pending_prompt_focus_isolation"
    case coachHungEvaluatorStopIsolation = "B05.hung_evaluator_stop_isolation"

    case deliveryReject = "C01.reject_never_queues"
    case deliveryConfirmExactBytes = "C02.confirm_exact_bytes"
    case deliveryRetryRelaunchExactBytes = "C03.retry_relaunch_exact_bytes"
    case deliveryExpiredOfflineCredential = "C04.expired_offline_credential"
    case enrollmentSignedBundle = "C05.signed_enrollment"
    case enrollmentSingleUseRace = "C06.single_use_enrollment_race"
    case enrollmentRotationQueuedDelivery = "C07.rotation_during_queued_delivery"

    case deployedDirectUploadReady = "D01.direct_upload_ready"
    case deployedAuthorizedDownloadImport = "D02.authorized_download_import"
    case deployedEvidenceReplay = "D03.evidence_replay"
    case deployedGuidedExecution = "D04.guided_execution"
    case deployedExpiredPreparedRefresh = "D05.expired_prepared_refresh"
    case deployedProcessExecutionHandoff = "D06.process_execution_handoff"

    case liveParity = "E01.live_archive_parity"
    case liveMismatchDetection = "E02.live_mismatch_detection"
    case liveArchiveAuthority = "E03.archive_authority"
    case liveDisabledCompleteness = "E04.live_disabled_completeness"

    /// Frozen evidence policy for the 33 coordinates in
    /// `jazz-desktop-client.issue-4.v1`. Keeping this separate from the current profile prevents a
    /// future evidence-policy revision from silently reinterpreting an exported v1 bundle.
    fileprivate var legacyProfileV1RequiredEvidenceKinds:
        [JazzDogfoodEvidenceKind]?
    {
        switch self {
        case .localCompletedDoubleClick,
            .localSeparatedSingleClicks,
            .localCompletedDragSelect,
            .localFocusedCopyCut,
            .localFocusedPaste,
            .localSecureDestination,
            .localActualOwnerDenylist,
            .localBrowserDocumentContext,
            .localFileContext,
            .localStopDuringInflightWork:
            return [.archiveSummary, .captureObservationSummary]
        case .localCapabilityTransitions:
            return [.archiveSummary, .capabilityTransitionSummary]
        case .localOfflineRestart:
            return [.archiveSummary, .playbackSummary]
        case .coachLabelBaselines,
            .coachRecordedAnswerSemantics,
            .coachAdvisoryActionsRelaunch:
            return [.archiveSummary, .coachInteractionSummary]
        case .coachPendingPromptFocusIsolation:
            return [
                .archiveSummary,
                .coachInteractionSummary,
                .operatorAttestationSummary,
            ]
        case .coachHungEvaluatorStopIsolation:
            return nil
        case .deliveryReject:
            return [.archiveSummary, .deliveryReceiptSummary]
        case .deliveryConfirmExactBytes,
            .deliveryRetryRelaunchExactBytes,
            .deliveryExpiredOfflineCredential:
            return [.archiveSummary, .deliveryReceiptSummary]
        case .enrollmentSignedBundle:
            return [.buildAttestationSummary, .enrollmentReceiptSummary]
        case .enrollmentSingleUseRace:
            return [.enrollmentReceiptSummary, .serverStateReceiptSummary]
        case .enrollmentRotationQueuedDelivery:
            return [
                .archiveSummary,
                .deliveryReceiptSummary,
                .enrollmentReceiptSummary,
            ]
        case .deployedDirectUploadReady:
            return [
                .archiveSummary,
                .deliveryReceiptSummary,
                .serverStateReceiptSummary,
            ]
        case .deployedAuthorizedDownloadImport:
            return [
                .archiveSummary,
                .deliveryReceiptSummary,
                .importReceiptSummary,
                .serverStateReceiptSummary,
            ]
        case .deployedEvidenceReplay:
            return [
                .archiveSummary,
                .importReceiptSummary,
                .playbackSummary,
            ]
        case .deployedGuidedExecution:
            return [
                .archiveSummary,
                .executionReceiptSummary,
                .serverStateReceiptSummary,
            ]
        case .deployedExpiredPreparedRefresh:
            return [.executionReceiptSummary, .serverStateReceiptSummary]
        case .deployedProcessExecutionHandoff:
            return [
                .executionReceiptSummary,
                .operatorAttestationSummary,
                .serverStateReceiptSummary,
            ]
        case .liveParity:
            return [.archiveSummary, .liveParitySummary]
        case .liveMismatchDetection:
            return [.liveParitySummary, .serverStateReceiptSummary]
        case .liveArchiveAuthority:
            return [
                .archiveSummary,
                .liveParitySummary,
                .serverStateReceiptSummary,
            ]
        case .liveDisabledCompleteness:
            return [.archiveSummary, .liveParitySummary, .playbackSummary]
        }
    }

    /// Closed evidence policy for `jazz-desktop-client.issue-4.v2`. The 33 shared coordinates
    /// deliberately retain their byte-for-byte v1 policy; B05 is new in v2. Any later change to a
    /// coordinate or its required evidence kinds requires another profile definition.
    public var requiredEvidenceKinds: [JazzDogfoodEvidenceKind] {
        if let legacyKinds = legacyProfileV1RequiredEvidenceKinds {
            return legacyKinds
        }
        precondition(self == .coachHungEvaluatorStopIsolation)
        return [
            // Together these receipts index the retained archive, Coach journal, suspended GET,
            // late-response rejection, and the operator's real-Mac Stop/focus observation. Their
            // semantics are reviewed externally; structural bundle validation does not infer the
            // physical behavior from generic receipt names.
            .archiveSummary,
            .coachInteractionSummary,
            .coachTransportSummary,
            .operatorAttestationSummary,
        ]
    }
}

public enum JazzDogfoodScenarioOutcome: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case blocked
    case notRun = "not_run"
}

public enum JazzDogfoodOverallOutcome: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case blocked
}

/// Evidence classes intentionally contain no screenshots, narration, clipboard contents, URLs,
/// filenames, user-entered labels, logs, server response bodies, or credentials. The bundle keeps
/// only hashes and bounded numeric/boolean measurements of sanitized evidence retained elsewhere.
public enum JazzDogfoodEvidenceKind:
    String, Codable, Equatable, Hashable, Sendable
{
    case archiveSummary = "archive_summary"
    case captureObservationSummary = "capture_observation_summary"
    case capabilityTransitionSummary = "capability_transition_summary"
    case coachInteractionSummary = "coach_interaction_summary"
    case coachTransportSummary = "coach_transport_summary"
    case deliveryReceiptSummary = "delivery_receipt_summary"
    case enrollmentReceiptSummary = "enrollment_receipt_summary"
    case serverStateReceiptSummary = "server_state_receipt_summary"
    case importReceiptSummary = "import_receipt_summary"
    case playbackSummary = "playback_summary"
    case executionReceiptSummary = "execution_receipt_summary"
    case liveParitySummary = "live_parity_summary"
    case operatorAttestationSummary = "operator_attestation_summary"
    case buildAttestationSummary = "build_attestation_summary"
}

public enum JazzDogfoodEvidenceValue: Codable, Equatable, Sendable {
    case boolean(Bool)
    case integer(Int64)
    case sha256(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case boolean
        case integer
        case sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .sha256:
            self = .sha256(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .boolean(let value):
            try container.encode(ValueType.boolean, forKey: .type)
            try container.encode(value, forKey: .value)
        case .integer(let value):
            try container.encode(ValueType.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case .sha256(let value):
            try container.encode(ValueType.sha256, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    fileprivate func validate(field: String) throws {
        switch self {
        case .boolean:
            break
        case .integer(let value):
            guard JazzDogfoodQualificationValidation.isSafeJSONInteger(value) else {
                throw JazzDogfoodQualificationError.invalidField(field)
            }
        case .sha256(let value):
            try JazzDogfoodQualificationValidation.sha256(value, field: field)
        }
    }
}

public struct JazzDogfoodEvidenceMeasurement: Codable, Equatable, Sendable {
    public let name: String
    public let value: JazzDogfoodEvidenceValue

    public init(name: String, value: JazzDogfoodEvidenceValue) {
        self.name = name
        self.value = value
    }

    fileprivate func validate() throws {
        try JazzDogfoodQualificationValidation.token(
            name, field: "evidence.measurement.name", maximumBytes: 96)
        try value.validate(field: "evidence.measurement.value")
    }
}

private struct JazzDogfoodEvidenceDigestMaterial: Codable {
    let scenario: JazzDogfoodScenario
    let kind: JazzDogfoodEvidenceKind
    let sourceSHA256: String
    let sourceByteLength: Int64
    let capturedAt: String
    let measurements: [JazzDogfoodEvidenceMeasurement]
}

/// A content-addressed receipt over one already-sanitized evidence source. `evidenceId` is derived
/// from every field, so a relaunch cannot accidentally attach measurements to different source
/// bytes under the same identity.
public struct JazzDogfoodEvidenceReceipt: Codable, Equatable, Sendable {
    public let evidenceId: String
    public let scenario: JazzDogfoodScenario
    public let kind: JazzDogfoodEvidenceKind
    public let sourceSHA256: String
    public let sourceByteLength: Int64
    public let capturedAt: String
    public let measurements: [JazzDogfoodEvidenceMeasurement]

    public init(
        scenario: JazzDogfoodScenario,
        kind: JazzDogfoodEvidenceKind,
        sourceSHA256: String,
        sourceByteLength: Int64,
        capturedAt: String,
        measurements: [JazzDogfoodEvidenceMeasurement]
    ) throws {
        let canonicalMeasurements = measurements.sorted { $0.name < $1.name }
        self.evidenceId = try Self.makeEvidenceId(
            scenario: scenario,
            kind: kind,
            sourceSHA256: sourceSHA256,
            sourceByteLength: sourceByteLength,
            capturedAt: capturedAt,
            measurements: canonicalMeasurements)
        self.scenario = scenario
        self.kind = kind
        self.sourceSHA256 = sourceSHA256
        self.sourceByteLength = sourceByteLength
        self.capturedAt = capturedAt
        self.measurements = canonicalMeasurements
        try validate()
    }

    fileprivate func canonicalized() -> Self {
        Self(
            uncheckedEvidenceId: evidenceId,
            scenario: scenario,
            kind: kind,
            sourceSHA256: sourceSHA256,
            sourceByteLength: sourceByteLength,
            capturedAt: capturedAt,
            measurements: measurements.sorted { $0.name < $1.name })
    }

    fileprivate func validate() throws {
        try JazzDogfoodQualificationValidation.sha256(
            sourceSHA256, field: "evidence.sourceSHA256")
        guard sourceByteLength > 0,
            JazzDogfoodQualificationValidation.isSafeJSONInteger(sourceByteLength)
        else {
            throw JazzDogfoodQualificationError.invalidField(
                "evidence.sourceByteLength")
        }
        try JazzDogfoodQualificationValidation.timestamp(
            capturedAt, field: "evidence.capturedAt")
        guard measurements.count <= JazzDogfoodQualificationLimits.maxMeasurementsPerEvidence
        else {
            throw JazzDogfoodQualificationError.limitExceeded(
                "measurements per evidence")
        }
        for measurement in measurements {
            try measurement.validate()
        }
        guard Set(measurements.map(\.name)).count == measurements.count else {
            throw JazzDogfoodQualificationError.duplicate("evidence measurement")
        }
        let expected = try Self.makeEvidenceId(
            scenario: scenario,
            kind: kind,
            sourceSHA256: sourceSHA256,
            sourceByteLength: sourceByteLength,
            capturedAt: capturedAt,
            measurements: measurements.sorted { $0.name < $1.name })
        guard evidenceId == expected else {
            throw JazzDogfoodQualificationError.invalidField(
                "evidence.evidenceId")
        }
    }

    private init(
        uncheckedEvidenceId: String,
        scenario: JazzDogfoodScenario,
        kind: JazzDogfoodEvidenceKind,
        sourceSHA256: String,
        sourceByteLength: Int64,
        capturedAt: String,
        measurements: [JazzDogfoodEvidenceMeasurement]
    ) {
        self.evidenceId = uncheckedEvidenceId
        self.scenario = scenario
        self.kind = kind
        self.sourceSHA256 = sourceSHA256
        self.sourceByteLength = sourceByteLength
        self.capturedAt = capturedAt
        self.measurements = measurements
    }

    private static func makeEvidenceId(
        scenario: JazzDogfoodScenario,
        kind: JazzDogfoodEvidenceKind,
        sourceSHA256: String,
        sourceByteLength: Int64,
        capturedAt: String,
        measurements: [JazzDogfoodEvidenceMeasurement]
    ) throws -> String {
        let material = JazzDogfoodEvidenceDigestMaterial(
            scenario: scenario,
            kind: kind,
            sourceSHA256: sourceSHA256,
            sourceByteLength: sourceByteLength,
            capturedAt: capturedAt,
            measurements: measurements)
        let digest = JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(material))
        return "dqe-sha256-\(digest)"
    }
}

public struct JazzDogfoodProviderVersion: Codable, Equatable, Sendable {
    public let provider: String
    public let version: String

    public init(provider: String, version: String) {
        self.provider = provider
        self.version = version
    }

    fileprivate func validate() throws {
        try JazzDogfoodQualificationValidation.token(
            provider, field: "environment.provider", maximumBytes: 64)
        try JazzDogfoodQualificationValidation.technicalToken(
            version, field: "environment.provider.version", maximumBytes: 128)
    }
}

/// Operator/device identity fields are hashes of stable organization-scoped identifiers. Human
/// names, e-mail addresses, serial numbers, certificate subjects, and signing output never enter
/// this shareable qualification document.
public struct JazzDogfoodQualificationEnvironment: Codable, Equatable, Sendable {
    public let desktopCommit: String
    public let serverCommit: String
    public let appBundleId: String
    public let appVersion: String
    public let appBuild: String
    public let codeIdentitySHA256: String
    public let serverBuildIdentitySHA256: String
    public let macOSVersion: String
    public let deviceIdentitySHA256s: [String]
    public let operatorIdentitySHA256s: [String]
    public let providers: [JazzDogfoodProviderVersion]

    public init(
        desktopCommit: String,
        serverCommit: String,
        appBundleId: String,
        appVersion: String,
        appBuild: String,
        codeIdentitySHA256: String,
        serverBuildIdentitySHA256: String,
        macOSVersion: String,
        deviceIdentitySHA256s: [String],
        operatorIdentitySHA256s: [String],
        providers: [JazzDogfoodProviderVersion]
    ) {
        self.desktopCommit = desktopCommit
        self.serverCommit = serverCommit
        self.appBundleId = appBundleId
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.codeIdentitySHA256 = codeIdentitySHA256
        self.serverBuildIdentitySHA256 = serverBuildIdentitySHA256
        self.macOSVersion = macOSVersion
        self.deviceIdentitySHA256s = deviceIdentitySHA256s
        self.operatorIdentitySHA256s = operatorIdentitySHA256s
        self.providers = providers
    }

    fileprivate func canonicalized() -> Self {
        Self(
            desktopCommit: desktopCommit,
            serverCommit: serverCommit,
            appBundleId: appBundleId,
            appVersion: appVersion,
            appBuild: appBuild,
            codeIdentitySHA256: codeIdentitySHA256,
            serverBuildIdentitySHA256: serverBuildIdentitySHA256,
            macOSVersion: macOSVersion,
            deviceIdentitySHA256s: deviceIdentitySHA256s.sorted(),
            operatorIdentitySHA256s: operatorIdentitySHA256s.sorted(),
            providers: providers.sorted {
                $0.provider == $1.provider
                    ? $0.version < $1.version
                    : $0.provider < $1.provider
            })
    }

    fileprivate func validate() throws {
        try JazzDogfoodQualificationValidation.gitRevision(
            desktopCommit, field: "environment.desktopCommit")
        try JazzDogfoodQualificationValidation.gitRevision(
            serverCommit, field: "environment.serverCommit")
        try JazzDogfoodQualificationValidation.bundleId(appBundleId)
        try JazzDogfoodQualificationValidation.technicalToken(
            appVersion, field: "environment.appVersion", maximumBytes: 128)
        try JazzDogfoodQualificationValidation.technicalToken(
            appBuild, field: "environment.appBuild", maximumBytes: 128)
        try JazzDogfoodQualificationValidation.sha256(
            codeIdentitySHA256, field: "environment.codeIdentitySHA256")
        try JazzDogfoodQualificationValidation.sha256(
            serverBuildIdentitySHA256,
            field: "environment.serverBuildIdentitySHA256")
        try JazzDogfoodQualificationValidation.technicalToken(
            macOSVersion, field: "environment.macOSVersion", maximumBytes: 128)
        guard !deviceIdentitySHA256s.isEmpty,
            deviceIdentitySHA256s.count
                <= JazzDogfoodQualificationLimits.maxDevices
        else {
            throw JazzDogfoodQualificationError.invalidField(
                "environment.deviceIdentitySHA256s")
        }
        for identity in deviceIdentitySHA256s {
            try JazzDogfoodQualificationValidation.sha256(
                identity, field: "environment.deviceIdentitySHA256")
        }
        guard Set(deviceIdentitySHA256s).count == deviceIdentitySHA256s.count
        else {
            throw JazzDogfoodQualificationError.duplicate("device identity")
        }
        guard !operatorIdentitySHA256s.isEmpty,
            operatorIdentitySHA256s.count
                <= JazzDogfoodQualificationLimits.maxOperators
        else {
            throw JazzDogfoodQualificationError.invalidField(
                "environment.operatorIdentitySHA256s")
        }
        for identity in operatorIdentitySHA256s {
            try JazzDogfoodQualificationValidation.sha256(
                identity, field: "environment.operatorIdentitySHA256")
        }
        guard Set(operatorIdentitySHA256s).count == operatorIdentitySHA256s.count
        else {
            throw JazzDogfoodQualificationError.duplicate("operator identity")
        }
        guard providers.count <= JazzDogfoodQualificationLimits.maxProviders else {
            throw JazzDogfoodQualificationError.limitExceeded("providers")
        }
        for provider in providers { try provider.validate() }
        guard Set(providers.map(\.provider)).count == providers.count else {
            throw JazzDogfoodQualificationError.duplicate("provider")
        }
    }
}

public struct JazzDogfoodArchiveAnchor: Codable, Equatable, Sendable {
    public let archiveId: String
    public let contentDigest: String
    public let packageSHA256: String
    public let packageByteLength: Int64

    public init(
        archiveId: String,
        contentDigest: String,
        packageSHA256: String,
        packageByteLength: Int64
    ) {
        self.archiveId = archiveId
        self.contentDigest = contentDigest
        self.packageSHA256 = packageSHA256
        self.packageByteLength = packageByteLength
    }

    fileprivate func validate() throws {
        try JazzDogfoodQualificationValidation.prefixedUUIDv7(
            archiveId, prefix: "ar", field: "archive.archiveId")
        try JazzDogfoodQualificationValidation.sha256(
            contentDigest, field: "archive.contentDigest")
        try JazzDogfoodQualificationValidation.sha256(
            packageSHA256, field: "archive.packageSHA256")
        guard packageByteLength > 0,
            JazzDogfoodQualificationValidation.isSafeJSONInteger(packageByteLength)
        else {
            throw JazzDogfoodQualificationError.invalidField(
                "archive.packageByteLength")
        }
    }
}

public struct JazzDogfoodScenarioResult: Codable, Equatable, Sendable {
    public let scenario: JazzDogfoodScenario
    public let outcome: JazzDogfoodScenarioOutcome
    public let evidenceIds: [String]

    public init(
        scenario: JazzDogfoodScenario,
        outcome: JazzDogfoodScenarioOutcome,
        evidenceIds: [String] = []
    ) {
        self.scenario = scenario
        self.outcome = outcome
        self.evidenceIds = evidenceIds
    }

    fileprivate func canonicalized() -> Self {
        Self(
            scenario: scenario,
            outcome: outcome,
            evidenceIds: evidenceIds.sorted())
    }

    fileprivate func validate() throws {
        guard evidenceIds.count <= JazzDogfoodQualificationLimits.maxEvidencePerScenario
        else {
            throw JazzDogfoodQualificationError.limitExceeded(
                "evidence per scenario")
        }
        guard Set(evidenceIds).count == evidenceIds.count else {
            throw JazzDogfoodQualificationError.duplicate(
                "scenario evidence")
        }
        for evidenceId in evidenceIds {
            try JazzDogfoodQualificationValidation.contentAddressedId(
                evidenceId, prefix: "dqe-sha256",
                field: "result.evidenceId")
        }
        switch outcome {
        case .passed, .failed:
            guard !evidenceIds.isEmpty else {
                throw JazzDogfoodQualificationError.missingEvidence(
                    scenario.rawValue)
            }
        case .notRun:
            guard evidenceIds.isEmpty else {
                throw JazzDogfoodQualificationError.invalidField(
                    "not-run result evidence")
            }
        case .blocked:
            break
        }
    }
}

/// Deterministic, privacy-safe evidence index for one full release-gate profile. It is explicitly
/// non-canonical: hashes point at Jazz Archives and sanitized receipts, but this document never
/// becomes capture truth and never changes archive identity, bytes, or delivery state.
public struct JazzDogfoodQualificationBundle: Codable, Equatable, Sendable {
    public static let expectedFormat = "dev.jazz.dogfood-qualification"
    public static let currentFormatVersion = 1
    public static let legacyProfileV1 = "jazz-desktop-client.issue-4.v1"
    public static let currentProfile = "jazz-desktop-client.issue-4.v2"
    public static let currentPrivacyProfile = "technical-facts-only.v1"

    public let format: String
    public let formatVersion: Int
    public let profile: String
    public let privacyProfile: String
    public let qualificationRunId: String
    public let startedAt: String
    public let completedAt: String
    public let overallOutcome: JazzDogfoodOverallOutcome
    public let environment: JazzDogfoodQualificationEnvironment
    public let archives: [JazzDogfoodArchiveAnchor]
    public let evidence: [JazzDogfoodEvidenceReceipt]
    public let results: [JazzDogfoodScenarioResult]

    public init(
        qualificationRunId: String = JazzDogfoodQualificationBundle.newRunId(),
        startedAt: String,
        completedAt: String,
        environment: JazzDogfoodQualificationEnvironment,
        archives: [JazzDogfoodArchiveAnchor],
        evidence: [JazzDogfoodEvidenceReceipt],
        results: [JazzDogfoodScenarioResult]
    ) {
        self.format = Self.expectedFormat
        self.formatVersion = Self.currentFormatVersion
        self.profile = Self.currentProfile
        self.privacyProfile = Self.currentPrivacyProfile
        self.qualificationRunId = qualificationRunId
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.overallOutcome = Self.derivedOutcome(
            results,
            expectedScenarios: Self.currentProfileScenarios)
        self.environment = environment
        self.archives = archives
        self.evidence = evidence
        self.results = results
    }

    public static func newRunId() -> String {
        "qrun-\(Identifiers.newUUIDv7().uuidString.lowercased())"
    }

    public func validate() throws {
        try canonicalized().validateCanonical()
    }

    fileprivate func canonicalized() -> Self {
        Self(
            uncheckedFormat: format,
            formatVersion: formatVersion,
            profile: profile,
            privacyProfile: privacyProfile,
            qualificationRunId: qualificationRunId,
            startedAt: startedAt,
            completedAt: completedAt,
            overallOutcome: overallOutcome,
            environment: environment.canonicalized(),
            archives: archives.sorted { $0.archiveId < $1.archiveId },
            evidence: evidence.map { $0.canonicalized() }.sorted {
                $0.evidenceId < $1.evidenceId
            },
            results: results.map { $0.canonicalized() }.sorted {
                $0.scenario.rawValue < $1.scenario.rawValue
            })
    }

    private init(
        uncheckedFormat: String,
        formatVersion: Int,
        profile: String,
        privacyProfile: String,
        qualificationRunId: String,
        startedAt: String,
        completedAt: String,
        overallOutcome: JazzDogfoodOverallOutcome,
        environment: JazzDogfoodQualificationEnvironment,
        archives: [JazzDogfoodArchiveAnchor],
        evidence: [JazzDogfoodEvidenceReceipt],
        results: [JazzDogfoodScenarioResult]
    ) {
        self.format = uncheckedFormat
        self.formatVersion = formatVersion
        self.profile = profile
        self.privacyProfile = privacyProfile
        self.qualificationRunId = qualificationRunId
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.overallOutcome = overallOutcome
        self.environment = environment
        self.archives = archives
        self.evidence = evidence
        self.results = results
    }

    fileprivate func validateCanonical() throws {
        guard format == Self.expectedFormat,
            formatVersion == Self.currentFormatVersion,
            privacyProfile == Self.currentPrivacyProfile
        else {
            throw JazzDogfoodQualificationError.invalidField(
                "qualification contract")
        }
        guard let expectedScenarios = Self.scenarios(for: profile) else {
            throw JazzDogfoodQualificationError.invalidField(
                "qualification profile")
        }
        try JazzDogfoodQualificationValidation.prefixedUUIDv7(
            qualificationRunId, prefix: "qrun",
            field: "qualificationRunId")
        try JazzDogfoodQualificationValidation.timestamp(
            startedAt, field: "startedAt")
        try JazzDogfoodQualificationValidation.timestamp(
            completedAt, field: "completedAt")
        guard let started = Timestamps.parse(startedAt),
            let completed = Timestamps.parse(completedAt),
            completed >= started
        else {
            throw JazzDogfoodQualificationError.invalidField(
                "qualification interval")
        }
        try environment.validate()

        guard !archives.isEmpty,
            archives.count <= JazzDogfoodQualificationLimits.maxArchives
        else {
            throw JazzDogfoodQualificationError.invalidField("archives")
        }
        for archive in archives { try archive.validate() }
        guard Set(archives.map(\.archiveId)).count == archives.count else {
            throw JazzDogfoodQualificationError.duplicate("archive")
        }

        guard evidence.count <= JazzDogfoodQualificationLimits.maxEvidence else {
            throw JazzDogfoodQualificationError.limitExceeded("evidence")
        }
        guard let allowedEvidenceKinds = Self.allowedEvidenceKinds(
            for: profile)
        else {
            throw JazzDogfoodQualificationError.invalidField(
                "qualification profile")
        }
        for receipt in evidence {
            try receipt.validate()
            guard allowedEvidenceKinds.contains(receipt.kind) else {
                throw JazzDogfoodQualificationError.invalidField(
                    "evidence.kind for qualification profile")
            }
            guard let capturedAt = Timestamps.parse(receipt.capturedAt),
                capturedAt >= started, capturedAt <= completed
            else {
                throw JazzDogfoodQualificationError.invalidField(
                    "evidence.capturedAt outside qualification interval")
            }
        }
        let evidenceIds = Set(evidence.map(\.evidenceId))
        guard evidenceIds.count == evidence.count else {
            throw JazzDogfoodQualificationError.duplicate("evidence")
        }

        guard results.count == expectedScenarios.count,
            Set(results.map(\.scenario)) == Set(expectedScenarios)
        else {
            throw JazzDogfoodQualificationError.incompleteProfile
        }
        for result in results { try result.validate() }
        if results.allSatisfy({
            $0.outcome == .passed || $0.outcome == .failed
        }) {
            guard environment.deviceIdentitySHA256s.count >= 2,
                environment.operatorIdentitySHA256s.count >= 2,
                !environment.providers.isEmpty
            else {
                throw JazzDogfoodQualificationError.invalidField(
                    "terminal profile environment coverage")
            }
        }
        let referencedEvidence = Set(results.flatMap(\.evidenceIds))
        guard referencedEvidence.isSubset(of: evidenceIds) else {
            throw JazzDogfoodQualificationError.missingEvidence(
                referencedEvidence.subtracting(evidenceIds).sorted().first
                    ?? "unknown")
        }
        guard evidenceIds == referencedEvidence else {
            throw JazzDogfoodQualificationError.orphanEvidence(
                evidenceIds.subtracting(referencedEvidence).sorted().first
                    ?? "unknown")
        }
        let evidenceById = Dictionary(
            uniqueKeysWithValues: evidence.map { ($0.evidenceId, $0) })
        for result in results {
            guard result.evidenceIds.allSatisfy({
                evidenceById[$0]?.scenario == result.scenario
            }) else {
                throw JazzDogfoodQualificationError.invalidField(
                    "result scenario evidence")
            }
            if result.outcome == .passed || result.outcome == .failed {
                let actualKinds = Set(result.evidenceIds.compactMap {
                    evidenceById[$0]?.kind
                })
                guard
                    let requiredKinds = Self.requiredEvidenceKinds(
                        for: result.scenario,
                        profile: profile)
                else {
                    throw JazzDogfoodQualificationError.incompleteProfile
                }
                let missingKinds = Set(requiredKinds).subtracting(actualKinds)
                if let missing = missingKinds.sorted(by: {
                    $0.rawValue < $1.rawValue
                }).first {
                    throw JazzDogfoodQualificationError.missingEvidenceKind(
                        scenario: result.scenario.rawValue,
                        kind: missing.rawValue)
                }
            }
        }
        guard overallOutcome == Self.derivedOutcome(
            results,
            expectedScenarios: expectedScenarios)
        else {
            throw JazzDogfoodQualificationError.invalidField(
                "overallOutcome")
        }
    }

    private static let currentProfileScenarios: [JazzDogfoodScenario] = [
        .localCompletedDoubleClick,
        .localSeparatedSingleClicks,
        .localCompletedDragSelect,
        .localFocusedCopyCut,
        .localFocusedPaste,
        .localSecureDestination,
        .localActualOwnerDenylist,
        .localBrowserDocumentContext,
        .localFileContext,
        .localCapabilityTransitions,
        .localStopDuringInflightWork,
        .localOfflineRestart,
        .coachLabelBaselines,
        .coachRecordedAnswerSemantics,
        .coachAdvisoryActionsRelaunch,
        .coachPendingPromptFocusIsolation,
        .coachHungEvaluatorStopIsolation,
        .deliveryReject,
        .deliveryConfirmExactBytes,
        .deliveryRetryRelaunchExactBytes,
        .deliveryExpiredOfflineCredential,
        .enrollmentSignedBundle,
        .enrollmentSingleUseRace,
        .enrollmentRotationQueuedDelivery,
        .deployedDirectUploadReady,
        .deployedAuthorizedDownloadImport,
        .deployedEvidenceReplay,
        .deployedGuidedExecution,
        .deployedExpiredPreparedRefresh,
        .deployedProcessExecutionHandoff,
        .liveParity,
        .liveMismatchDetection,
        .liveArchiveAuthority,
        .liveDisabledCompleteness,
    ]

    private static let legacyProfileV1Scenarios: [JazzDogfoodScenario] = [
        .localCompletedDoubleClick,
        .localSeparatedSingleClicks,
        .localCompletedDragSelect,
        .localFocusedCopyCut,
        .localFocusedPaste,
        .localSecureDestination,
        .localActualOwnerDenylist,
        .localBrowserDocumentContext,
        .localFileContext,
        .localCapabilityTransitions,
        .localStopDuringInflightWork,
        .localOfflineRestart,
        .coachLabelBaselines,
        .coachRecordedAnswerSemantics,
        .coachAdvisoryActionsRelaunch,
        .coachPendingPromptFocusIsolation,
        .deliveryReject,
        .deliveryConfirmExactBytes,
        .deliveryRetryRelaunchExactBytes,
        .deliveryExpiredOfflineCredential,
        .enrollmentSignedBundle,
        .enrollmentSingleUseRace,
        .enrollmentRotationQueuedDelivery,
        .deployedDirectUploadReady,
        .deployedAuthorizedDownloadImport,
        .deployedEvidenceReplay,
        .deployedGuidedExecution,
        .deployedExpiredPreparedRefresh,
        .deployedProcessExecutionHandoff,
        .liveParity,
        .liveMismatchDetection,
        .liveArchiveAuthority,
        .liveDisabledCompleteness,
    ]

    private static func scenarios(
        for profile: String
    ) -> [JazzDogfoodScenario]? {
        switch profile {
        case currentProfile:
            return currentProfileScenarios
        case legacyProfileV1:
            return legacyProfileV1Scenarios
        default:
            return nil
        }
    }

    private static func requiredEvidenceKinds(
        for scenario: JazzDogfoodScenario,
        profile: String
    ) -> [JazzDogfoodEvidenceKind]? {
        switch profile {
        case legacyProfileV1:
            return scenario.legacyProfileV1RequiredEvidenceKinds
        case currentProfile:
            return scenario.requiredEvidenceKinds
        default:
            return nil
        }
    }

    // A profile freezes both its scenarios and its complete evidence vocabulary. New enum cases
    // must be opted into a new profile explicitly; otherwise an old bundle could acquire a shape
    // that its original reader could never have decoded.
    private static func allowedEvidenceKinds(
        for profile: String
    ) -> Set<JazzDogfoodEvidenceKind>? {
        let legacyV1: Set<JazzDogfoodEvidenceKind> = [
            .archiveSummary,
            .captureObservationSummary,
            .capabilityTransitionSummary,
            .coachInteractionSummary,
            .deliveryReceiptSummary,
            .enrollmentReceiptSummary,
            .serverStateReceiptSummary,
            .importReceiptSummary,
            .playbackSummary,
            .executionReceiptSummary,
            .liveParitySummary,
            .operatorAttestationSummary,
            .buildAttestationSummary,
        ]
        switch profile {
        case legacyProfileV1:
            return legacyV1
        case currentProfile:
            return legacyV1.union([.coachTransportSummary])
        default:
            return nil
        }
    }

    private static func derivedOutcome(
        _ results: [JazzDogfoodScenarioResult],
        expectedScenarios: [JazzDogfoodScenario]
    ) -> JazzDogfoodOverallOutcome {
        if results.contains(where: { $0.outcome == .failed }) {
            return .failed
        }
        if results.count == expectedScenarios.count,
            Set(results.map(\.scenario)) == Set(expectedScenarios),
            results.allSatisfy({ $0.outcome == .passed })
        {
            return .passed
        }
        return .blocked
    }
}

public struct JazzDogfoodQualificationExport: Equatable, Sendable {
    public let url: URL
    public let fingerprint: JazzArchiveFileFingerprint
    /// The exact checklist contract validated by this export.
    public let profile: String
    /// Historical profiles remain readable, but only the current profile is release-gate input.
    public let currentProfileEligible: Bool
    public let overallOutcome: JazzDogfoodOverallOutcome
}

/// Writes one canonical JSON bundle with an atomic publish and explicit durability barriers.
/// Repeating the same export is idempotent; an existing destination with different bytes is never
/// overwritten.
public struct JazzDogfoodQualificationExporter {
    public static let defaultMaximumBundleBytes = 1024 * 1024

    private let durability: JazzArchiveFilesystemDurability
    private let fileManager: FileManager
    private let maximumBundleBytes: Int

    public init(
        durability: JazzArchiveFilesystemDurability,
        fileManager: FileManager = .default,
        maximumBundleBytes: Int = Self.defaultMaximumBundleBytes
    ) {
        self.durability = durability
        self.fileManager = fileManager
        self.maximumBundleBytes = maximumBundleBytes
    }

    public func encodedBundle(
        _ bundle: JazzDogfoodQualificationBundle
    ) throws -> Data {
        guard maximumBundleBytes > 0 else {
            throw JazzDogfoodQualificationError.invalidField(
                "maximumBundleBytes")
        }
        let canonical = bundle.canonicalized()
        try canonical.validateCanonical()
        let data = try JazzArchiveCanonicalJSON.encode(canonical)
        guard data.count <= maximumBundleBytes else {
            throw JazzDogfoodQualificationError.bundleTooLarge(data.count)
        }
        return data
    }

    public func export(
        _ bundle: JazzDogfoodQualificationBundle,
        to destination: URL
    ) throws -> JazzDogfoodQualificationExport {
        let data = try encodedBundle(bundle)
        let expected = JazzArchiveFileFingerprint(
            sha256: JazzArchiveDigest.sha256Hex(data),
            byteLength: Int64(data.count))
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        try validateParent(parent)
        guard !destination.lastPathComponent.isEmpty,
            destination.lastPathComponent.utf8.count <= 255
        else {
            throw JazzDogfoodQualificationError.unsafeDestination
        }

        if let existing = try matchingExisting(
            destination, expected: expected)
        {
            try durability.synchronizeRegularFile(
                destination, permissions: Int16(0o600))
            try durability.synchronizeDirectory(parent)
            return JazzDogfoodQualificationExport(
                url: destination,
                fingerprint: existing,
                profile: bundle.profile,
                currentProfileEligible:
                    bundle.profile
                    == JazzDogfoodQualificationBundle.currentProfile,
                overallOutcome: bundle.overallOutcome)
        }

        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).qualification-"
                + Identifiers.newUUIDv7().uuidString.lowercased())
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        else {
            throw JazzDogfoodQualificationError.publishFailed
        }
        var keepTemporary = true
        defer {
            if keepTemporary { try? fileManager.removeItem(at: temporary) }
        }

        do {
            let output = try FileHandle(forWritingTo: temporary)
            do {
                try output.write(contentsOf: data)
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            try durability.synchronizeRegularFile(
                temporary, permissions: Int16(0o600))
            do {
                try fileManager.moveItem(at: temporary, to: destination)
                keepTemporary = false
            } catch {
                guard try matchingExisting(
                    destination, expected: expected) != nil
                else {
                    throw JazzDogfoodQualificationError.publishFailed
                }
            }
            try durability.synchronizeRegularFile(
                destination, permissions: Int16(0o600))
            try durability.synchronizeDirectory(parent)
        } catch let error as JazzDogfoodQualificationError {
            throw error
        } catch {
            throw JazzDogfoodQualificationError.publishFailed
        }

        return JazzDogfoodQualificationExport(
            url: destination,
            fingerprint: expected,
            profile: bundle.profile,
            currentProfileEligible:
                bundle.profile == JazzDogfoodQualificationBundle.currentProfile,
            overallOutcome: bundle.overallOutcome)
    }

    private func validateParent(_ parent: URL) throws {
        let values: URLResourceValues
        do {
            values = try parent.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw JazzDogfoodQualificationError.unsafeDestination
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw JazzDogfoodQualificationError.unsafeDestination
        }
    }

    private func matchingExisting(
        _ destination: URL,
        expected: JazzArchiveFileFingerprint
    ) throws -> JazzArchiveFileFingerprint? {
        guard fileManager.fileExists(atPath: destination.path) else {
            return nil
        }
        let values: URLResourceValues
        do {
            values = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw JazzDogfoodQualificationError.unsafeDestination
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw JazzDogfoodQualificationError.unsafeDestination
        }
        let fingerprint: JazzArchiveFileFingerprint
        do {
            fingerprint = try JazzArchiveFileIO.fingerprint(destination)
        } catch {
            throw JazzDogfoodQualificationError.unsafeDestination
        }
        guard fingerprint == expected else {
            throw JazzDogfoodQualificationError.exportConflict
        }
        return fingerprint
    }
}

public enum JazzDogfoodQualificationError:
    Error, Equatable, CustomStringConvertible, Sendable
{
    case invalidField(String)
    case duplicate(String)
    case incompleteProfile
    case missingEvidence(String)
    case missingEvidenceKind(scenario: String, kind: String)
    case orphanEvidence(String)
    case limitExceeded(String)
    case bundleTooLarge(Int)
    case unsafeDestination
    case exportConflict
    case publishFailed

    public var description: String {
        switch self {
        case .invalidField(let field):
            return "Invalid dogfood qualification field: \(field)"
        case .duplicate(let kind):
            return "Duplicate dogfood qualification \(kind)"
        case .incompleteProfile:
            return "Dogfood qualification does not contain the complete scenario profile"
        case .missingEvidence(let scenario):
            return "Dogfood qualification is missing evidence: \(scenario)"
        case .missingEvidenceKind(let scenario, let kind):
            return "Dogfood qualification \(scenario) is missing evidence kind \(kind)"
        case .orphanEvidence(let evidenceId):
            return "Dogfood qualification contains unreferenced evidence: \(evidenceId)"
        case .limitExceeded(let kind):
            return "Dogfood qualification limit exceeded: \(kind)"
        case .bundleTooLarge(let bytes):
            return "Dogfood qualification bundle is too large: \(bytes) bytes"
        case .unsafeDestination:
            return "Dogfood qualification destination is unsafe"
        case .exportConflict:
            return "Dogfood qualification destination contains different bytes"
        case .publishFailed:
            return "Dogfood qualification bundle could not be published"
        }
    }
}

private enum JazzDogfoodQualificationLimits {
    static let maxDevices = 32
    static let maxOperators = 32
    static let maxProviders = 32
    static let maxArchives = 32
    static let maxEvidence = 512
    static let maxEvidencePerScenario = 64
    static let maxMeasurementsPerEvidence = 64
}

private enum JazzDogfoodQualificationValidation {
    private static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    static func isSafeJSONInteger(_ value: Int64) -> Bool {
        value >= -maximumSafeInteger && value <= maximumSafeInteger
    }

    static func sha256(_ value: String, field: String) throws {
        guard value.count == 64,
            value.allSatisfy({ "0123456789abcdef".contains($0) })
        else {
            throw JazzDogfoodQualificationError.invalidField(field)
        }
    }

    static func gitRevision(_ value: String, field: String) throws {
        guard (value.count == 40 || value.count == 64),
            value.allSatisfy({ "0123456789abcdef".contains($0) })
        else {
            throw JazzDogfoodQualificationError.invalidField(field)
        }
    }

    static func timestamp(_ value: String, field: String) throws {
        guard Timestamps.parse(value) != nil, value.utf8.count <= 64 else {
            throw JazzDogfoodQualificationError.invalidField(field)
        }
    }

    static func token(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
            let first = value.first, first.isLowercase || first.isNumber,
            value.allSatisfy({
                $0.isLowercase || $0.isNumber || "._-".contains($0)
            })
        else {
            throw JazzDogfoodQualificationError.invalidField(field)
        }
    }

    static func technicalToken(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws {
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-")
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
            value.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw JazzDogfoodQualificationError.invalidField(field)
        }
    }

    static func bundleId(_ value: String) throws {
        guard value.utf8.count <= 255,
            value.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$"#,
                options: .regularExpression) != nil,
            value.contains(".")
        else {
            throw JazzDogfoodQualificationError.invalidField(
                "environment.appBundleId")
        }
    }

    static func contentAddressedId(
        _ value: String,
        prefix: String,
        field: String
    ) throws {
        let marker = "\(prefix)-"
        guard value.hasPrefix(marker) else {
            throw JazzDogfoodQualificationError.invalidField(field)
        }
        try sha256(String(value.dropFirst(marker.count)), field: field)
    }

    static func prefixedUUIDv7(
        _ value: String,
        prefix: String,
        field: String
    ) throws {
        let marker = "\(prefix)-"
        guard value.hasPrefix(marker) else {
            throw JazzDogfoodQualificationError.invalidField(field)
        }
        let raw = String(value.dropFirst(marker.count))
        guard let uuid = UUID(uuidString: raw),
            uuid.uuidString.lowercased() == raw
        else {
            throw JazzDogfoodQualificationError.invalidField(field)
        }
        let characters = Array(raw)
        guard characters.count == 36,
            characters[14] == "7",
            "89ab".contains(characters[19])
        else {
            throw JazzDogfoodQualificationError.invalidField(field)
        }
    }
}
