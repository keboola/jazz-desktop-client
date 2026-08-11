import Combine
import Foundation
import JazzCaptureCore

/// Reads the opaque enrolled device token only when one control-plane request is about to run.
/// The token is never cached in queue state, UserDefaults, logs, URLs, or process arguments.
@MainActor
struct KeychainArchiveCredentialProvider: JazzArchiveCredentialProvider, Sendable {
    func credential(
        for routeBinding: JazzArchiveUploadRouteBinding
    ) throws -> JazzArchiveScopedDeviceCredential {
        if routeBinding.hasSignedAuthority {
            return try SignedDeviceCredentialKeychain.vault.archiveCredential(
                for: routeBinding)
        }
        guard routeBinding.hasMVPAdminHandoffAuthority,
            let currentRoute = AgentSettings.shared.archiveUploadRouteBinding,
            currentRoute.hasMVPAdminHandoffAuthority,
            currentRoute.hasSameDeliveryAuthority(as: routeBinding),
            let routing = AgentSettings.shared.archiveEnrollmentRouting,
            routing.tokenId == currentRoute.tokenId,
            routing.expiresAtDate.map({ $0 > Date() }) == true,
            let token = try Keychain.get(account: Keychain.Account.kbcToken),
            !token.isEmpty
        else {
            throw JazzArchiveUploadError.credentialUnavailable
        }
        return try JazzArchiveScopedDeviceCredential(token)
    }
}

