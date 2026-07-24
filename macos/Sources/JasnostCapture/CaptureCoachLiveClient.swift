import Foundation
import JasnostCaptureCore

enum CaptureCoachLiveHTTPError: Error, Equatable, CustomStringConvertible {
    case invalidEndpoint
    case scopeMismatch
    case promptLineageMismatch
    case credentialUnavailable
    case retryable(Int)
    case identityCollision
    case unexpectedStatus(Int)
    case responseTooLarge
    case invalidResponse

    var description: String {
        switch self {
        case .invalidEndpoint: "Capture Coach live endpoint is invalid."
        case .scopeMismatch: "Capture Coach live scope differs from signed enrollment."
        case .promptLineageMismatch:
            "Capture Coach live prompt differs from the requested capture or label."
        case .credentialUnavailable: "Capture Coach live credential is unavailable."
        case .retryable(let status): "Capture Coach live request is retryable (HTTP \(status))."
        case .identityCollision: "Capture Coach live id was reused with different bytes."
        case .unexpectedStatus(let status):
            "Capture Coach live server returned HTTP \(status)."
        case .responseTooLarge: "Capture Coach live response exceeded its hard byte limit."
        case .invalidResponse: "Capture Coach live response violated the strict JCS contract."
        }
    }
}

struct CaptureCoachLiveDeliveryStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case retrying
        case suspended
    }

    var state: State
    var detail: String
}

/// Same-origin native adapter for the optional advisory channel. It reads the signed-enrollment
/// credential at request time, sends exact spooled bytes, follows no redirects, and returns only a
/// strict persisted ACK. It never owns capture truth, transcript semantics, or prompt policy.
final class CaptureCoachLiveHTTPClient: @unchecked Sendable {
    private static let maximumAcknowledgementBytes = 16 * 1_024
    private static let maximumPromptBytes = 256 * 1_024

    private let routeBinding: JazzArchiveUploadRouteBinding
    private let root: URL
    private let credentialProvider: any JazzArchiveCredentialProvider
    private let session: JazzCredentialSafeHTTPSession

    init(
        routeBinding: JazzArchiveUploadRouteBinding,
        credentialProvider: any JazzArchiveCredentialProvider,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        guard routeBinding.hasSignedAuthority,
            let root = CaptureCoachLiveEndpoint.derive(
                fromArchiveIngestURL: routeBinding.ingestEndpoint)
        else { throw CaptureCoachLiveHTTPError.invalidEndpoint }
        self.routeBinding = routeBinding
        self.root = root
        self.credentialProvider = credentialProvider
        let configuration = sessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        session = JazzCredentialSafeHTTPSession(configuration: configuration)
    }

    @MainActor
    convenience init(
        routeBinding: JazzArchiveUploadRouteBinding,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        try self.init(
            routeBinding: routeBinding,
            credentialProvider: KeychainArchiveCredentialProvider(),
            sessionConfiguration: sessionConfiguration)
    }

    func sendMessage(
        _ item: CaptureCoachLivePendingItem<CaptureCoachLiveMessage>
    ) async throws -> CaptureCoachLiveMessageAcknowledgement {
        try validateScope(item.document.scope)
        guard try item.document.canonicalData() == item.canonicalData else {
            throw CaptureCoachLiveHTTPError.invalidResponse
        }
        let (data, status) = try await send(
            method: "POST",
            url: root.appendingPathComponent("messages"),
            body: item.canonicalData,
            maximumResponseBytes: Self.maximumAcknowledgementBytes)
        if status == 409 {
            guard data.isEmpty else { throw CaptureCoachLiveHTTPError.invalidResponse }
            throw CaptureCoachLiveHTTPError.identityCollision
        }
        try requireSuccessfulPOST(status)
        let acknowledgement: CaptureCoachLiveMessageAcknowledgement
        do {
            acknowledgement =
                try CaptureCoachLiveMessageAcknowledgement
                .decodeCanonical(data)
        } catch {
            throw CaptureCoachLiveHTTPError.invalidResponse
        }
        guard acknowledgement.messageId == item.document.messageId,
            acknowledgement.contentDigest == item.document.contentDigest
        else { throw CaptureCoachLiveHTTPError.invalidResponse }
        return acknowledgement
    }

