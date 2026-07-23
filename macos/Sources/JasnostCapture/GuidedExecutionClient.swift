import Foundation
import JasnostCaptureCore

enum GuidedExecutionHTTPError: Error, CustomStringConvertible {
    case invalidEndpoint
    case missingCredential
    case http(Int)
    case transport(String)

    var description: String {
        switch self {
        case .invalidEndpoint: return "Guided execution endpoint is invalid."
        case .missingCredential: return "Guided execution credential is unavailable."
        case let .http(status): return "Guided execution server returned HTTP \(status)."
        case let .transport(message): return "Guided execution transport failed: \(message)"
        }
    }
}

/// Direct HTTPS implementation of the transport-neutral guided execution boundary. Claim proofs
/// exist only in an ephemeral request body. The closure reads the token from Keychain at send time;
/// the client never stores it in a property value, URL, log or caller-stable lifecycle record.
final class GuidedExecutionHTTPClient: @unchecked Sendable, GuidedExecutionTransport {
    private let baseURL: URL
    private let session: URLSession
    private let credential: @Sendable () -> String?

    init(
        baseURL: URL,
        credential: @escaping @Sendable () -> String?,
        session: URLSession? = nil
    ) throws {
        guard baseURL.scheme?.lowercased() == "https",
            baseURL.host != nil,
            baseURL.user == nil,
            baseURL.password == nil,
            baseURL.query == nil,
            baseURL.fragment == nil
        else { throw GuidedExecutionHTTPError.invalidEndpoint }
        self.baseURL = baseURL
        self.credential = credential
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
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
        var body = try scopeObject(scope)
        body["reconciliationRequestId"] = .string(reconciliationRequestId)
        body["mode"] = .string(mode.rawValue)
        body["reason"] = .string(reason)
        body["evidence"] = try jsonValue(evidence)
        if let receiptRequestId {
            body["receiptRequestId"] = .string(receiptRequestId)
        }
        if let result { body["result"] = result }
        return try await post(
            ["replay", "claims", claimId, "reconcile"], body: .object(body))
    }

    private func post(_ path: [String], body: JazzArchiveJSONValue) async throws -> Data {
        try await send(
            url: endpoint(path),
            method: "POST",
            body: try JazzArchiveCanonicalJSON.encode(body))
    }

    private func send(url: URL, method: String, body: Data?) async throws -> Data {
        guard let token = credential(), !token.isEmpty else {
            throw GuidedExecutionHTTPError.missingCredential
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(token, forHTTPHeaderField: "X-StorageApi-Token")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                throw GuidedExecutionHTTPError.http(
                    (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            return data
        } catch let error as GuidedExecutionHTTPError {
            throw error
        } catch {
            throw GuidedExecutionHTTPError.transport(error.localizedDescription)
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