/// Concrete control-plane client plus a provider-neutral direct HTTP upload adapter. Upload grants
/// are interpreted only in memory and never persisted; their signed URLs/headers may expire freely.
final class ArchiveUploadHTTPClient: JazzArchiveUploadControlPlane,
    JazzArchiveDirectUploadTransport, @unchecked Sendable
{
    private static let maximumControlResponseBytes = 1 * 1_024 * 1_024
    private static let maximumUploadResponseBytes = 64 * 1_024

    let routeBinding: JazzArchiveUploadRouteBinding
    private let baseURL: URL
    private let session: JazzCredentialSafeHTTPSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        routeBinding: JazzArchiveUploadRouteBinding,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        guard routeBinding.hasDeliveryAuthority else {
            throw JazzArchiveUploadError.routeBindingMissing("enrollment authority")
        }
        guard let normalized = JazzArchiveControlPlaneURL.normalize(
            routeBinding.ingestEndpoint),
            let normalizedURL = URL(string: normalized)
        else {
            throw JazzArchiveUploadError.invalidItem("archive ingest URL")
        }
        self.routeBinding = routeBinding
        self.baseURL = normalizedURL
        let configuration = sessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3_600
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        self.session = JazzCredentialSafeHTTPSession(configuration: configuration)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func createIntent(
        _ request: JazzArchiveUploadIntentRequest,
        credential: JazzArchiveScopedDeviceCredential
    ) async throws -> JazzArchiveUploadIntentResponse {
        let payload = IntentPayload(
            uploadOperationId: request.uploadOperationId,
            archiveId: request.archiveId,
            originId: request.originId,
            formatVersion: request.formatVersion,
            revision: request.revision,
            contentDigest: request.contentDigest,
            rawSha256: request.rawSHA256,
            byteLength: request.byteLength,
            companyId: request.scope.companyId,
            areaId: request.scope.areaId,
            deviceId: request.scope.deviceId)
        let response: IntentEnvelope = try await send(
            method: "POST",
            url: baseURL.appendingPathComponent("intents"),
            payload: payload,
            credential: credential,
            expectedUploadOperationId: request.uploadOperationId)
        let instructions: JazzArchiveOpaqueUploadInstructions?
        if var upload = response.upload {
            guard let transport = upload.removeValue(forKey: "transport")?.stringValue else {
                throw JazzArchiveUploadError.invalidServerResponse(
                    "ARCHIVE_UPLOAD_TRANSPORT_MISSING")
            }
            instructions = try JazzArchiveOpaqueUploadInstructions(
                transport: transport,
                values: upload)
        } else {
            instructions = nil
        }
        return JazzArchiveUploadIntentResponse(
            status: try response.status.domain(),
            upload: instructions)
    }

    func reconcileLegacyIntent(
        _ request: JazzArchiveLegacyUploadReconciliationRequest,
        credential: JazzArchiveScopedDeviceCredential
    ) async throws -> JazzArchiveUploadIntentResponse {
        let response: IntentEnvelope = try await send(
            method: "POST",
            url: baseURL.appendingPathComponent("intents"),
            payload: LegacyIntentPayload(
                archiveId: request.archiveId,
                originId: request.originId,
                formatVersion: request.formatVersion,
                revision: request.revision,
                contentDigest: request.contentDigest,
                rawSha256: request.rawSHA256,
                byteLength: request.byteLength,
                companyId: request.scope.companyId,
                areaId: request.scope.areaId,
                deviceId: request.scope.deviceId),
            credential: credential)
        let instructions: JazzArchiveOpaqueUploadInstructions?
        if var upload = response.upload {
            guard let transport = upload.removeValue(forKey: "transport")?.stringValue else {
                throw JazzArchiveUploadError.invalidServerResponse(
                    "ARCHIVE_UPLOAD_TRANSPORT_MISSING")
            }
            instructions = try JazzArchiveOpaqueUploadInstructions(
                transport: transport,
                values: upload)
        } else {
            instructions = nil
        }
        return JazzArchiveUploadIntentResponse(
            status: try response.status.domain(),
            upload: instructions)
    }

    func finalize(
        ingestId: String,
        uploadOperationId: String,
        scope: JazzArchiveUploadScope,
        uploadReceipt: String,
        credential: JazzArchiveScopedDeviceCredential
    ) async throws -> JazzArchiveRemoteStatus {
        let url = try endpoint(ingestId: ingestId, suffix: "finalize")
        let response: StatusEnvelope = try await send(
            method: "POST",
            url: url,
            payload: FinalizePayload(
                uploadOperationId: uploadOperationId,
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                uploadReceipt: uploadReceipt),
            credential: credential,
            expectedUploadOperationId: uploadOperationId)
        return try response.domain()
    }

    func status(
        ingestId: String,
        scope: JazzArchiveUploadScope,
        credential: JazzArchiveScopedDeviceCredential
    ) async throws -> JazzArchiveRemoteStatus {
        let endpoint = try endpoint(ingestId: ingestId)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw JazzArchiveUploadError.invalidItem("archive status URL")
        }
        components.queryItems = [
            URLQueryItem(name: "companyId", value: scope.companyId),
            URLQueryItem(name: "areaId", value: scope.areaId),
            URLQueryItem(name: "deviceId", value: scope.deviceId),
        ]
        guard let url = components.url else {
            throw JazzArchiveUploadError.invalidItem("archive status URL")
        }
        let response: StatusEnvelope = try await send(
            method: "GET", url: url, payload: Optional<Int>.none, credential: credential)
        return try response.domain()
    }

    func upload(
        file: URL,
        instructions: JazzArchiveOpaqueUploadInstructions
    ) async throws -> String {
        let grant = try JazzArchiveHTTPPutGrant(instructions: instructions)
        var request = URLRequest(url: grant.url)
        request.httpMethod = "PUT"
        for (name, value) in grant.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await session.boundedUpload(
                for: request,
                fromFile: file,
                maximumResponseBytes: Self.maximumUploadResponseBytes)
        } catch JazzCredentialSafeHTTPSessionError.responseTooLarge {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_OBJECT_UPLOAD_RESPONSE_TOO_LARGE")
        } catch {
            throw JazzArchiveUploadError.retryable("ARCHIVE_OBJECT_UPLOAD_UNAVAILABLE")
        }
        guard let http = response as? HTTPURLResponse else {
            throw JazzArchiveUploadError.retryable("ARCHIVE_OBJECT_UPLOAD_INVALID_RESPONSE")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                // This is an expired/invalid object-store grant, not the enrolled device token.
                throw JazzArchiveUploadError.retryable("ARCHIVE_UPLOAD_GRANT_EXPIRED")
            }
            throw JazzArchiveUploadError.retryable("ARCHIVE_OBJECT_UPLOAD_HTTP_\(http.statusCode)")
        }
        guard let receipt = http.value(forHTTPHeaderField: grant.receiptHeader) else {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_UPLOAD_RECEIPT_MISSING")
        }
        return try JazzArchiveHTTPPutGrant.validateReceipt(receipt)
    }

    private func endpoint(ingestId: String, suffix: String? = nil) throws -> URL {
        guard !ingestId.isEmpty,
            ingestId.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression) != nil
        else { throw JazzArchiveUploadError.invalidServerResponse("INGEST_ID_INVALID") }
        var url = baseURL.appendingPathComponent(ingestId)
        if let suffix { url.appendPathComponent(suffix) }
        return url
    }

    private func send<Response: Decodable, Payload: Encodable>(
        method: String,
        url: URL,
        payload: Payload?,
        credential: JazzArchiveScopedDeviceCredential,
        expectedUploadOperationId: String? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payload {
            request.httpBody = try encoder.encode(payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        credential.withValue {
            request.setValue($0, forHTTPHeaderField: "X-StorageApi-Token")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.boundedData(
                for: request,
                maximumResponseBytes: Self.maximumControlResponseBytes)
        } catch JazzCredentialSafeHTTPSessionError.responseTooLarge {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_CONTROL_PLANE_RESPONSE_TOO_LARGE")
        } catch {
            throw JazzArchiveUploadError.retryable("ARCHIVE_CONTROL_PLANE_UNAVAILABLE")
        }
        guard let http = response as? HTTPURLResponse else {
            throw JazzArchiveUploadError.retryable("ARCHIVE_CONTROL_PLANE_INVALID_RESPONSE")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let expectedUploadOperationId,
                JazzArchiveUploadServerCompatibility.rejectsUploadOperationId(
                    statusCode: http.statusCode,
                    responseBody: data,
                    expectedOperationId: expectedUploadOperationId)
            {
                throw JazzArchiveUploadError.retryable(
                    JazzArchiveUploadServerCompatibility.operationIdContractNotReadyCode)
            }
            let code = (try? decoder.decode(ErrorEnvelope.self, from: data))?.detail.code
                ?? "ARCHIVE_HTTP_\(http.statusCode)"
            throw Self.mapServerError(code: code, status: http.statusCode)
        }
        do { return try decoder.decode(Response.self, from: data) }
        catch {
            throw JazzArchiveUploadError.invalidServerResponse(
                "ARCHIVE_RESPONSE_SCHEMA_INVALID")
        }
    }

    private static func mapServerError(code: String, status: Int) -> JazzArchiveUploadError {
        if code == "ARCHIVE_TOKEN_EXPIRED" { return .credentialExpired }
        if status == 401 || [
            "ARCHIVE_AUTH_REQUIRED", "ARCHIVE_TOKEN_INVALID", "ARCHIVE_TOKEN_REVOKED",
        ].contains(code) {
            return .tokenRejected(code)
        }
        if code.contains("COLLISION") || code.contains("FORK")
            || code.contains("DIGEST_MISMATCH")
        {
            return .conflict(code)
        }
        if code.contains("QUARANTIN") { return .quarantined(code) }
        if status == 403 || status == 413 || status == 422 { return .rejected(code) }
        if status >= 500 || status == 408 || status == 429 { return .retryable(code) }
        return .rejected(code)
    }

    static func isSafeControlPlaneURL(_ url: URL) -> Bool {
        JazzArchiveControlPlaneURL.normalize(url.absoluteString) != nil
    }

    private struct IntentPayload: Encodable {
        let uploadOperationId: String
        let archiveId: String
        let originId: String
        let formatVersion: Int
        let revision: Int
        let contentDigest: String
        let rawSha256: String
        let byteLength: Int64
        let companyId: String
        let areaId: String
        let deviceId: String
    }

    private struct LegacyIntentPayload: Encodable {
        let archiveId: String
        let originId: String
        let formatVersion: Int
        let revision: Int
        let contentDigest: String
        let rawSha256: String
        let byteLength: Int64
        let companyId: String
        let areaId: String
        let deviceId: String
    }

    private struct FinalizePayload: Encodable {
        let uploadOperationId: String
        let companyId: String
        let areaId: String
        let deviceId: String
        let uploadReceipt: String
    }

    private struct ServerError: Decodable { let code: String }
    private struct ErrorEnvelope: Decodable { let detail: ServerError }

    private struct StatusFields: Decodable {
        let ingestId: String
        let state: JazzArchiveRemoteState
        let archiveId: String
        let originId: String
        let formatVersion: Int
        let revision: Int
        let contentDigest: String
        let rawSha256: String
        let byteLength: Int64
        let error: ServerError?
        let nextAttemptAt: String?
    }

    private enum OperationEchoKey: String, CodingKey {
        case uploadOperationId
    }

    private struct StatusEnvelope: Decodable {
        let uploadOperationId: String?
        let fields: StatusFields

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: OperationEchoKey.self)
            uploadOperationId = container.contains(.uploadOperationId)
                ? try container.decode(String.self, forKey: .uploadOperationId)
                : nil
            fields = try StatusFields(from: decoder)
        }

        init(uploadOperationId: String?, fields: StatusFields) {
            self.uploadOperationId = uploadOperationId
            self.fields = fields
        }

        func domain() throws -> JazzArchiveRemoteStatus {
            guard !fields.ingestId.isEmpty else {
                throw JazzArchiveUploadError.invalidServerResponse("INGEST_ID_MISSING")
            }
            return JazzArchiveRemoteStatus(
                uploadOperationId: uploadOperationId,
                ingestId: fields.ingestId,
                state: fields.state,
                archiveId: fields.archiveId,
                originId: fields.originId,
                formatVersion: fields.formatVersion,
                revision: fields.revision,
                contentDigest: fields.contentDigest,
                rawSHA256: fields.rawSha256,
                byteLength: fields.byteLength,
                errorCode: fields.error?.code,
                nextAttemptAt: fields.nextAttemptAt)
        }
    }

    private struct IntentEnvelope: Decodable {
        let uploadOperationId: String?
        let fields: StatusFields
        let upload: [String: JazzArchiveJSONValue]?

        private enum CodingKeys: String, CodingKey {
            case uploadOperationId
            case upload
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uploadOperationId = container.contains(.uploadOperationId)
                ? try container.decode(String.self, forKey: .uploadOperationId)
                : nil
            fields = try StatusFields(from: decoder)
            upload = try container.decodeIfPresent(
                [String: JazzArchiveJSONValue].self,
                forKey: .upload)
        }

        var status: StatusEnvelope {
            StatusEnvelope(
                uploadOperationId: uploadOperationId,
                fields: fields)
        }
    }
}