    func nextPrompt(
        selector: CaptureCoachLivePromptSelector
    ) async throws -> CaptureCoachLivePrompt? {
        try selector.validate()
        try validateScope(selector.scope)
        let url = try selector.requestURL(
            endpoint: root.appendingPathComponent("prompts/next"))
        let (data, status) = try await send(
            method: "GET",
            url: url,
            body: nil,
            maximumResponseBytes: Self.maximumPromptBytes)
        if status == 204 {
            guard data.isEmpty else { throw CaptureCoachLiveHTTPError.invalidResponse }
            return nil
        }
        guard status == 200 else {
            try throwForStatus(status)
            throw CaptureCoachLiveHTTPError.unexpectedStatus(status)
        }
        let prompt: CaptureCoachLivePrompt
        do {
            prompt = try CaptureCoachLivePrompt.decodeCanonical(data)
        } catch {
            throw CaptureCoachLiveHTTPError.invalidResponse
        }
        guard prompt.scope == selector.scope else {
            throw CaptureCoachLiveHTTPError.scopeMismatch
        }
        guard selector.matches(prompt) else {
            throw CaptureCoachLiveHTTPError.promptLineageMismatch
        }
        return prompt
    }

    func sendReceipt(
        _ item: CaptureCoachLivePendingItem<CaptureCoachLivePromptReceipt>
    ) async throws -> CaptureCoachLiveReceiptAcknowledgement {
        try await sendReceipt(
            data: item.canonicalData,
            expectedData: try item.document.canonicalData(),
            scope: item.document.scope,
            receiptId: item.document.receiptId,
            contentDigest: item.document.contentDigest)
    }

    func sendReceipt(
        _ item: CaptureCoachLivePendingItem<CaptureCoachLiveScopeControlReceipt>
    ) async throws -> CaptureCoachLiveReceiptAcknowledgement {
        try await sendReceipt(
            data: item.canonicalData,
            expectedData: try item.document.canonicalData(),
            scope: item.document.scope,
            receiptId: item.document.receiptId,
            contentDigest: item.document.contentDigest)
    }

    func sendReceipt(
        _ item: CaptureCoachLivePendingItem<CaptureCoachLiveReceiptDocument>
    ) async throws -> CaptureCoachLiveReceiptAcknowledgement {
        let scope: CaptureCoachLiveScope
        switch item.document {
        case .prompt(let value): scope = value.scope
        case .scopeControl(let value): scope = value.scope
        }
        return try await sendReceipt(
            data: item.canonicalData,
            expectedData: try item.document.canonicalData(),
            scope: scope,
            receiptId: item.document.spoolIdentifier,
            contentDigest: item.document.contentDigest)
    }

    func invalidateAndCancel() {
        session.invalidateAndCancel()
    }

    private func sendReceipt(
        data: Data,
        expectedData: Data,
        scope: CaptureCoachLiveScope,
        receiptId: String,
        contentDigest: String
    ) async throws -> CaptureCoachLiveReceiptAcknowledgement {
        try validateScope(scope)
        guard data == expectedData else {
            throw CaptureCoachLiveHTTPError.invalidResponse
        }
        let (responseData, status) = try await send(
            method: "POST",
            url: root.appendingPathComponent("receipts"),
            body: data,
            maximumResponseBytes: Self.maximumAcknowledgementBytes)
        if status == 409 {
            guard responseData.isEmpty else {
                throw CaptureCoachLiveHTTPError.invalidResponse
            }
            throw CaptureCoachLiveHTTPError.identityCollision
        }
        try requireSuccessfulPOST(status)
        let acknowledgement: CaptureCoachLiveReceiptAcknowledgement
        do {
            acknowledgement =
                try CaptureCoachLiveReceiptAcknowledgement
                .decodeCanonical(responseData)
        } catch {
            throw CaptureCoachLiveHTTPError.invalidResponse
        }
        guard acknowledgement.receiptId == receiptId,
            acknowledgement.contentDigest == contentDigest
        else { throw CaptureCoachLiveHTTPError.invalidResponse }
        return acknowledgement
    }

