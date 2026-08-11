import Foundation
import JazzCaptureCore

enum GuidedExecutionHTTPError: Error, CustomStringConvertible {
    case invalidEndpoint
    case missingCredential
    case credentialEndpointMismatch
    case invalidDeviceBinding
    case requestTooLarge
    case responseTooLarge
    case http(Int)
    case transport(String)

    var description: String {
        switch self {
        case .invalidEndpoint: return "Guided execution endpoint is invalid."
        case .missingCredential: return "Guided execution credential is unavailable."
        case .credentialEndpointMismatch:
            return "Guided execution credential is bound to a different endpoint."
        case .invalidDeviceBinding:
            return "Guided execution device handoff is invalid."
        case .requestTooLarge:
            return "Guided execution request exceeds the 4 MiB protocol limit."
        case .responseTooLarge:
            return "Guided execution response exceeds the 4 MiB protocol limit."
        case let .http(status): return "Guided execution server returned HTTP \(status)."
        case let .transport(message): return "Guided execution transport failed: \(message)"
        }
    }
}

/// Direct HTTPS implementation of the transport-neutral guided execution boundary. Claim proofs
/// enter only proof-bound request bodies and the permission-restricted active attempt journal; they
/// never enter URLs, logs, portable artifacts, or server responses. The closure reads the scoped
/// token from Keychain at send time and the client never stores it in a property value.
final class GuidedExecutionHTTPClient: @unchecked Sendable, GuidedExecutionTransport {
    private static let maximumWireBytes = 4 * 1_024 * 1_024
    private static let actionAuthorityProtocolVersion = "2"
    private enum Authorization {
        case legacy(@Sendable () -> String?)
        case deviceBound(
            authority: GuidedExecutionDeviceRequestAuthority,
            credential: @Sendable () throws -> JazzArchiveScopedDeviceCredential
        )
    }

    private let baseURL: URL
    private let session: JazzCredentialSafeHTTPSession
    private let authorization: Authorization

    /// Explicit local/development compatibility only. Enrolled production replay uses the
    /// device-bound initializer below and never reads this legacy credential.
    init(
        baseURL: URL,
        credential: @escaping @Sendable () -> String?,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        guard let normalized = GuidedExecutionEndpointBinding.normalize(baseURL.absoluteString)
        else { throw GuidedExecutionHTTPError.invalidEndpoint }
        self.baseURL = normalized
        self.authorization = .legacy(credential)
        let configuration = sessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        self.session = JazzCredentialSafeHTTPSession(configuration: configuration)
    }

    /// Production replay requires two independent authorities on every request: the current
    /// signed-enrollment credential and the opaque capability carried by the exact handoff.
    init(
        baseURL: URL,
        deviceId: String,
        replayCapability: String,
        credential: @escaping @Sendable () throws -> JazzArchiveScopedDeviceCredential,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        guard let normalized = GuidedExecutionEndpointBinding.normalize(baseURL.absoluteString)
        else { throw GuidedExecutionHTTPError.invalidEndpoint }
        guard let authority = try? GuidedExecutionDeviceRequestAuthority(
            deviceId: deviceId,
            replayCapability: replayCapability)
        else {
            throw GuidedExecutionHTTPError.invalidDeviceBinding
        }
        self.baseURL = normalized
        self.authorization = .deviceBound(
            authority: authority,
            credential: credential)
        let configuration = sessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        self.session = JazzCredentialSafeHTTPSession(configuration: configuration)
    }

