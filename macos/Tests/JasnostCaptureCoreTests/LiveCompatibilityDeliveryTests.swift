import Foundation
import XCTest

@testable import JasnostCaptureCore

final class LiveCompatibilityDeliveryTests: XCTestCase {
    func testNativeRouteIsDerivedOnlyFromExactSignedArchiveRoute() throws {
        let route = try signedRoute(
            endpoint:
                "https://jazz.example/tenant-a/api/archive-ingests")

        let logs = try JazzLiveCompatibilityRequestPlan(
            routeBinding: route,
            signal: .logs)
        let traces = try JazzLiveCompatibilityRequestPlan(
            routeBinding: route,
            signal: .traces)

        XCTAssertEqual(
            logs.url.absoluteString,
            "https://jazz.example/tenant-a/api/live-compatibility/v1/logs")
        XCTAssertEqual(
            traces.url.absoluteString,
            "https://jazz.example/tenant-a/api/live-compatibility/v1/traces")
        XCTAssertEqual(logs.deviceId, "device-7")
        XCTAssertEqual(logs.routeBinding, route)
    }

    func testRequestCarriesExactBodyAndScopedHeadersWithoutPersistingCredential() throws {
        let route = try signedRoute(
            endpoint: "http://127.0.0.1:8787/api/archive-ingests")
        let plan = try JazzLiveCompatibilityRequestPlan(
            routeBinding: route,
            signal: .logs)
        let body = Data(#"{"resourceLogs":[]}"#.utf8)
        let secret = "8625-scoped-device-secret"
        let request = try plan.request(
            body: body,
            credential: JazzArchiveScopedDeviceCredential(secret))

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, body)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Jazz-Device-Id"),
            "device-7")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-StorageApi-Token"),
            secret)
        XCTAssertFalse(String(describing: plan).contains(secret))
    }

    func testRequestHardLimitRejectsEmptyAndOversizedPayloads() throws {
        let plan = try JazzLiveCompatibilityRequestPlan(
            routeBinding: signedRoute(
                endpoint: "https://jazz.example/api/archive-ingests"),
            signal: .traces)
        let credential = try JazzArchiveScopedDeviceCredential("scoped")

        XCTAssertThrowsError(
            try plan.request(body: Data(), credential: credential))
        XCTAssertThrowsError(
            try plan.request(
                body: Data(
                    repeating: 0,
                    count:
                        JazzLiveCompatibilityRequestPlan.maximumRequestBytes
                        + 1),
                credential: credential))
    }

    func testSignedArchiveOnlyEnrollmentRequiresJazzWithoutLegacyAck() throws {
        let (route, envelope) = try signedEnrollment(streamEndpoint: nil)
        let requirements = try JazzLiveCompatibilityDeliveryRequirements(
            routeBinding: route,
            signedEnvelope: envelope)
        let state = JazzLiveCompatibilityDeliveryState(
            payload: Data(#"{"resourceLogs":[]}"#.utf8),
            legacyAccepted: false,
            jazzAccepted: true,
            requiredDestinations: requirements.requiredDestinations)

        XCTAssertEqual(requirements.requiredDestinations, [.jazz])
        XCTAssertFalse(state.requires(.legacy))
        XCTAssertTrue(state.requires(.jazz))
        XCTAssertTrue(state.isComplete)
    }

    func testSignedLegacyEndpointRequiresBothDestinations() throws {
        let (route, envelope) = try signedEnrollment(
            streamEndpoint: "https://stream.example/otlp/source/secret")
        let requirements = try JazzLiveCompatibilityDeliveryRequirements(
            routeBinding: route,
            signedEnvelope: envelope)

        XCTAssertEqual(requirements.requiredDestinations, [.legacy, .jazz])
        XCTAssertFalse(
            JazzLiveCompatibilityDeliveryState(
                payload: Data(#"{"resourceLogs":[]}"#.utf8),
                legacyAccepted: false,
                jazzAccepted: true,
                requiredDestinations: requirements.requiredDestinations
            ).isComplete)
        XCTAssertTrue(
            JazzLiveCompatibilityDeliveryState(
                payload: Data(#"{"resourceLogs":[]}"#.utf8),
                legacyAccepted: true,
                jazzAccepted: true,
                requiredDestinations: requirements.requiredDestinations
            ).isComplete)
    }

    func testJazzAcceptanceMustBindExactPayloadAndCanonicalItemCount() throws {
        let body = Data(#"{"resourceLogs":[{"scopeLogs":[]}]}"#.utf8)
        let digest = JazzArchiveDigest.sha256Hex(body)
        let response = Data(
            """
            {"acceptedCanonicalItems":1,"payloadDigest":"sha256:\(digest)","schemaVersion":1}
            """.utf8)
        let acceptance = try JazzLiveCompatibilityAcceptance(
            responseData: response,
            expectedPayload: body,
            expectedCanonicalItems: 1)

        XCTAssertEqual(acceptance.acceptedCanonicalItems, 1)
        XCTAssertEqual(acceptance.payloadDigest, "sha256:\(digest)")
        let multiItemResponse = Data(
            """
            {"acceptedCanonicalItems":3,"payloadDigest":"sha256:\(digest)","schemaVersion":1}
            """.utf8)
        XCTAssertEqual(
            try JazzLiveCompatibilityAcceptance(
                responseData: multiItemResponse,
                expectedPayload: body,
                expectedCanonicalItems: 3
            ).acceptedCanonicalItems,
            3)
        for invalid in [
            Data("{}".utf8),
            Data(
                """
                {"acceptedCanonicalItems":0,"payloadDigest":"sha256:\(digest)","schemaVersion":1}
                """.utf8),
            Data(
                """
                {"acceptedCanonicalItems":1,"payloadDigest":"sha256:\(String(repeating: "0", count: 64))","schemaVersion":1}
                """.utf8),
        ] {
            XCTAssertThrowsError(
                try JazzLiveCompatibilityAcceptance(
                    responseData: invalid,
                    expectedPayload: body,
                    expectedCanonicalItems: 1))
        }
    }

    private func signedRoute(
        endpoint: String
    ) throws -> JazzArchiveUploadRouteBinding {
        try JazzArchiveUploadRouteBinding(
            ingestEndpoint: endpoint,
            stackURL: "https://connection.example.keboola.com",
            projectId: "123",
            tokenId: "456",
            scope: JazzArchiveUploadScope(
                companyId: "acme",
                areaId: "finance",
                deviceId: "device-7"),
            signedAuthority: JazzArchiveSignedEnrollmentAuthority(
                issuer: "https://issuer.example",
                audience: "jazz-desktop",
                bundleId: "jdb_00000000000000000000000000000007",
                generation: 7,
                envelopeDigest: String(repeating: "7", count: 64)))
    }

    private func signedEnrollment(
        streamEndpoint: String?
    ) throws -> (
        JazzArchiveUploadRouteBinding,
        JazzSignedDeviceCredentialEnvelope
    ) {
        let route = try signedRoute(
            endpoint: "https://jazz.example/api/archive-ingests")
        let routing = JazzArchiveEnrollmentRouting(
            projectId: route.projectId,
            stackURL: route.stackURL,
            scope: route.scope,
            archiveIngestURL: route.ingestEndpoint,
            tokenId: route.tokenId,
            expiresAt: "2099-07-24T00:00:00.000Z",
            tokenBucketScope: JazzArchiveTokenBucketScope.none,
            signedAuthority: route.signedAuthority)
        return (
            route,
            try JazzSignedDeviceCredentialEnvelope(
                token: "scoped-device-token",
                expiresAt: routing.expiresAt,
                routeBinding: route,
                enrollmentRouting: routing,
                streamSourceId: streamEndpoint == nil ? nil : "legacy-source",
                streamEndpoint: streamEndpoint)
        )
    }
}
