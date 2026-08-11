import Foundation
import XCTest

@testable import JasnostCaptureCore

/// The renewal DECISION surface: route derivation, request bytes, response validation, failure
/// classification, the schedule, and the backoff. No networking and no Keychain — the executable
/// target owns those.
final class DeviceTokenRenewalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - Route

    func testRenewalRouteReplacesOnlyTheTerminalResource() throws {
        let route = try JazzDeviceTokenRenewalRoute(routeBinding: try routeBinding())
        XCTAssertEqual(
            route.url.absoluteString,
            "https://jazz.example/api/device-enrollment/renewals")
        XCTAssertEqual(route.deviceId, "mac-1")
    }

    func testRenewalRoutePreservesADeploymentPathPrefix() throws {
        let route = try JazzDeviceTokenRenewalRoute(
            routeBinding: try routeBinding(
                ingestEndpoint: "https://hub.example/apps/jazz-1234/api/archive-ingests"))
        XCTAssertEqual(
            route.url.absoluteString,
            "https://hub.example/apps/jazz-1234/api/device-enrollment/renewals")
    }

    func testRenewalRouteRejectsAnUnsignedEnrollment() throws {
        let mvp = try JazzArchiveUploadRouteBinding(
            mvpIngestEndpoint: "https://jazz.example/api/archive-ingests",
            stackURL: "https://connection.signed.keboola.com",
            projectId: "123",
            tokenId: "456",
            scope: try JazzArchiveUploadScope(
                companyId: "acme", areaId: "finance", deviceId: "mac-1"))
        XCTAssertThrowsError(try JazzDeviceTokenRenewalRoute(routeBinding: mvp)) {
            XCTAssertEqual($0 as? JazzDeviceTokenRenewalError, .invalidRoute)
        }
    }

    // MARK: - Request

    func testRequestBytesAreDeterministicAndCarryExactlyTheContractFields() throws {
        let request = try JazzDeviceTokenRenewalRequest(routeBinding: try routeBinding())
        XCTAssertEqual(request.deviceId, "mac-1")
        XCTAssertEqual(request.currentTokenId, "456")

        let body = try request.body()
        // An exact replay after a lost response depends on identical bytes.
        XCTAssertEqual(body, try request.body())
        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            #"{"currentTokenId":"456","deviceId":"mac-1","kind":"jazz-device-token-renewal-request","schemaVersion":1}"#
        )
    }

    func testRequestRejectsANonCanonicalIdentity() {
        XCTAssertThrowsError(
            try JazzDeviceTokenRenewalRequest(deviceId: " mac-1", currentTokenId: "456"))
        XCTAssertThrowsError(
            try JazzDeviceTokenRenewalRequest(deviceId: "mac-1", currentTokenId: ""))
    }

    func testRequestCarriesTheCredentialInHeadersNeverInTheURL() throws {
        let route = try JazzDeviceTokenRenewalRoute(routeBinding: try routeBinding())
        let request = try JazzDeviceTokenRenewalRequest(routeBinding: try routeBinding())
        let urlRequest = try route.request(
            body: try request.body(),
            credential: try JazzArchiveScopedDeviceCredential("123-scoped-device-secret"))

        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(
            urlRequest.value(forHTTPHeaderField: "X-StorageApi-Token"),
            "123-scoped-device-secret")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-Jazz-Device-Id"), "mac-1")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(
            try XCTUnwrap(urlRequest.url?.absoluteString).contains("123-scoped-device-secret"))
    }

    // MARK: - Grant validation

    func testGrantAcceptsARenewalForTheSameDeviceAndScope() throws {
        let grant = try grant()
        XCTAssertEqual(grant.deviceId, "mac-1")
        XCTAssertEqual(grant.tokenId, "457")
        XCTAssertEqual(grant.tokenBucketScope, .sink)
        XCTAssertEqual(grant.sinkBucketId, "in.c-otlp-src1")
        XCTAssertEqual(grant.renewAfterSeconds, 2_880)
        XCTAssertEqual(grant.componentAccess, [])
        XCTAssertEqual(grant.serverTime, "2026-02-02T02:40:00Z")
        XCTAssertGreaterThan(grant.expiresAtDate, now)
    }

    func testGrantAcceptsADeploymentThatDoesNotSupplyALeadTime() throws {
        var payload = grantPayload()
        payload.removeValue(forKey: "renewAfterSeconds")
        XCTAssertNil(try grant(payload).renewAfterSeconds)
    }

    func testGrantRejectsAnotherDevice() {
        assertGrantRejected(overriding: "deviceId", with: "mac-2")
    }

    func testGrantRejectsTheCredentialTheDeviceAlreadyHolds() {
        assertGrantRejected(overriding: "tokenId", with: "456")
    }

    func testGrantRejectsAnExpiryThatIsNotInTheFuture() {
        assertGrantRejected(overriding: "expiresAt", with: "2020-01-01T00:00:00Z")
        assertGrantRejected(overriding: "expiresAt", with: "not-a-timestamp")
    }

    func testGrantRejectsADriftedBucketScope() {
        assertGrantRejected(overriding: "tokenBucketScope", with: "none")
        assertGrantRejected(overriding: "sinkBucketId", with: "in.c-otlp-other")
        assertGrantRejected(overriding: "sinkBucketId", with: NSNull())
    }

    func testGrantRejectsAForeignEnvelope() {
        assertGrantRejected(overriding: "kind", with: "jazz-device-bundle")
        assertGrantRejected(overriding: "schemaVersion", with: 2)
        assertGrantRejected(overriding: "token", with: "")
        assertGrantRejected(overriding: "componentAccess", with: "keboola.ex-db")
        assertGrantRejected(overriding: "renewAfterSeconds", with: 0)
        assertGrantRejected(overriding: "renewAfterSeconds", with: 90 * 24 * 60 * 60)
    }

    func testGrantNeverRendersItsCredential() throws {
        let grant = try grant()
        XCTAssertFalse("\(grant)".contains("scoped-device-secret"))
        XCTAssertFalse(String(reflecting: grant).contains("scoped-device-secret"))
    }

    // MARK: - Atomic swap

    func testRenewedEnvelopeSwapsOnlyTheCredentialAndKeepsDeliveryAuthority() throws {
        let envelope = try signedEnvelope()
        let renewed = try envelope.renewed(with: try grant())

        XCTAssertEqual(renewed.enrollmentRouting.tokenId, "457")
        XCTAssertEqual(renewed.expiresAt, "2026-02-02T03:40:00Z")
        XCTAssertEqual(renewed.enrollmentRouting.expiresAt, "2026-02-02T03:40:00Z")
        XCTAssertTrue(renewed.routeBinding.hasSameDeliveryAuthority(as: envelope.routeBinding))
        XCTAssertEqual(
            renewed.routeBinding.signedAuthority,
            envelope.routeBinding.signedAuthority)
        XCTAssertEqual(renewed.routeBinding.scope, envelope.routeBinding.scope)
        XCTAssertEqual(renewed.streamSourceId, envelope.streamSourceId)
        XCTAssertEqual(
            try renewed.signedStreamEndpoint(),
            try envelope.signedStreamEndpoint())
        // The new secret is the one the request may now present.
        let request = try renewed.keboolaCredential(now: now)
            .request(path: "/v2/storage/tokens/verify", method: "GET", timeout: 10)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-StorageApi-Token"),
            "123-renewed-device-secret")
    }

    func testRenewedEnvelopeRefusesAGrantForAnotherDevice() throws {
        let envelope = try signedEnvelope(deviceId: "mac-9")
        XCTAssertThrowsError(try envelope.renewed(with: try grant())) {
            XCTAssertEqual($0 as? JazzDeviceTokenRenewalError, .authorityChanged)
        }
    }

    // MARK: - Failure classification

    func testEveryDocumentedRefusalStopsTheSchedule() {
        let terminal: [(Int, String)] = [
            (401, "DEVICE_RENEWAL_TOKEN_INVALID"),
            (401, "DEVICE_RENEWAL_TOKEN_EXPIRED"),
            (403, "DEVICE_RENEWAL_DEVICE_NOT_ENROLLED"),
            (403, "DEVICE_RENEWAL_DEVICE_INACTIVE"),
            (403, "DEVICE_RENEWAL_PROJECT_MISMATCH"),
            (403, "DEVICE_RENEWAL_SCOPE_MISMATCH"),
            (409, "DEVICE_RENEWAL_TOKEN_SUPERSEDED"),
        ]
        for (status, code) in terminal {
            let disposition = JazzDeviceTokenRenewalFailure.classify(status: status, code: code)
            XCTAssertFalse(disposition.isRetryable, code)
            XCTAssertNotNil(disposition.menuMessage, code)
            guard case .reenrollmentRequired = disposition else {
                return XCTFail("\(code) must ask for a re-enrollment")
            }
        }
    }

    func testAClientDefectIsNeverRetried() {
        for code in ["DEVICE_RENEWAL_AUTH_REQUIRED", "DEVICE_RENEWAL_REQUEST_INVALID"] {
            let disposition = JazzDeviceTokenRenewalFailure.classify(
                status: code.hasSuffix("REQUEST_INVALID") ? 422 : 401,
                code: code)
            XCTAssertFalse(disposition.isRetryable, code)
            guard case .clientDefect = disposition else {
                return XCTFail("\(code) is a client bug")
            }
        }
    }

    func testAnUnsupportedProfileStopsSchedulingRenewals() {
        let disposition = JazzDeviceTokenRenewalFailure.classify(
            status: 503,
            code: "DEVICE_RENEWAL_UNSUPPORTED_PROFILE")
        XCTAssertFalse(disposition.isRetryable)
        guard case .unsupportedDeployment = disposition else {
            return XCTFail("an unsupported profile is not an outage")
        }
    }

    func testAnOutageIsRetryableButOnlyWithATransientStatus() {
        XCTAssertTrue(
            JazzDeviceTokenRenewalFailure.classify(
                status: 503, code: "DEVICE_RENEWAL_UNAVAILABLE"
            ).isRetryable)
        // The server reuses UNAVAILABLE with a dependency's own status; a 403 is a refusal.
        XCTAssertFalse(
            JazzDeviceTokenRenewalFailure.classify(
                status: 403, code: "DEVICE_RENEWAL_UNAVAILABLE"
            ).isRetryable)
    }

    func testCodesAreMatchedWithoutDependingOnTheWirePrefix() {
        XCTAssertEqual(
            JazzDeviceTokenRenewalFailure.classify(status: 409, code: "TOKEN_SUPERSEDED"),
            JazzDeviceTokenRenewalFailure.classify(
                status: 409, code: "DEVICE_RENEWAL_TOKEN_SUPERSEDED"))
    }

    func testAnUnknownCodeIsClassifiedByStatus() {
        XCTAssertTrue(
            JazzDeviceTokenRenewalFailure.classify(status: 500, code: nil).isRetryable)
        XCTAssertTrue(
            JazzDeviceTokenRenewalFailure.classify(status: 429, code: "SOMETHING_NEW").isRetryable)
        guard case .reenrollmentRequired = JazzDeviceTokenRenewalFailure.classify(
            status: 401,
            code: nil)
        else { return XCTFail("an unexplained 401 must ask for a re-enrollment") }
        guard case .clientDefect = JazzDeviceTokenRenewalFailure.classify(status: 404, code: nil)
        else { return XCTFail("an unexplained 404 is our bug, not an outage") }
    }

    func testATransportFailureIsAlwaysRetryable() {
        XCTAssertTrue(JazzDeviceTokenRenewalFailure.transport("offline").isRetryable)
        XCTAssertNil(JazzDeviceTokenRenewalFailure.transport("offline").menuMessage)
    }

    func testTheRefusalCodeIsReadFromTheServersDetailEnvelope() {
        let body = Data(
            #"{"detail":{"code":"DEVICE_RENEWAL_TOKEN_SUPERSEDED","detail":"not current"}}"#.utf8)
        XCTAssertEqual(
            JazzDeviceTokenRenewalFailure.code(inResponse: body),
            "DEVICE_RENEWAL_TOKEN_SUPERSEDED")
        XCTAssertNil(
            JazzDeviceTokenRenewalFailure.code(inResponse: Data(#"{"detail":"nope"}"#.utf8)))
        XCTAssertNil(JazzDeviceTokenRenewalFailure.code(inResponse: Data("<html>".utf8)))
    }

    func testRetryAfterIsHonouredInDeltaSecondsAndClamped() {
        XCTAssertEqual(JazzDeviceTokenRenewalFailure.retryAfter("5"), 5)
        XCTAssertEqual(JazzDeviceTokenRenewalFailure.retryAfter(" 12 "), 12)
        XCTAssertEqual(JazzDeviceTokenRenewalFailure.retryAfter("100000"), 300)
        XCTAssertNil(JazzDeviceTokenRenewalFailure.retryAfter(nil))
        XCTAssertNil(JazzDeviceTokenRenewalFailure.retryAfter("Wed, 21 Oct 2026 07:28:00 GMT"))
        XCTAssertNil(JazzDeviceTokenRenewalFailure.retryAfter("-1"))
    }

    // MARK: - Backoff

    func testBackoffIsFullJitterFromFiveSecondsToAFiveMinuteCap() {
        let ceilings = (0..<8).map {
            JazzDeviceTokenRenewalPolicy.backoffCeiling(attempt: $0)
        }
        XCTAssertEqual(ceilings, [5, 10, 20, 40, 80, 160, 300, 300])
        // Full jitter: anywhere in [0, ceiling].
        XCTAssertEqual(
            JazzDeviceTokenRenewalPolicy.backoffDelay(attempt: 3, randomFraction: 0),
            0)
        XCTAssertEqual(
            JazzDeviceTokenRenewalPolicy.backoffDelay(attempt: 3, randomFraction: 1),
            40)
        XCTAssertEqual(
            JazzDeviceTokenRenewalPolicy.backoffDelay(attempt: 3, randomFraction: 0.5),
            20)
        // No attempt limit: a week of failures still produces a bounded, finite delay.
        XCTAssertEqual(
            JazzDeviceTokenRenewalPolicy.backoffDelay(attempt: 5_000, randomFraction: 1),
            300)
    }

    // MARK: - Schedule

    func testTheScheduleUsesTheServersOwnLeadTime() {
        let due = JazzDeviceTokenRenewalPolicy.due(
            anchor: JazzDeviceTokenRenewalAnchor(
                tokenId: "456",
                heldSince: now,
                renewAfterSeconds: 2_880),
            expiresAt: now.addingTimeInterval(3_600))
        XCTAssertEqual(due, now.addingTimeInterval(2_880))
    }

    func testTheScheduleFallsBackToTheLegacyFractionOfTheHeldLifetime() {
        let due = JazzDeviceTokenRenewalPolicy.due(
            anchor: JazzDeviceTokenRenewalAnchor(
                tokenId: "456",
                heldSince: now,
                renewAfterSeconds: nil),
            expiresAt: now.addingTimeInterval(3_600))
        XCTAssertEqual(due, now.addingTimeInterval(2_880))
    }

    /// The bug this pins: a due moment computed from the time STILL LEFT at each consultation is a
    /// moving target that always sits in the future, so a Mac whose deployment sends no lead time
    /// never renews at all. The schedule must be a fixed point that eventually arrives.
    func testTheLegacyScheduleIsAFixedMomentThatEventuallyArrives() {
        let expiresAt = now.addingTimeInterval(3_600)
        let anchor = JazzDeviceTokenRenewalPolicy.anchor(
            existing: nil,
            tokenId: "456",
            now: now)
        let due = JazzDeviceTokenRenewalPolicy.due(anchor: anchor, expiresAt: expiresAt)
        XCTAssertEqual(due, now.addingTimeInterval(2_880))

        // Consulting it again — a minute later, after a wake, after a relaunch — never moves it.
        for offset in [0.0, 1, 60, 600, 2_879, 2_880, 3_000, 3_599] {
            let persisted = JazzDeviceTokenRenewalPolicy.anchor(
                existing: anchor,
                tokenId: "456",
                now: now.addingTimeInterval(offset))
            XCTAssertEqual(persisted, anchor, "the anchor moved at +\(offset)s")
            XCTAssertEqual(
                JazzDeviceTokenRenewalPolicy.due(anchor: persisted, expiresAt: expiresAt),
                due,
                "the due moment moved at +\(offset)s")
        }
        // And it arrives, comfortably before the credential lapses.
        XCTAssertFalse(
            JazzDeviceTokenRenewalPolicy.shouldAttempt(
                due: due, lastAttemptAt: nil, now: now.addingTimeInterval(2_879)))
        XCTAssertTrue(
            JazzDeviceTokenRenewalPolicy.shouldAttempt(
                due: due, lastAttemptAt: nil, now: now.addingTimeInterval(2_880)))
        XCTAssertLessThan(due, expiresAt)
    }

    func testACredentialThisMacDidNotMintIsAnchoredAtFirstSight() {
        let minted = JazzDeviceTokenRenewalPolicy.anchor(
            existing: nil,
            tokenId: "456",
            now: now)
        XCTAssertEqual(minted.tokenId, "456")
        XCTAssertEqual(minted.heldSince, now)
        // Nothing is claimed about a lead time this Mac was never told.
        XCTAssertNil(minted.renewAfterSeconds)
    }

    func testAnAnchorForAnotherCredentialIsNeverInherited() {
        let anchor = JazzDeviceTokenRenewalPolicy.anchor(
            existing: JazzDeviceTokenRenewalAnchor(
                tokenId: "111",
                heldSince: now.addingTimeInterval(-10_000),
                renewAfterSeconds: 2_880),
            tokenId: "456",
            now: now)
        XCTAssertEqual(anchor.tokenId, "456")
        XCTAssertEqual(anchor.heldSince, now)
        XCTAssertNil(anchor.renewAfterSeconds)
        XCTAssertEqual(
            JazzDeviceTokenRenewalPolicy.due(
                anchor: anchor,
                expiresAt: now.addingTimeInterval(1_000)),
            now.addingTimeInterval(800))
    }

    func testTheScheduleNeverLandsAfterTheCredentialExpires() {
        let expiresAt = now.addingTimeInterval(600)
        XCTAssertEqual(
            JazzDeviceTokenRenewalPolicy.due(
                anchor: JazzDeviceTokenRenewalAnchor(
                    tokenId: "456",
                    heldSince: now,
                    renewAfterSeconds: 86_400),
                expiresAt: expiresAt),
            expiresAt)
    }

    func testACredentialFirstSeenAfterItsExpiryIsDueImmediately() {
        let expiresAt = now.addingTimeInterval(-1)
        XCTAssertEqual(
            JazzDeviceTokenRenewalPolicy.due(
                anchor: JazzDeviceTokenRenewalPolicy.anchor(
                    existing: nil,
                    tokenId: "456",
                    now: now),
                expiresAt: expiresAt),
            expiresAt)
    }

    /// The 60-second poll must not walk through an open backoff window: without this the escalating
    /// 5 s → 300 s schedule is silently truncated to one attempt a minute.
    func testAnOpenBackoffWindowOutranksEveryTrigger() {
        let due = now.addingTimeInterval(-3_000)
        let backoffUntil = now.addingTimeInterval(240)
        XCTAssertFalse(
            JazzDeviceTokenRenewalPolicy.shouldAttempt(
                due: due,
                lastAttemptAt: now.addingTimeInterval(-60),
                backoffUntil: backoffUntil,
                now: now))
        // Once the window closes, the ordinary floor applies again.
        XCTAssertTrue(
            JazzDeviceTokenRenewalPolicy.shouldAttempt(
                due: due,
                lastAttemptAt: now.addingTimeInterval(-300),
                backoffUntil: backoffUntil,
                now: backoffUntil))
        XCTAssertEqual(
            JazzDeviceTokenRenewalPolicy.nextAttempt(
                due: due,
                lastAttemptAt: now.addingTimeInterval(-60),
                backoffUntil: backoffUntil),
            backoffUntil)
    }

    // MARK: - Reading the stored credential

    func testATransientCredentialReadFailureRetriesInsteadOfStrandingTheMac() {
        // The vault reports a locked or busy credential store as `credentialUnavailable`; treating
        // that as terminal would park a Mac on "Reconnect this Mac" for a momentary read error.
        XCTAssertTrue(
            JazzDeviceTokenRenewalFailure.credentialRead(
                JazzArchiveUploadError.credentialUnavailable
            ).isRetryable)
        XCTAssertTrue(
            JazzDeviceTokenRenewalFailure.credentialRead(
                JazzArchiveUploadError.persistenceFailed("credential store busy")
            ).isRetryable)
        struct UnknownFailure: Error {}
        XCTAssertTrue(
            JazzDeviceTokenRenewalFailure.credentialRead(UnknownFailure()).isRetryable)
    }

    func testOnlyAPositivelyTerminalCredentialStateStopsTheSchedule() {
        for error: JazzArchiveUploadError in [.credentialExpired, .credentialBindingMismatch] {
            let disposition = JazzDeviceTokenRenewalFailure.credentialRead(error)
            XCTAssertFalse(disposition.isRetryable, "\(error)")
            guard case .reenrollmentRequired = disposition else {
                return XCTFail("\(error) must ask for a re-enrollment")
            }
        }
    }

    func testTheOncePerMinuteFloorSurvivesAWakeStorm() {
        let due = now.addingTimeInterval(-10)
        XCTAssertTrue(
            JazzDeviceTokenRenewalPolicy.shouldAttempt(
                due: due, lastAttemptAt: nil, now: now))
        XCTAssertFalse(
            JazzDeviceTokenRenewalPolicy.shouldAttempt(
                due: due,
                lastAttemptAt: now.addingTimeInterval(-5),
                now: now))
        XCTAssertTrue(
            JazzDeviceTokenRenewalPolicy.shouldAttempt(
                due: due,
                lastAttemptAt: now.addingTimeInterval(-60),
                now: now))
        XCTAssertFalse(
            JazzDeviceTokenRenewalPolicy.shouldAttempt(
                due: now.addingTimeInterval(30),
                lastAttemptAt: nil,
                now: now))
        XCTAssertEqual(
            JazzDeviceTokenRenewalPolicy.nextAttempt(
                due: due,
                lastAttemptAt: now.addingTimeInterval(-5)),
            now.addingTimeInterval(55))
    }

    // MARK: - Surfaced state

    func testOnlyActionableStatesReachTheMenu() throws {
        XCTAssertNil(JazzDeviceTokenRenewalStatus().menuMessage)
        XCTAssertNil(
            JazzDeviceTokenRenewalStatus(phase: .scheduled(at: now)).menuMessage)
        XCTAssertNil(JazzDeviceTokenRenewalStatus(phase: .renewing).menuMessage)
        XCTAssertNotNil(
            JazzDeviceTokenRenewalStatus(
                phase: .retrying(nextAttemptAt: now, reason: "offline")
            ).menuMessage)
        let blocked = JazzDeviceTokenRenewalStatus(
            phase: .stopped(.reenrollmentRequired("the stored credential expired")),
            tokenId: "456",
            expiresAt: now)
        XCTAssertEqual(
            blocked.menuMessage,
            "Reconnect this Mac — device token renewal stopped "
                + "(the stored credential expired).")
        // Every actionable line must survive the menu's 110-character budget intact.
        for reason in [
            "the credential scope no longer matches the enrollment",
            "the enrolled project no longer matches",
        ] {
            let message = try XCTUnwrap(
                JazzDeviceTokenRenewalStatus(
                    phase: .stopped(.reenrollmentRequired(reason))
                ).menuMessage)
            XCTAssertLessThanOrEqual("⚠︎ \(message)".count, 110, reason)
        }
        XCTAssertFalse(blocked.isCredentialUsable(now: now))
        XCTAssertTrue(
            JazzDeviceTokenRenewalStatus(expiresAt: now.addingTimeInterval(1))
                .isCredentialUsable(now: now))
    }

    // MARK: - Fixtures

    private func routeBinding(
        ingestEndpoint: String = "https://jazz.example/api/archive-ingests",
        tokenId: String = "456",
        deviceId: String = "mac-1"
    ) throws -> JazzArchiveUploadRouteBinding {
        try enrollmentRouting(
            ingestEndpoint: ingestEndpoint,
            tokenId: tokenId,
            deviceId: deviceId
        ).signedUploadRouteBinding()
    }

    private func enrollmentRouting(
        ingestEndpoint: String = "https://jazz.example/api/archive-ingests",
        tokenId: String = "456",
        deviceId: String = "mac-1",
        expiresAt: String = "2026-02-02T02:40:00Z",
        tokenBucketScope: JazzArchiveTokenBucketScope? = .sink,
        sinkBucketId: String? = "in.c-otlp-src1"
    ) throws -> JazzArchiveEnrollmentRouting {
        JazzArchiveEnrollmentRouting(
            projectId: "123",
            stackURL: "https://connection.signed.keboola.com",
            scope: try JazzArchiveUploadScope(
                companyId: "acme",
                areaId: "finance",
                deviceId: deviceId),
            archiveIngestURL: ingestEndpoint,
            tokenId: tokenId,
            expiresAt: expiresAt,
            tokenBucketScope: tokenBucketScope,
            sinkBucketId: sinkBucketId,
            signedAuthority: try JazzArchiveSignedEnrollmentAuthority(
                issuer: "https://issuer.example",
                audience: "jazz-desktop",
                bundleId: "jdb_00000000000000000000000000000001",
                generation: 1,
                envelopeDigest: String(repeating: "c", count: 64)),
            authorizationProfile: .signedJWS)
    }

    private func signedEnvelope(
        deviceId: String = "mac-1"
    ) throws -> JazzSignedDeviceCredentialEnvelope {
        let routing = try enrollmentRouting(deviceId: deviceId)
        return try JazzSignedDeviceCredentialEnvelope(
            token: "123-current-device-secret",
            expiresAt: routing.expiresAt,
            routeBinding: try routing.signedUploadRouteBinding(),
            enrollmentRouting: routing,
            streamSourceId: "src1",
            streamEndpoint: "https://stream.example.test/otlp/123/src1/secret")
    }

    private func grantPayload() -> [String: Any] {
        [
            "schemaVersion": 1,
            "kind": "jazz-device-token-renewal",
            "deviceId": "mac-1",
            "tokenId": "457",
            "token": "123-renewed-device-secret",
            "expiresAt": "2026-02-02T03:40:00Z",
            "tokenBucketScope": "sink",
            "sinkBucketId": "in.c-otlp-src1",
            "componentAccess": [],
            "renewAfterSeconds": 2_880,
            "serverTime": "2026-02-02T02:40:00Z",
        ]
    }

    private func grant(
        _ payload: [String: Any]? = nil
    ) throws -> JazzDeviceTokenRenewalGrant {
        try JazzDeviceTokenRenewalGrant(
            responseData: try JSONSerialization.data(
                withJSONObject: payload ?? grantPayload()),
            request: try JazzDeviceTokenRenewalRequest(routeBinding: try routeBinding()),
            currentRouting: try enrollmentRouting(),
            now: now)
    }

    private func assertGrantRejected(
        overriding field: String,
        with value: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var payload = grantPayload()
        payload[field] = value
        XCTAssertThrowsError(try grant(payload), field, file: file, line: line) { error in
            guard case .invalidResponse = error as? JazzDeviceTokenRenewalError else {
                return XCTFail("\(field) must fail closed, got \(error)", file: file, line: line)
            }
        }
    }
}