private extension JazzArchiveJSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}

/// App-level owner of queue progress and confirmed finalization. Capture itself never calls this;
/// only local review confirmation creates an archive delivery.
@MainActor
final class ArchiveUploadManager: ObservableObject {
    @Published private(set) var items: [String: JazzArchiveUploadItem] = [:]
    @Published private(set) var isWorking = false
    @Published private(set) var status = "No confirmed archive is waiting"
    @Published private(set) var lastError: String?

    let queue: JazzArchiveUploadQueue
    private let confirmedDelivery: JazzArchiveConfirmedDelivery
    private let archiveRoot: URL
    private let draftStore: JazzArchiveDraftStore
    private let reviewStore: JazzArchiveReviewStore
    private var passTask: Task<Void, Never>?
    private var followUpTask: Task<Void, Never>?
    private var followUpAt: Date?

    init(spoolRoot: URL) {
        archiveRoot = spoolRoot.appendingPathComponent("archives", isDirectory: true)
        queue = JazzArchiveUploadQueue(
            root: spoolRoot.appendingPathComponent(
                "archive-upload-delivery",
                isDirectory: true),
            durability: JazzArchiveFilesystemPlatform.durability,
            leaseProvider: JazzArchiveFilesystemPlatform.uploadQueueLeaseProvider)
        confirmedDelivery = JazzArchiveConfirmedDelivery(
            archiveRoot: archiveRoot,
            queue: queue,
            durability: JazzArchiveFilesystemPlatform.durability)
        draftStore = JazzArchiveDraftStore(
            root: archiveRoot,
            durability: JazzArchiveFilesystemPlatform.durability)
        reviewStore = JazzArchiveReviewStore(
            root: archiveRoot,
            durability: JazzArchiveFilesystemPlatform.durability)
        Task { [weak self] in
            await self?.recoverConfirmedAndDrain()
        }
    }

