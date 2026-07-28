import Foundation
import XCTest

@testable import JasnostCapture
@testable import JasnostCaptureCore

final class ExecutableHTTPClientTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var responseData = Data()
        private static var responseStatus = 200
        private static var capturedRequest: URLRequest?

        static func prepare(status: Int = 200, data: Data) {
            lock.lock()
            responseStatus = status
            responseData = data
            capturedRequest = nil
            lock.unlock()
        }

        static func request() -> URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return capturedRequest
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.capturedRequest = request
            let status = Self.responseStatus
            let data = Self.responseData
            Self.lock.unlock()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testArchiveStatusClientPinsScopeAndCredentialToSignedRoute() async throws {
        let route = try signedRoute()
        let digest = String(repeating: "a", count: 64)
        let rawDigest = String(repeating: "b", count: 64)
        let response = """
            {
              "ingestId":"ingest-1",
              "state":"ready",
              "archiveId":"ar-11111111-1111-7111-8111-111111111111",
              "originId":"origin-11111111-1111-7111-8111-111111111111",
              "formatVersion":1,
              "revision":1,
              "contentDigest":"\(digest)",
              "rawSha256":"\(rawDigest)",
              "byteLength":42,
              "error":null,
              "nextAttemptAt":null
            }
            """
        StubURLProtocol.prepare(data: Data(response.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = try ArchiveUploadHTTPClient(
            routeBinding: route,
            sessionConfiguration: configuration)

        let status = try await client.status(
            ingestId: "ingest-1",
            scope: route.scope,
            credential: try JazzArchiveScopedDeviceCredential("scoped-device-secret"))

        XCTAssertEqual(status.state, .ready)
        let request = try XCTUnwrap(StubURLProtocol.request())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/archive-ingests/ingest-1")
        let query = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: (query.queryItems ?? []).map { ($0.name, $0.value) }),
            [
                "companyId": "acme",
                "areaId": "finance",
                "deviceId": "mac-1",
            ])
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-StorageApi-Token"),
            "scoped-device-secret")
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains("scoped-device-secret"))
    }

    func testDeviceBoundGuidedClientSendsExactAuthorityWithoutURLLeakage() async throws {
        StubURLProtocol.prepare(data: Data(#"{"status":"ready"}"#.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let capability =
            "rhc_8888888888888888888888888888888888888888888888888888888888888888."
            + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let client = try GuidedExecutionHTTPClient(
            baseURL: try XCTUnwrap(URL(string: "https://jazz.example/api/process-governance")),
            deviceId: "mac-1",
            replayCapability: capability,
            credential: {
                try JazzArchiveScopedDeviceCredential("guided-device-secret")
            },
            sessionConfiguration: configuration)

        let response = try await client.decision(
            scope: GuidedExecutionScope(
                companyId: "acme",
                areaId: "finance",
                processId: "issue-invoice"),
            decisionId: "decision-1")

        XCTAssertEqual(response, Data(#"{"status":"ready"}"#.utf8))
        let request = try XCTUnwrap(StubURLProtocol.request())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.path,
            "/api/process-governance/replay/decisions/decision-1")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-StorageApi-Token"),
            "guided-device-secret")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Jazz-Device-Id"),
            "mac-1")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Jazz-Replay-Capability"),
            capability)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Jazz-Action-Authority-Protocol"),
            "2")
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertFalse(url.contains(capability))
        XCTAssertFalse(url.contains("guided-device-secret"))
    }

    private func signedRoute() throws -> JazzArchiveUploadRouteBinding {
        try JazzArchiveUploadRouteBinding(
            ingestEndpoint: "https://jazz.example/api/archive-ingests",
            stackURL: "https://connection.example.keboola.com",
            projectId: "123",
            tokenId: "456",
            scope: JazzArchiveUploadScope(
                companyId: "acme",
                areaId: "finance",
                deviceId: "mac-1"),
            signedAuthority: JazzArchiveSignedEnrollmentAuthority(
                issuer: "https://issuer.example",
                audience: "jazz-desktop",
                bundleId: "jdb_00000000000000000000000000000001",
                generation: 1,
                envelopeDigest: String(repeating: "c", count: 64)))
    }
}