    private func send(
        method: String,
        url: URL,
        body: Data?,
        maximumResponseBytes: Int
    ) async throws -> (Data, Int) {
        let credential: JazzArchiveScopedDeviceCredential
        do {
            credential = try await credentialProvider.credential(
                for: routeBinding)
        } catch {
            throw CaptureCoachLiveHTTPError.credentialUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue(
                "application/json", forHTTPHeaderField: "Content-Type")
        }
        credential.withValue {
            request.setValue($0, forHTTPHeaderField: "X-StorageApi-Token")
        }
        do {
            let (data, response) = try await session.boundedData(
                for: request, maximumResponseBytes: maximumResponseBytes)
            guard let http = response as? HTTPURLResponse else {
                throw CaptureCoachLiveHTTPError.invalidResponse
            }
            return (data, http.statusCode)
        } catch JazzCredentialSafeHTTPSessionError.responseTooLarge {
            throw CaptureCoachLiveHTTPError.responseTooLarge
        } catch let error as CaptureCoachLiveHTTPError {
            throw error
        } catch {
            // No spool acknowledgement follows this error; exact pending bytes survive retry.
            throw CaptureCoachLiveHTTPError.retryable(0)
        }
    }

    private func validateScope(_ scope: CaptureCoachLiveScope) throws {
        try scope.validate()
        guard scope.companyId == routeBinding.scope.companyId,
            scope.areaId == routeBinding.scope.areaId,
            scope.deviceId == routeBinding.scope.deviceId
        else { throw CaptureCoachLiveHTTPError.scopeMismatch }
    }

    private func requireSuccessfulPOST(_ status: Int) throws {
        guard status == 200 else {
            try throwForStatus(status)
            throw CaptureCoachLiveHTTPError.unexpectedStatus(status)
        }
    }

    private func throwForStatus(_ status: Int) throws {
        if status == 401 || status == 403 {
            throw CaptureCoachLiveHTTPError.credentialUnavailable
        }
        if status == 408 || status == 425 || status == 429 || status >= 500 {
            throw CaptureCoachLiveHTTPError.retryable(status)
        }
    }
}