    var pendingCount: Int {
        items.values.filter { !$0.state.isTerminal }.count
    }

    var reconnectCount: Int {
        items.values.filter { $0.state == .reconnectRequired }.count
    }

    func item(archiveId: String) -> JazzArchiveUploadItem? { items[archiveId] }

    func enqueueConfirmed(archiveId: String) async throws -> JazzArchiveUploadItem {
        let item = try await confirmedDelivery.enqueueConfirmed(
            archiveId: archiveId,
            scope: AgentSettings.shared.archiveUploadScope)
        await refresh()
        nudge()
        return item
    }

    func retry(archiveId: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let scope = AgentSettings.shared.archiveUploadScope {
                    _ = try await confirmedDelivery.bindScope(
                        archiveId: archiveId, scope: scope)
                }
                _ = try await queue.retry(archiveId: archiveId)
                await refresh()
                nudge()
            } catch {
                lastError = Self.safeMessage(error)
            }
        }
    }

    func reconcileLegacy(archiveId: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let routeBinding =
                    try SignedDeviceCredentialKeychain.vault.envelope()?.routeBinding
                    ?? AgentSettings.shared.archiveUploadRouteBinding
                guard let routeBinding
                else {
                    throw JazzArchiveUploadError.credentialUnavailable
                }
                let client = try ArchiveUploadHTTPClient(routeBinding: routeBinding)
                let coordinator = JazzArchiveUploadCoordinator(
                    queue: queue,
                    credentials: KeychainArchiveCredentialProvider(),
                    controlPlane: client,
                    objectTransport: client)
                _ = try await coordinator.reconcileLegacy(archiveId: archiveId)
                lastError = nil
                await refresh()
                nudge()
            } catch {
                lastError = Self.safeMessage(error)
                await refresh()
            }
        }
    }

    func cancel(archiveId: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await queue.cancel(archiveId: archiveId)
                await refresh()
            } catch {
                lastError = Self.safeMessage(error)
            }
        }
    }

    /// Called after bundle import/rotation. Scope is filled only for deliveries that never reached
    /// the server; reconnect-bound items then resume from their durable stage.
    func reconnectAndRetry() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await queue.all()
                for item in snapshot where item.state == .reconnectRequired {
                    if item.scope == nil, let scope = AgentSettings.shared.archiveUploadScope {
                        _ = try await confirmedDelivery.bindScope(
                            archiveId: item.archiveId, scope: scope)
                    }
                    _ = try? await queue.retry(archiveId: item.archiveId)
                }
                await refresh()
                nudge()
            } catch {
                lastError = Self.safeMessage(error)
            }
        }
    }

    func nudge() {
        guard passTask == nil else { return }
        passTask = Task { [weak self] in
            await self?.runPass()
        }
    }

    func refresh() async {
        do {
            let values = try await queue.all()
            items = Dictionary(uniqueKeysWithValues: values.map { ($0.archiveId, $0) })
            updateStatus()
        } catch {
            lastError = Self.safeMessage(error)
        }
    }

    private func recoverConfirmedAndDrain() async {
        let archiveIds = await draftStore.draftArchiveIds()
        for archiveId in archiveIds {
            guard (try? await queue.item(archiveId: archiveId)) == nil,
                let head = try? await reviewStore.latestArchiveAssertion(archiveId: archiveId),
                head.decision == .confirm
            else { continue }
            _ = try? await confirmedDelivery.enqueueConfirmed(
                archiveId: archiveId,
                scope: AgentSettings.shared.archiveUploadScope)
        }
        await refresh()
        nudge()
    }

    private func runPass() async {
        defer { passTask = nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let snapshot = try await queue.all()
            // Production authority comes from the atomic signed envelope. The explicitly marked
            // MVP compatibility profile uses its live-verified raw token plus exact persisted route.
            let currentEnrollment =
                try SignedDeviceCredentialKeychain.vault.envelope()?.routeBinding
                ?? AgentSettings.shared.archiveUploadRouteBinding
            let failures = try await JazzArchiveUploadPassRunner.drain(
                snapshot.filter { $0.canRunAutomatically() }
            ) { item in
                guard let routeBinding = item.effectiveRouteBinding(
                    currentEnrollment: currentEnrollment)
                else { return }
                let client = try ArchiveUploadHTTPClient(routeBinding: routeBinding)
                let coordinator = JazzArchiveUploadCoordinator(
                    queue: queue,
                    credentials: KeychainArchiveCredentialProvider(),
                    controlPlane: client,
                    objectTransport: client)
                _ = try await coordinator.run(archiveId: item.archiveId)
            }
            lastError = failures.first?.message
        } catch is CancellationError {
            return
        } catch {
            lastError = Self.safeMessage(error)
        }
        await refresh()
        scheduleFollowUpIfNeeded()
    }

    private func scheduleFollowUp(at deadline: Date) {
        if let followUpAt, followUpAt <= deadline { return }
        followUpTask?.cancel()
        followUpAt = deadline
        let delay = max(0.1, deadline.timeIntervalSinceNow)
        let nanoseconds = UInt64(min(delay, 86_400) * 1_000_000_000)
        followUpTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, !Task.isCancelled else { return }
            followUpTask = nil
            followUpAt = nil
            nudge()
        }
    }

    private func scheduleFollowUpIfNeeded() {
        if let earliest = JazzArchiveUploadRetryPolicy.nextAutomaticFollowUp(
            for: Array(items.values))
        {
            scheduleFollowUp(at: earliest)
        }
    }

    private func updateStatus() {
        let values = Array(items.values)
        if values.isEmpty {
            status = "No confirmed archive is waiting"
        } else if values.allSatisfy({
            $0.state == .reconnectRequired
                && $0.issue?.code == "ARCHIVE_SCOPE_UNAVAILABLE"
        }) {
            status = "Confirmed archives are saved locally; upload is not configured"
        } else if values.contains(where: { $0.state == .reconnectRequired }) {
            status = "Reconnect device to resume confirmed archive upload"
        } else if values.contains(where: { [.uploading, .finalizing].contains($0.state) }) {
            status = "Uploading confirmed Jazz Archive"
        } else if values.contains(where: { [.verifying, .processing].contains($0.state) }) {
            status = "Server is verifying confirmed Jazz Archive"
        } else if values.contains(where: { $0.state == .retryable }) {
            let next = values.compactMap { $0.nextAttemptAt }.sorted().first
            status = next.map {
                "Confirmed archive is safe locally; server retry after \($0)"
            } ?? "Confirmed archive is safe locally and waiting to retry"
        } else if values.contains(where: {
            [.failedTerminal, .conflict, .quarantined, .rejected].contains($0.state)
        }) {
            status = "A confirmed archive needs attention"
        } else if values.allSatisfy({ $0.state == .ready || $0.state == .cancelled }) {
            status = "Confirmed archives are settled"
        } else {
            status = "Confirmed archive queued"
        }
    }

    private static func safeMessage(_ error: Error) -> String {
        if let value = error as? JazzArchiveUploadError { return value.description }
        return "Archive delivery is temporarily unavailable; local bytes are safe."
    }
}
