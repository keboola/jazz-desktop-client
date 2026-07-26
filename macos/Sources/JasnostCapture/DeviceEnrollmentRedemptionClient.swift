import Foundation
import JasnostCaptureCore
import JasnostEnrollmentSecurity

struct KeychainDeviceRedemptionPendingStore: DeviceRedemptionPendingStoring, Sendable {
    func load() throws -> Data? {
        guard
            let encoded = try Keychain.get(
                account: Keychain.Account.pendingDeviceEnrollment)
        else {
            return nil
        }
        guard let exactBytes = Data(base64Encoded: encoded) else {
            throw DeviceEnrollmentRedemptionError.pendingStateUnavailable
        }
        return exactBytes
    }

    func replace(_ exactBytes: Data) throws {
        guard !exactBytes.isEmpty else {
            throw DeviceEnrollmentRedemptionError.pendingStateUnavailable
        }
        try Keychain.set(
            exactBytes.base64EncodedString(),
            account: Keychain.Account.pendingDeviceEnrollment)
    }

    func delete() throws {
        try Keychain.delete(account: Keychain.Account.pendingDeviceEnrollment)
    }
}

final class NativeDeviceRedemptionTransport: DeviceRedemptionTransport, @unchecked Sendable {
    private let session: JazzCredentialSafeHTTPSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "Accept-Encoding": "identity",
        ]
        session = JazzCredentialSafeHTTPSession(configuration: configuration)
    }

    func fetchContext(
        endpoint: URL,
        bearer: String
    ) async throws -> DeviceRedemptionHTTPResponse {
        try await send(
            endpoint: endpoint.appendingPathComponent("context"),
            method: "GET",
            bearer: bearer,
            body: nil)
    }

    func submitClaim(
        endpoint: URL,
        bearer: String,
        exactClaim: Data
    ) async throws -> DeviceRedemptionHTTPResponse {
        try await send(
            endpoint: endpoint.appendingPathComponent("claim"),
            method: "POST",
            bearer: bearer,
            body: exactClaim)
    }

    func poll(
        endpoint: URL,
        bearer: String
    ) async throws -> DeviceRedemptionHTTPResponse {
        try await send(
            endpoint: endpoint,
            method: "GET",
            bearer: bearer,
            body: nil)
    }

    private func send(
        endpoint: URL,
        method: String,
        bearer: String,
        body: Data?
    ) async throws -> DeviceRedemptionHTTPResponse {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(bearer, forHTTPHeaderField: "X-Jazz-Bootstrap")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(
            "application/json, application/jazz-device-enrollment-sealed+json",
            forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue(
                "application/jazz-device-enrollment-claim+json",
                forHTTPHeaderField: "Content-Type")
        }

        let (data, rawResponse) = try await session.boundedData(
            for: request,
            maximumResponseBytes: 200_000)
        guard
            let response = rawResponse as? HTTPURLResponse,
            response.url == endpoint
        else {
            throw DeviceEnrollmentRedemptionError.malformedResponse
        }
        var headers: [String: String] = [:]
        for (rawName, rawValue) in response.allHeaderFields {
            guard
                let name = rawName as? String,
                let value = rawValue as? String
            else {
                continue
            }
            headers[name] = value
        }
        return DeviceRedemptionHTTPResponse(
            statusCode: response.statusCode,
            body: data,
            headers: headers)
    }
}

enum DeviceEnrollmentRedemptionProduction {
    static func makeCoordinator() -> DeviceEnrollmentRedemptionCoordinator? {
        guard
            let trustPolicy = EnrollmentTrustBootstrap.load(),
            let routePolicy = EnrollmentTrustBootstrap.loadRedemptionRoutePolicy(),
            let identityVault = try? DeviceEnrollmentIdentityVault.production()
        else {
            return nil
        }
        return DeviceEnrollmentRedemptionCoordinator(
            pendingStore: KeychainDeviceRedemptionPendingStore(),
            transport: NativeDeviceRedemptionTransport(),
            identityVault: identityVault,
            trustPolicy: trustPolicy,
            routePolicy: routePolicy)
    }
}