/// Minimal durable delivery loop. It acknowledges a queue item only after the strict server ACK
/// has echoed that exact item; all errors deliberately leave pending bytes untouched.
actor CaptureCoachLiveDeliveryWorker {
    typealias StatusHandler =
        @Sendable (CaptureCoachLiveDeliveryStatus) async -> Void

    private let messages: CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>
    private let receipts: CaptureCoachLiveExactByteSpool<CaptureCoachLiveReceiptDocument>
    private let client: CaptureCoachLiveHTTPClient
    private var statusHandler: StatusHandler?
    private var suspendedDetail: String?
    private var fairness = CaptureCoachLiveDeliveryFairnessGate()
    private var deliveryInFlight = false

    init(
        messages: CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>,
        receipts: CaptureCoachLiveExactByteSpool<CaptureCoachLiveReceiptDocument>,
        client: CaptureCoachLiveHTTPClient
    ) {
        self.messages = messages
        self.receipts = receipts
        self.client = client
    }

    func setStatusHandler(_ handler: StatusHandler?) async {
        statusHandler = handler
        if let suspendedDetail {
            await handler?(
                CaptureCoachLiveDeliveryStatus(
                    state: .suspended, detail: suspendedDetail))
        }
    }

    func isSuspended() -> Bool {
        suspendedDetail != nil
    }

    func reportLocalIntegrityFailure(_ context: String) async {
        await suspend("\(context) failed local integrity checks")
    }

    func reportTransportFailure(_ error: Error, operation: String) async {
        await handle(error, queue: operation)
    }

    func deliverPending() async {
        guard suspendedDetail == nil, !deliveryInFlight else { return }
        deliveryInFlight = true
        defer { deliveryInFlight = false }
        var delivered = 0
        while delivered < 64 {
            guard suspendedDetail == nil else { return }
            let message: CaptureCoachLivePendingItem<CaptureCoachLiveMessage>?
            let receipt: CaptureCoachLivePendingItem<CaptureCoachLiveReceiptDocument>?
            do {
                message = try await messages.pendingItems().first
                receipt = try await receipts.pendingItems().first
            } catch {
                await suspend("local delivery queue failed integrity validation")
                return
            }
            switch fairness.next(
                hasMessage: message != nil, hasReceipt: receipt != nil)
            {
            case .message:
                guard let message else {
                    await suspend("message fairness selected an empty queue")
                    return
                }
                do {
                    let acknowledgement = try await client.sendMessage(message)
                    try await messages.acknowledge(acknowledgement)
                    delivered += 1
                    continue
                } catch {
                    await handle(error, queue: "message")
                    return
                }
            case .receipt:
                guard let receipt else {
                    await suspend("receipt fairness selected an empty queue")
                    return
                }
                do {
                    let acknowledgement = try await client.sendReceipt(receipt)
                    try await receipts.acknowledge(acknowledgement)
                    delivered += 1
                    continue
                } catch {
                    await handle(error, queue: "receipt")
                    return
                }
            case nil:
                await publish(.ready, "delivery queue is drained")
                return
            }
        }
        await publish(.ready, "delivery made bounded progress")
    }

    private func handle(_ error: Error, queue: String) async {
        switch error as? CaptureCoachLiveHTTPError {
        case .credentialUnavailable?, .retryable?:
            await publish(.retrying, "\(queue) delivery is waiting to retry")
        case .identityCollision?:
            await suspend("\(queue) identity collision (HTTP 409)")
        case .invalidEndpoint?, .scopeMismatch?, .promptLineageMismatch?,
            .unexpectedStatus?,
            .responseTooLarge?, .invalidResponse?:
            await suspend("\(queue) delivery failed protocol integrity checks")
        case nil:
            if error is CaptureCoachLiveSpoolError
                || error is CaptureCoachLiveContractError
                || error is JazzArchiveFilesystemDurabilityError
            {
                await suspend("\(queue) durable queue failed integrity checks")
            } else {
                await publish(.retrying, "\(queue) delivery is waiting to retry")
            }
        }
    }

    private func suspend(_ detail: String) async {
        suspendedDetail = detail
        await publish(.suspended, detail)
    }

    private func publish(
        _ state: CaptureCoachLiveDeliveryStatus.State,
        _ detail: String
    ) async {
        await statusHandler?(
            CaptureCoachLiveDeliveryStatus(
                state: state, detail: detail))
    }
}

/// Immutable transport resources for one signed route-authority partition. The active capture and
/// the idle relaunch drainer share these actor instances, avoiding duplicate writers while keeping
/// foreign enrollment partitions durable and out of the current head of line.
final class CaptureCoachLiveTransportPartition: @unchecked Sendable {
    let boundRoute: CaptureCoachLiveBoundRoutePartition
    let scopeAuthority: JazzArchiveUploadScope
    let messages: CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>
    let receipts: CaptureCoachLiveExactByteSpool<CaptureCoachLiveReceiptDocument>
    let client: CaptureCoachLiveHTTPClient
    let worker: CaptureCoachLiveDeliveryWorker

    @MainActor
    init(
        baseRoot: URL,
        routeBinding: JazzArchiveUploadRouteBinding
    ) throws {
        let boundRoute = try CaptureCoachLiveRoutePartition.bind(
            baseRoot: baseRoot,
            routeBinding: routeBinding,
            durability: JazzArchiveFilesystemPlatform.durability)
        let messages = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: boundRoute.root.appendingPathComponent("messages", isDirectory: true),
            globalCollisionRoot:
                baseRoot
                .appendingPathComponent("identity", isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true),
            preserveLegacyAcknowledgedDocumentsForRecovery: true,
            durability: JazzArchiveFilesystemPlatform.durability)
        let receipts = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveReceiptDocument>(
            root: boundRoute.root.appendingPathComponent("receipts", isDirectory: true),
            globalCollisionRoot:
                baseRoot
                .appendingPathComponent("identity", isDirectory: true)
                .appendingPathComponent("receipts", isDirectory: true),
            durability: JazzArchiveFilesystemPlatform.durability)
        let client = try CaptureCoachLiveHTTPClient(routeBinding: routeBinding)
        self.boundRoute = boundRoute
        scopeAuthority = routeBinding.scope
        self.messages = messages
        self.receipts = receipts
        self.client = client
        worker = CaptureCoachLiveDeliveryWorker(
            messages: messages, receipts: receipts, client: client)
    }

    func captureStateRoot(_ captureId: String) -> URL {
        boundRoute.root
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent(captureId, isDirectory: true)
    }
}