    func decision(
        scope: GuidedExecutionScope,
        decisionId: String
    ) async throws -> Data {
        var components = URLComponents(
            url: try endpoint(["replay", "decisions", decisionId]),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "companyId", value: scope.companyId),
            URLQueryItem(name: "areaId", value: scope.areaId),
            URLQueryItem(name: "processId", value: scope.processId),
        ]
        guard let url = components?.url else {
            throw GuidedExecutionHTTPError.invalidEndpoint
        }
        return try await send(url: url, method: "GET", body: nil)
    }

    func prepare(
        scope: GuidedExecutionScope,
        request: GuidedReplayRequest
    ) async throws -> Data {
        try await post(
            ["replay", "prepare"],
            body: .object(try scopeObject(scope).merging([
                "request": try jsonValue(request)
            ]) { _, new in new }))
    }

    func refresh(
        scope: GuidedExecutionScope,
        decisionId: String,
        refreshRequestId: String,
        runtime: GuidedReplayRefreshRuntime
    ) async throws -> Data {
        try await post(
            ["replay", "decisions", decisionId, "refresh"],
            body: .object(try scopeObject(scope).merging([
                "refreshRequestId": .string(refreshRequestId),
                "runtime": try jsonValue(runtime)
            ]) { _, new in new }))
    }

    func claim(
        scope: GuidedExecutionScope,
        decisionId: String,
        claimRequestId: String,
        claimProof: String,
        replayHostId: String
    ) async throws -> Data {
        try await post(
            ["replay", "decisions", decisionId, "claims"],
            body: .object(try scopeObject(scope).merging([
                "claimRequestId": .string(claimRequestId),
                "claimProof": .string(claimProof),
                "replayHostId": .string(replayHostId),
            ]) { _, new in new }))
    }

    func start(
        scope: GuidedExecutionScope,
        claimId: String,
        startRequestId: String,
        claimProof: String
    ) async throws -> Data {
        try await post(
            ["replay", "claims", claimId, "start"],
            body: .object(try scopeObject(scope).merging([
                "startRequestId": .string(startRequestId),
                "claimProof": .string(claimProof),
            ]) { _, new in new }))
    }

    func lifecycle(
        scope: GuidedExecutionScope,
        claimId: String
    ) async throws -> Data {
        var components = URLComponents(
            url: try endpoint(["replay", "claims", claimId]),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "companyId", value: scope.companyId),
            URLQueryItem(name: "areaId", value: scope.areaId),
            URLQueryItem(name: "processId", value: scope.processId),
        ]
        guard let url = components?.url else {
            throw GuidedExecutionHTTPError.invalidEndpoint
        }
        return try await send(url: url, method: "GET", body: nil)
    }

    func cancel(
        scope: GuidedExecutionScope,
        claimId: String,
        cancellationRequestId: String,
        claimProof: String,
        reason: String
    ) async throws -> Data {
        try await post(
            ["replay", "claims", claimId, "cancel"],
            body: .object(try scopeObject(scope).merging([
                "cancellationRequestId": .string(cancellationRequestId),
                "claimProof": .string(claimProof),
                "reason": .string(reason),
            ]) { _, new in new }))
    }

    func recordReceipt(
        scope: GuidedExecutionScope,
        decisionId: String,
        claimId: String,
        startReceiptId: String,
        receiptRequestId: String,
        claimProof: String,
        result: JazzArchiveJSONValue
    ) async throws -> Data {
        try await post(
            ["replay", "decisions", decisionId, "receipts"],
            body: .object(try scopeObject(scope).merging([
                "claimId": .string(claimId),
                "startReceiptId": .string(startReceiptId),
                "receiptRequestId": .string(receiptRequestId),
                "claimProof": .string(claimProof),
                "result": result,
            ]) { _, new in new }))
    }

    func reconcile(
        scope: GuidedExecutionScope,
        claimId: String,
        reconciliationRequestId: String,
        mode: GuidedReconciliationMode,
        reason: String,
        evidence: [GuidedEvidenceReference],
        receiptRequestId: String?,
        result: JazzArchiveJSONValue?
    ) async throws -> Data {
        let body = try GuidedExecutionWirePayload.reconciliation(
            scope: scope,
            claimReconciliationRequestId: reconciliationRequestId,
            mode: mode,
            reason: reason,
            evidence: evidence,
            receiptRequestId: receiptRequestId,
            result: result)
        return try await post(
            ["replay", "claims", claimId, "reconcile"], body: body)
    }

    private func post(_ path: [String], body: JazzArchiveJSONValue) async throws -> Data {
        try await send(
            url: endpoint(path),
            method: "POST",
            body: try JazzArchiveCanonicalJSON.encode(body))
    }

    private func send(url: URL, method: String, body: Data?) async throws -> Data {
        guard body?.count ?? 0 <= Self.maximumWireBytes else {
            throw GuidedExecutionHTTPError.requestTooLarge
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            Self.actionAuthorityProtocolVersion,
            forHTTPHeaderField: "X-Jazz-Action-Authority-Protocol")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try authorize(&request)
        do {
            let (data, response) = try await session.boundedData(
                for: request,
                maximumResponseBytes: Self.maximumWireBytes)
            guard let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                throw GuidedExecutionHTTPError.http(
                    (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            return data
        } catch let error as GuidedExecutionHTTPError {
            throw error
        } catch JazzCredentialSafeHTTPSessionError.responseTooLarge {
            throw GuidedExecutionHTTPError.responseTooLarge
        } catch {
            throw GuidedExecutionHTTPError.transport(error.localizedDescription)
        }
    }

    private func authorize(_ request: inout URLRequest) throws {
        switch authorization {
        case let .legacy(credential):
            guard let token = credential(), !token.isEmpty else {
                throw GuidedExecutionHTTPError.missingCredential
            }
            request.setValue(token, forHTTPHeaderField: "X-StorageApi-Token")
        case let .deviceBound(authority, credential):
            let scopedCredential = try credential()
            authority.authorize(&request, credential: scopedCredential)
        }
    }

    private func endpoint(_ components: [String]) throws -> URL {
        var result = baseURL
        for component in components {
            guard !component.isEmpty, component != ".", component != "..",
                !component.contains("/")
            else { throw GuidedExecutionHTTPError.invalidEndpoint }
            result.appendPathComponent(component)
        }
        return result
    }

    private func scopeObject(
        _ scope: GuidedExecutionScope
    ) throws -> [String: JazzArchiveJSONValue] {
        guard !scope.companyId.isEmpty, !scope.areaId.isEmpty, !scope.processId.isEmpty else {
            throw GuidedExecutionError.invalidField("scope")
        }
        return [
            "companyId": .string(scope.companyId),
            "areaId": .string(scope.areaId),
            "processId": .string(scope.processId),
        ]
    }

    private func jsonValue<T: Encodable>(_ value: T) throws -> JazzArchiveJSONValue {
        try JSONDecoder().decode(
            JazzArchiveJSONValue.self,
            from: JSONEncoder().encode(value))
    }
}