/// Starts at application/controller initialization, not capture start. It retries only the current
/// signed authority's exact pending bytes; prompt polling remains owned by an active runtime.
actor CaptureCoachLiveBackgroundDrainer {
    private let worker: CaptureCoachLiveDeliveryWorker
    private var task: Task<Void, Never>?

    init(worker: CaptureCoachLiveDeliveryWorker) {
        self.worker = worker
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.worker.deliverPending()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func nudge() async {
        await worker.deliverPending()
    }
}

actor CaptureCoachLiveObservationRouter {
    private var runtime: CaptureCoachLiveRuntime?

    func install(_ runtime: CaptureCoachLiveRuntime) {
        self.runtime = runtime
    }

    func project(_ record: JazzArchiveRecord, event: ActivityEvent) async {
        await runtime?.projectCanonicalObservation(record, event: event)
    }
}

/// Opt-in per-capture orchestration. It accepts only already-canonical observations, rate-limits
/// advisory messages, drains durable queues independently of capture finalization, polls strict
/// prompts, and projects them through the canonical coordinator before asking the UI to refresh.
actor CaptureCoachLiveRuntime {
    typealias PresentationHandler =
        @Sendable (CaptureCoachPrompt) async -> Bool
    typealias AvailabilityHandler = @Sendable (Bool) async -> Void

    private let scopeAuthority: JazzArchiveUploadScope
    private let captureId: String
    private let producer: CaptureCoachLiveProducer
    private let messageProjector: CaptureCoachLiveMessageProjector
    private let worker: CaptureCoachLiveDeliveryWorker
    private let deliveryNudge: CaptureCoachLiveDetachedDeliveryNudge
    private let client: CaptureCoachLiveHTTPClient
    private let promptProjector: CaptureCoachLivePromptProjector
    private let actionIntentStore: CaptureCoachLiveActionProjectionIntentStore
    private let actionProjector: CaptureCoachLiveActionReceiptProjector
    private let promptIntents: CaptureCoachLiveProjectionIntentStore
    private let onPresentation: PresentationHandler
    private let onAvailability: AvailabilityHandler
    private let liveAudioAvailable: Bool
    private var activeScope: CaptureCoachLiveScope?
    private var activeLabelId: String?
    private var labelContextGeneration: UInt64 = 0
    private var promptPollGate = CaptureCoachLivePromptPollAdmissionGate()
    private var latestWatermarkByLabel: [String: CaptureCoachInputWatermark] = [:]
    private var audioStreams = CaptureCoachLiveLabelAudioStreams()
    private var audioSequencer = CaptureCoachLivePCMSequencer()
    private var livePrompts: [String: CaptureCoachLivePrompt] = [:]
    private var lastMessageAtByLabel: [String: Date] = [:]
    private var pollTask: Task<Void, Never>?
    private var accepting = true

    init(
        transport: CaptureCoachLiveTransportPartition,
        sourceId: String,
        archiveId: String,
        captureId: String,
        liveAudioAvailable: Bool,
        coordinator: CaptureCoachCoordinator,
        onPresentation: @escaping PresentationHandler,
        onAvailability: @escaping AvailabilityHandler
    ) throws {
        scopeAuthority = transport.scopeAuthority
        self.captureId = captureId
        producer = CaptureCoachLiveProducer.nativeDesktopArchiveSource(
            sourceId: sourceId,
            version: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            liveAudioAvailable: liveAudioAvailable)
        let captureRoot = transport.captureStateRoot(captureId)
        let promptIntents = try CaptureCoachLiveProjectionIntentStore(
            root: captureRoot.appendingPathComponent("prompt-intents", isDirectory: true),
            durability: JazzArchiveFilesystemPlatform.durability)
        let actionIntents = try CaptureCoachLiveActionProjectionIntentStore(
            root: captureRoot.appendingPathComponent("action-intents", isDirectory: true),
            recoveryBinding: try CaptureCoachLiveActionRecoveryBinding(
                archiveId: archiveId, captureId: captureId),
            durability: JazzArchiveFilesystemPlatform.durability)
        messageProjector = try CaptureCoachLiveMessageProjector(
            captureId: captureId,
            producer: producer,
            messages: transport.messages,
            stateRoot: captureRoot.appendingPathComponent(
                "message-head", isDirectory: true),
            durability: JazzArchiveFilesystemPlatform.durability)
        worker = transport.worker
        deliveryNudge = CaptureCoachLiveDetachedDeliveryNudge { [worker = transport.worker] in
            await worker.deliverPending()
        }
        client = transport.client
        self.promptIntents = promptIntents
        actionIntentStore = actionIntents
        promptProjector = CaptureCoachLivePromptProjector(
            coordinator: coordinator,
            intents: promptIntents,
            receipts: CaptureCoachLiveReceiptUnionSink(spool: transport.receipts))
        actionProjector = CaptureCoachLiveActionReceiptProjector(
            intents: actionIntents, receipts: transport.receipts)
        self.onPresentation = onPresentation
        self.onAvailability = onAvailability
        self.liveAudioAvailable = liveAudioAvailable
    }

    func start() async {
        accepting = true
        do {
            try await messageProjector.recoverPendingProgress()
        } catch {
            await suspendForIntegrity("watermark recovery")
            return
        }
        do {
            let intents = try await promptIntents.allIntents()
            livePrompts = Dictionary(
                intents.map { ($0.promptId, $0.prompt) },
                uniquingKeysWith: { _, latest in latest })
        } catch {
            await suspendForIntegrity("prompt intent recovery")
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
                await self?.tick()
            }
        }
    }

    func stop() async {
        if audioSequencer.hasPendingChunks {
            await worker.reportLocalIntegrityFailure("audio sequence drain")
            await onAvailability(false)
        }
        accepting = false
        labelContextGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        activeScope = nil
        activeLabelId = nil
        deliveryNudge.schedule()
    }

    /// The compact watermark head belongs to crash recovery, not transport lifecycle. Route
    /// suspension and network shutdown must retain it; only the caller that has durably committed
    /// the canonical local capture may retire it.
    func retireRecoveryState() async {
        do {
            try await actionIntentStore.markCaptureCommitted()
            try await messageProjector.retireRecoveryState()
        } catch {
            await worker.reportLocalIntegrityFailure(
                "message head retirement")
            await onAvailability(false)
        }
    }

    func suspendProjection() {
        accepting = false
        labelContextGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        activeScope = nil
        activeLabelId = nil
    }

    func setActiveLabel(
        labelId: String?,
        processId: String?
    ) -> UInt64? {
        guard accepting else { return nil }
        labelContextGeneration &+= 1
        guard let labelId, let processId else {
            activeScope = nil
            activeLabelId = nil
            return nil
        }
        let proposed = CaptureCoachLiveScope(
            companyId: scopeAuthority.companyId,
            areaId: scopeAuthority.areaId,
            processId: processId,
            deviceId: scopeAuthority.deviceId)
        let selector = CaptureCoachLivePromptSelector(
            scope: proposed, captureId: captureId, labelId: labelId)
        guard (try? selector.validate()) != nil else {
            activeScope = nil
            activeLabelId = nil
            return nil
        }
        activeScope = proposed
        activeLabelId = labelId
        if liveAudioAvailable {
            _ = audioStreams.streamId(for: labelId)
        }
        return labelContextGeneration
    }

    func projectCanonicalObservation(
        _ record: JazzArchiveRecord,
        event: ActivityEvent
    ) async {
        guard accepting else { return }
        guard let labelId = event.labelId,
            let processId = event.processId
        else { return }
        let scope = CaptureCoachLiveScope(
            companyId: scopeAuthority.companyId,
            areaId: scopeAuthority.areaId,
            processId: processId,
            deviceId: scopeAuthority.deviceId)
        guard (try? scope.validate()) != nil else { return }
        let now = Timestamps.parse(record.capturedAt) ?? Date()
        let boundary = ["label_start", "label_end"].contains(event.eventType)
        if !boundary,
            let prior = lastMessageAtByLabel[labelId],
            now.timeIntervalSince(prior) < 2
        {
            return
        }
        let context = CaptureCoachLiveSanitizedObservationContext(
            applicationId: Self.bounded(event.application?.value, maximum: 256),
            applicationVersion: Self.bounded(
                event.application?.version, maximum: 128),
            documentKind: Self.bounded(event.system, maximum: 128),
            documentRef: Self.bounded(event.documentURL, maximum: 1_024),
            action: Self.bounded(event.eventType, maximum: 128),
            targetRole: Self.bounded(event.target?.role, maximum: 128),
            targetName: event.inputMasked == true
                ? nil : Self.bounded(event.target?.accessibleName, maximum: 1_024),
            payloadSummary: Self.bounded(
                "\(event.eventType) in \(event.label ?? processId)", maximum: 8_192),
            redactionPolicyVersion: "desktop-redaction-v1",
            maskedFields: event.inputMasked == true ? ["input"] : [])
        do {
            let evidence = CaptureCoachLiveCanonicalObservation(
                observationId: record.observationId,
                streamId: record.streamId,
                streamSequence: record.streamSequence,
                recordType: record.recordType,
                recordDigest: JazzArchiveDigest.sha256Hex(
                    try JazzArchiveCanonicalJSON.encode(record)),
                sanitizedContext: context)
            let pending = try await messageProjector.enqueue(
                scope: scope,
                labelId: labelId,
                createdAt: record.capturedAt,
                streamProgress: [
                    CaptureCoachStreamWatermark(
                        streamId: record.streamId,
                        throughSequence: record.streamSequence)
                ],
                evidence: [.canonicalObservation(evidence)])
            latestWatermarkByLabel[labelId] = pending.document.inputWatermark
            lastMessageAtByLabel[labelId] = now
            deliveryNudge.schedule()
        } catch {
            await suspendForIntegrity("observation projection")
        }
    }

    /// The label/process context is explicit because NarrationRecorder flushes its final partial
    /// buffer before returning from label close, while the async projection may run just afterwards.
    func projectAudioChunk(
        labelId: String,
        processId: String,
        chunk: CaptureCoachLivePCMChunk
    ) async {
        guard accepting, liveAudioAvailable else { return }
        do {
            let contiguous = try audioSequencer.admit(
                labelId: labelId, processId: processId, chunk: chunk)
            await projectAudio(
                contiguous, labelId: labelId, processId: processId)
        } catch {
            await suspendForIntegrity("audio sequence")
        }
    }

    private func projectAudio(
        _ chunks: [CaptureCoachLivePCMChunk],
        labelId: String,
        processId: String
    ) async {
        let audioStreamId = audioStreams.streamId(for: labelId)
        for chunk in chunks {
            let scope = CaptureCoachLiveScope(
                companyId: scopeAuthority.companyId,
                areaId: scopeAuthority.areaId,
                processId: processId,
                deviceId: scopeAuthority.deviceId)
            do {
                let audio = CaptureCoachLiveAudioChunk(
                    streamId: audioStreamId,
                    streamSequence: chunk.sequence,
                    startMillis: chunk.startMillis,
                    endMillis: chunk.endMillis,
                    mediaType: "audio/l16;rate=16000;channels=1",
                    bytes: chunk.bytes)
                let pending = try await messageProjector.enqueue(
                    scope: scope,
                    labelId: labelId,
                    createdAt: chunk.recordedAt,
                    streamProgress: [
                        CaptureCoachStreamWatermark(
                            streamId: audioStreamId,
                            throughSequence: chunk.sequence)
                    ],
                    evidence: [.audioChunk(audio)])
                latestWatermarkByLabel[labelId] = pending.document.inputWatermark
                deliveryNudge.schedule()
            } catch {
                await suspendForIntegrity("audio projection")
                return
            }
        }
    }

    func preparePromptAction(
        promptId: String,
        interactionType: CaptureCoachInteractionType,
        at date: Date
    ) async throws -> CaptureCoachLiveActionProjectionIntent? {
        guard let prompt = livePrompts[promptId] else { return nil }
        do {
            return try await actionIntentStore.prepare(
                CaptureCoachLiveActionProjectionIntent(
                    prompt: prompt, interactionType: interactionType, at: date))
        } catch {
            await suspendForIntegrity("action intent")
            return nil
        }
    }

    func prepareScopeAction(
        interactionType: CaptureCoachInteractionType,
        at date: Date
    ) async throws -> CaptureCoachLiveActionProjectionIntent? {
        guard let scope = activeScope,
            let labelId = activeLabelId,
            let watermark = latestWatermarkByLabel[labelId]
        else { return nil }
        do {
            return try await actionIntentStore.prepare(
                CaptureCoachLiveActionProjectionIntent(
                    scope: scope,
                    captureId: watermark.captureId,
                    labelId: labelId,
                    inputWatermark: watermark,
                    interactionType: interactionType,
                    at: date))
        } catch {
            await suspendForIntegrity("scope action intent")
            return nil
        }
    }

    func projectAction(_ interaction: CaptureCoachInteraction) async {
        do {
            try await actionProjector.project(interaction)
            deliveryNudge.schedule()
        } catch {
            // The write-once intent remains available to the restart scanner.
            await suspendForIntegrity("action receipt projection")
        }
    }

    func nudge(labelContextGeneration expectedGeneration: UInt64) async {
        guard expectedGeneration == labelContextGeneration else { return }
        await worker.deliverPending()
        guard expectedGeneration == labelContextGeneration else { return }
        await pollPrompt()
    }

    private func tick() async {
        await worker.deliverPending()
        await pollPrompt()
    }

    private func pollPrompt() async {
        guard accepting,
            let scope = activeScope,
            let labelId = activeLabelId
        else { return }
        let generation = labelContextGeneration
        guard promptPollGate.begin(generation: generation) else {
            return
        }
        defer { promptPollGate.end(generation: generation) }
        let selector = CaptureCoachLivePromptSelector(
            scope: scope, captureId: captureId, labelId: labelId)
        if await worker.isSuspended() {
            await onAvailability(false)
            return
        }
        let prompt: CaptureCoachLivePrompt?
        do {
            prompt = try await client.nextPrompt(selector: selector)
        } catch {
            await worker.reportTransportFailure(error, operation: "prompt")
            await onAvailability(false)
            return
        }
        guard accepting,
            generation == labelContextGeneration,
            activeScope == scope,
            activeLabelId == labelId
        else { return }
        guard let prompt else {
            await onAvailability(!(await worker.isSuspended()))
            return
        }
        do {
            switch try await promptProjector.beginPresentation(prompt) {
            case .terminal:
                deliveryNudge.schedule()
            case .present(let ticket):
                guard accepting,
                    generation == labelContextGeneration,
                    activeScope == scope,
                    activeLabelId == labelId
                else { return }
                // This callback is the real UI boundary. Once it returns true we must append
                // `shown` even if label context changes immediately afterwards; otherwise the
                // audit trail would deny a presentation that the user actually saw.
                guard await onPresentation(ticket.prompt.domainPrompt) else {
                    return
                }
                livePrompts[prompt.promptId] = prompt
                _ = try await promptProjector.confirmPresented(ticket)
                deliveryNudge.schedule()
            }
            await onAvailability(!(await worker.isSuspended()))
        } catch {
            await suspendForIntegrity("prompt projection")
        }
    }

    private func suspendForIntegrity(_ context: String) async {
        accepting = false
        labelContextGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        activeScope = nil
        activeLabelId = nil
        await worker.reportLocalIntegrityFailure(context)
        await onAvailability(false)
    }

    private static func bounded(_ value: String?, maximum: Int) -> String? {
        guard
            var result = value?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !result.isEmpty
        else { return nil }
        while result.utf8.count > maximum { result.removeLast() }
        return result.isEmpty ? nil : result
    }
}
