import XCTest

@testable import JasnostCaptureCore

final class DeviceBundleTests: XCTestCase {
    /// A realistic bundle matching the processor's `issue_device_bundle` response, wrapped by the
    /// admin app into the `jazz-device-bundle` envelope (adds `kind` + `streamEndpoint`).
    private let validJSON = """
        {
          "kind": "jazz-device-bundle",
          "deviceId": "dev-abc123",
          "stackURL": "https://connection.groupon.keboola.cloud",
          "streamSourceId": "src-xyz",
          "streamEndpoint": "https://stream-in.keboola.com/otlp/2968/src-xyz/s3cr3t-value-here",
          "token": "2968-123456-abcdefghijklmnopqrstuvwxyz0123456789",
          "tokenId": "123456",
          "expiresAt": "2099-07-03T12:00:00.000Z",
          "tokenBucketScope": "sink",
          "sinkBucketId": "in.c-otlp-device-1",
          "componentAccess": ["keboola.sandboxes"]
        }
        """

    private let credentialExpiry = "2099-07-03T12:00:00Z"

    private var validationNow: Date {
        Timestamps.parse("2099-07-03T11:00:00Z")!
    }

    private func bundle(
        tokenId: String = "123456",
        expiresAt: String = "2099-07-03T12:00:00Z",
        tokenBucketScope: JazzArchiveTokenBucketScope? = .sink,
        sinkBucketId: String? = "in.c-otlp-device-1"
    ) -> DeviceBundle {
        DeviceBundle(
            deviceId: "dev-abc123",
            token: "2968-123456-abcdefghijklmnopqrstuvwxyz0123456789",
            tokenId: tokenId,
            expiresAt: expiresAt,
            tokenBucketScope: tokenBucketScope,
            sinkBucketId: sinkBucketId)
    }

    private func verifiedToken(
        _ mutate: (inout [String: Any]) -> Void = { _ in }
    ) throws -> KeboolaAPI.TokenVerify {
        var payload: [String: Any] = [
            "id": "123456",
            "description": "Jazz device",
            "isMasterToken": false,
            "isExpired": false,
            "isDisabled": false,
            "canManageBuckets": false,
            "canManageTokens": false,
            "canReadAllFileUploads": false,
            "expires": credentialExpiry,
            "bucketPermissions": ["in.c-otlp-device-1": "write"],
            "owner": ["id": 2968, "name": "Jasnost"],
        ]
        mutate(&payload)
        return try JSONDecoder().decode(
            KeboolaAPI.TokenVerify.self,
            from: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    }

    private func assertCredentialError(
        _ expected: DeviceBundle.CredentialValidationError,
        bundle: DeviceBundle,
        verify: KeboolaAPI.TokenVerify,
        now: Date? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try bundle.validateVerifiedCredential(verify, now: now ?? validationNow),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? DeviceBundle.CredentialValidationError,
                expected,
                file: file,
                line: line)
        }
    }

    // MARK: - Valid parse

    func testParsesValidBundle() throws {
        let bundle = try DeviceBundle.parse(validJSON).get()
        XCTAssertEqual(bundle.kind, "jazz-device-bundle")
        XCTAssertEqual(bundle.deviceId, "dev-abc123")
        XCTAssertEqual(bundle.stackURL, "https://connection.groupon.keboola.cloud")
        XCTAssertEqual(bundle.normalizedStackURL, "https://connection.groupon.keboola.cloud")
        XCTAssertEqual(bundle.streamSourceId, "src-xyz")
        XCTAssertEqual(
            bundle.streamEndpoint,
            "https://stream-in.keboola.com/otlp/2968/src-xyz/s3cr3t-value-here")
        XCTAssertEqual(bundle.token, "2968-123456-abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertEqual(bundle.tokenId, "123456")
        XCTAssertEqual(bundle.tokenBucketScope, .sink)
        XCTAssertEqual(bundle.sinkBucketId, "in.c-otlp-device-1")
        XCTAssertEqual(bundle.componentAccess, ["keboola.sandboxes"])
    }

    func testParsesMinimalBundleWithoutOptionalStreamFields() throws {
        // stackURL is optional only for bundles issued before #197; the other fields are optional
        // for the Phase-1 shared-endpoint compatibility path.
        let json = """
            {
              "kind": "jazz-device-bundle",
              "deviceId": "dev-1",
              "token": "2968-9-0123456789abcdef0123",
              "tokenId": "9",
              "expiresAt": "2026-07-03T12:00:00Z"
            }
            """
        let bundle = try DeviceBundle.parse(json).get()
        XCTAssertNil(bundle.streamSourceId)
        XCTAssertNil(bundle.streamEndpoint)
        XCTAssertNil(bundle.stackURL)
        XCTAssertNil(bundle.componentAccess)
        XCTAssertEqual(bundle.deviceId, "dev-1")
    }

    func testArchiveEnrollmentBindsExactVerifiedProjectAndStack() throws {
        let json = """
            {
              "kind": "jazz-device-bundle",
              "deviceId": "dev-1",
              "stackURL": "https://connection.keboola.com/",
              "projectId": "8625",
              "companyId": "acme",
              "areaId": "finance",
              "archiveIngestURL": "https://jazz.example.test/api/archive-ingests/",
              "token": "8625-9-0123456789abcdef0123",
              "tokenId": "9",
              "expiresAt": "2099-07-03T12:00:00Z",
              "tokenBucketScope": "sink",
              "sinkBucketId": "in.c-otlp-device-1"
            }
            """
        let bundle = try DeviceBundle.parse(json).get()
        let routing = try XCTUnwrap(try bundle.archiveEnrollmentRouting(
            verifiedStackURL: "https://connection.keboola.com",
            verifiedProjectId: "8625"))
        XCTAssertEqual(routing.projectId, "8625")
        XCTAssertEqual(routing.scope.deviceId, "dev-1")
        XCTAssertEqual(routing.scope.areaId, "finance")
        XCTAssertEqual(
            routing.archiveIngestURL,
            "https://jazz.example.test/api/archive-ingests")
        XCTAssertEqual(routing.tokenBucketScope, .sink)
        XCTAssertEqual(routing.sinkBucketId, "in.c-otlp-device-1")

        XCTAssertThrowsError(try bundle.archiveEnrollmentRouting(
            verifiedStackURL: "https://connection.keboola.com",
            verifiedProjectId: "9999")) { error in
                XCTAssertEqual(error as? DeviceBundle.ArchiveBindingError, .projectMismatch)
            }
        XCTAssertThrowsError(try bundle.archiveEnrollmentRouting(
            verifiedStackURL: "https://connection.eu-central-1.keboola.com",
            verifiedProjectId: "8625")) { error in
                XCTAssertEqual(error as? DeviceBundle.ArchiveBindingError, .stackMismatch)
            }
    }

    func testArchiveRoutingRequiresProjectAndCompleteTuple() {
        let json = """
            {
              "kind": "jazz-device-bundle",
              "deviceId": "dev-1",
              "stackURL": "https://connection.keboola.com",
              "companyId": "acme",
              "areaId": "finance",
              "archiveIngestURL": "https://jazz.example.test/api/archive-ingests",
              "token": "8625-9-0123456789abcdef0123",
              "tokenId": "9",
              "expiresAt": "2026-07-03T12:00:00Z"
            }
            """
        XCTAssertEqual(DeviceBundle.parse(json), .failure(.invalidArchiveDelivery))
    }

    func testScopedBundleWithoutArchiveRouteRemainsLegacyAndCannotEnableArchiveUpload() throws {
        let json = """
            {
              "kind": "jazz-device-bundle",
              "deviceId": "dev-1",
              "stackURL": "https://connection.keboola.com",
              "projectId": "8625",
              "companyId": "acme",
              "areaId": "finance",
              "streamEndpoint": "https://stream-in.keboola.com/otlp/8625/source/secret",
              "token": "8625-9-0123456789abcdef0123",
              "tokenId": "9",
              "expiresAt": "2026-07-03T12:00:00Z"
            }
            """
        let bundle = try DeviceBundle.parse(json).get()
        XCTAssertNil(try bundle.archiveEnrollmentRouting(
            verifiedStackURL: "https://connection.keboola.com",
            verifiedProjectId: "8625"))
    }

    func testArchiveControlPlaneURLAcceptsHTTPSAndLiteralLoopbackHTTP() {
        let accepted = [
            (
                "https://jazz.example.test/api/archive-ingests/",
                "https://jazz.example.test/api/archive-ingests"
            ),
            (
                "https://JAZZ.EXAMPLE.TEST:443/api/archive-ingests/",
                "https://jazz.example.test/api/archive-ingests"
            ),
            (
                "http://localhost:8000/api/archive-ingests/",
                "http://localhost:8000/api/archive-ingests"
            ),
            (
                "http://127.0.0.1:8000/prefix/api/archive-ingests",
                "http://127.0.0.1:8000/prefix/api/archive-ingests"
            ),
            (
                "http://[::1]:8000/api/archive-ingests",
                "http://[::1]:8000/api/archive-ingests"
            ),
        ]
        for (supplied, canonical) in accepted {
            XCTAssertEqual(JazzArchiveControlPlaneURL.normalize(supplied), canonical, supplied)
        }
    }

    func testArchiveControlPlaneURLRejectsUnsafeOrAmbiguousRoutes() {
        let rejected = [
            "http://evil.example/api/archive-ingests",
            "https://user:secret@jazz.example/api/archive-ingests",
            "https://jazz.example/api/another-service",
            "https://jazz.example/api/archive-ingests?token=secret",
            "https://jazz.example/api/archive-ingests#",
            "https://jazz.example:bad/api/archive-ingests",
            "https://jazz.example/a/../api/archive-ingests",
            "https://jazz.example/a//api/archive-ingests",
            "https://jazz.example/a%2f../api/archive-ingests",
            "https://jazz.example/prefix%2Fapi/archive-ingests",
            "https://jazz.example/prefix%5Capi/archive-ingests",
            "https://jazz.example/ api/archive-ingests",
            "http://localhost.evil.test/api/archive-ingests",
        ]
        for supplied in rejected {
            XCTAssertNil(JazzArchiveControlPlaneURL.normalize(supplied), supplied)
        }
    }

    func testParsesWithSurroundingWhitespace() throws {
        let padded = "\n\n   \(validJSON)  \n"
        XCTAssertNoThrow(try DeviceBundle.parse(padded).get())
    }

    func testParsesBase64DataURL() throws {
        let base64 = Data(validJSON.utf8).base64EncodedString()
        let dataURL = "data:application/json;base64,\(base64)"
        let bundle = try DeviceBundle.parse(dataURL).get()
        XCTAssertEqual(bundle.deviceId, "dev-abc123")
    }

    func testParsesPlainDataURL() throws {
        let escaped =
            validJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? validJSON
        let dataURL = "data:text/plain,\(escaped)"
        let bundle = try DeviceBundle.parse(dataURL).get()
        XCTAssertEqual(bundle.token, "2968-123456-abcdefghijklmnopqrstuvwxyz0123456789")
    }

    // MARK: - Rejections

    func testRejectsWrongKind() {
        let json = """
            {
              "kind": "something-else",
              "deviceId": "dev-1",
              "token": "2968-9-0123456789abcdef0123",
              "tokenId": "9",
              "expiresAt": "2026-07-03T12:00:00Z"
            }
            """
        XCTAssertEqual(DeviceBundle.parse(json), .failure(.notJazzBundle))
    }

    func testRejectsMissingKind() {
        let json = """
            {
              "deviceId": "dev-1",
              "token": "2968-9-0123456789abcdef0123",
              "tokenId": "9",
              "expiresAt": "2026-07-03T12:00:00Z"
            }
            """
        XCTAssertEqual(DeviceBundle.parse(json), .failure(.notJazzBundle))
    }

    func testRejectsEmptyToken() {
        let json = """
            {
              "kind": "jazz-device-bundle",
              "deviceId": "dev-1",
              "token": "",
              "tokenId": "9",
              "expiresAt": "2026-07-03T12:00:00Z"
            }
            """
        XCTAssertEqual(DeviceBundle.parse(json), .failure(.missingToken))
    }

    func testRejectsEmptyDeviceId() {
        let json = """
            {
              "kind": "jazz-device-bundle",
              "deviceId": "",
              "token": "2968-9-0123456789abcdef0123",
              "tokenId": "9",
              "expiresAt": "2026-07-03T12:00:00Z"
            }
            """
        XCTAssertEqual(DeviceBundle.parse(json), .failure(.missingToken))
    }

    func testRejectsObviouslyWrongTokenShape() {
        // A short, non-`<projectId>-<secret>` value can't be a scoped Storage token.
        let json = """
            {
              "kind": "jazz-device-bundle",
              "deviceId": "dev-1",
              "token": "not-a-token",
              "tokenId": "9",
              "expiresAt": "2026-07-03T12:00:00Z"
            }
            """
        XCTAssertEqual(DeviceBundle.parse(json), .failure(.missingToken))
    }

    func testRejectsInvalidStackURL() {
        let json = """
            {
              "kind": "jazz-device-bundle",
              "deviceId": "dev-1",
              "stackURL": "https://attacker.example.com",
              "token": "2968-9-0123456789abcdef0123",
              "tokenId": "9",
              "expiresAt": "2026-07-03T12:00:00Z"
            }
            """
        XCTAssertEqual(DeviceBundle.parse(json), .failure(.invalidStackURL))
    }

    func testRejectsMissingRequiredFieldAsMalformed() {
        // Right kind, but `tokenId` (required) is absent -> a decode failure, reported as malformed.
        let json = """
            {
              "kind": "jazz-device-bundle",
              "deviceId": "dev-1",
              "token": "2968-9-0123456789abcdef0123",
              "expiresAt": "2026-07-03T12:00:00Z"
            }
            """
        guard case .failure(let error) = DeviceBundle.parse(json),
            case .malformed = error
        else {
            return XCTFail("expected .malformed for a missing required field")
        }
    }

    func testRejectsEmptyTokenIdAndMalformedExpiry() {
        let emptyId = validJSON.replacingOccurrences(
            of: #""tokenId": "123456""#,
            with: #""tokenId": "   ""#)
        guard case .failure(.malformed) = DeviceBundle.parse(emptyId) else {
            return XCTFail("expected empty token id to fail")
        }

        let malformedExpiry = validJSON.replacingOccurrences(
            of: #""expiresAt": "2099-07-03T12:00:00.000Z""#,
            with: #""expiresAt": "never""#)
        guard case .failure(.malformed) = DeviceBundle.parse(malformedExpiry) else {
            return XCTFail("expected malformed finite expiry to fail")
        }
    }

    func testRejectsInconsistentStaticBucketScope() {
        let sinkWithoutBucket = validJSON.replacingOccurrences(
            of: #""sinkBucketId": "in.c-otlp-device-1","#,
            with: "")
        guard case .failure(.malformed) = DeviceBundle.parse(sinkWithoutBucket) else {
            return XCTFail("expected sink scope without sink id to fail")
        }

        let noneWithBucket = validJSON.replacingOccurrences(
            of: #""tokenBucketScope": "sink""#,
            with: #""tokenBucketScope": "none""#)
        guard case .failure(.malformed) = DeviceBundle.parse(noneWithBucket) else {
            return XCTFail("expected explicit empty scope with sink id to fail")
        }
    }

    func testRejectsGarbage() {
        for garbage in ["", "   ", "not json at all", "<html></html>", "12345", "[1,2,3]"] {
            guard case .failure = DeviceBundle.parse(garbage) else {
                return XCTFail("expected failure for garbage input \(garbage.debugDescription)")
            }
        }
    }

    func testRejectsRawTokenPastedAsBundle() {
        // A user pasting a raw Storage token (not a bundle) into the bundle field is not JSON.
        XCTAssertEqual(
            DeviceBundle.parse("2968-123456-abcdefghijklmnopqrstuvwxyz"),
            .failure(.malformed("not JSON")))
    }

    // MARK: - Expiry parsing

    func testExpiresAtDateParsesFractionalSeconds() throws {
        let bundle = try DeviceBundle.parse(validJSON).get()
        let date = try XCTUnwrap(bundle.expiresAtDate)
        // Compare against the same instant parsed independently rather than a magic epoch constant.
        let formatter = ISO8601DateFormatter()
        let expected = try XCTUnwrap(formatter.date(from: "2099-07-03T12:00:00Z"))
        XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testExpiresAtDateParsesPlainISO8601() throws {
        let bundle = DeviceBundle(
            deviceId: "d", token: "2968-9-0123456789abcdef0123", tokenId: "9",
            expiresAt: "2026-07-03T12:00:00Z")
        XCTAssertNotNil(bundle.expiresAtDate)
    }

    func testExpiresAtDateNilWhenUnparseable() {
        let bundle = DeviceBundle(
            deviceId: "d", token: "2968-9-0123456789abcdef0123", tokenId: "9", expiresAt: "not-a-date")
        XCTAssertNil(bundle.expiresAtDate)
    }

    // MARK: - Live credential security validation

    func testAcceptsExactFiniteSinkScopedCredential() throws {
        let verify = try verifiedToken { payload in
            // Equivalent RFC-3339 spelling must compare by instant, not raw text.
            payload["expires"] = "2099-07-03T14:00:00+02:00"
        }
        XCTAssertNoThrow(
            try bundle().validateVerifiedCredential(verify, now: validationNow))
    }

    func testAcceptsExplicitNoBucketScopeOnlyWithEmptyPermissions() throws {
        let noBucketBundle = bundle(
            tokenBucketScope: JazzArchiveTokenBucketScope.none,
            sinkBucketId: nil)
        let verify = try verifiedToken { $0["bucketPermissions"] = [String: String]() }
        XCTAssertNoThrow(
            try noBucketBundle.validateVerifiedCredential(verify, now: validationNow))
    }

    func testPersistedRoutingRevalidatesAndLegacyUnknownScopeFailsClosed() throws {
        let routing = JazzArchiveEnrollmentRouting(
            projectId: "2968",
            stackURL: "https://connection.keboola.com",
            scope: try JazzArchiveUploadScope(
                companyId: "acme",
                areaId: "finance",
                deviceId: "dev-abc123"),
            archiveIngestURL: "https://jazz.example.test/api/archive-ingests",
            tokenId: "123456",
            expiresAt: credentialExpiry,
            tokenBucketScope: .sink,
            sinkBucketId: "in.c-otlp-device-1")
        XCTAssertNoThrow(
            try routing.validateVerifiedCredential(
                try verifiedToken(),
                now: validationNow))

        let legacyJSON = """
            {
              "projectId": "2968",
              "stackURL": "https://connection.keboola.com",
              "scope": {
                "companyId": "acme",
                "areaId": "finance",
                "deviceId": "dev-abc123"
              },
              "archiveIngestURL": "https://jazz.example.test/api/archive-ingests",
              "tokenId": "123456",
              "expiresAt": "2099-07-03T12:00:00Z"
            }
            """
        let legacy = try JSONDecoder().decode(
            JazzArchiveEnrollmentRouting.self,
            from: Data(legacyJSON.utf8))
        XCTAssertThrowsError(
            try legacy.validateVerifiedCredential(
                try verifiedToken(),
                now: validationNow)
        ) { error in
            XCTAssertEqual(
                error as? DeviceBundle.CredentialValidationError,
                .missingBucketScope)
        }
    }

    func testRejectsEmptyOrDifferentVerifiedTokenIdentity() throws {
        assertCredentialError(
            .invalidTokenId,
            bundle: bundle(tokenId: " "),
            verify: try verifiedToken())
        assertCredentialError(
            .invalidTokenId,
            bundle: bundle(),
            verify: try verifiedToken { $0["id"] = " " })
        assertCredentialError(
            .tokenIdMismatch,
            bundle: bundle(),
            verify: try verifiedToken { $0["id"] = "654321" })
    }

    func testRejectsMissingMalformedMismatchedAndElapsedExpiry() throws {
        assertCredentialError(
            .invalidBundleExpiry,
            bundle: bundle(expiresAt: "never"),
            verify: try verifiedToken())
        assertCredentialError(
            .missingVerifiedExpiry,
            bundle: bundle(),
            verify: try verifiedToken { $0.removeValue(forKey: "expires") })
        assertCredentialError(
            .missingVerifiedExpiry,
            bundle: bundle(),
            verify: try verifiedToken { $0["expires"] = "never" })
        assertCredentialError(
            .expiryMismatch,
            bundle: bundle(),
            verify: try verifiedToken { $0["expires"] = "2099-07-03T12:00:01Z" })
        assertCredentialError(
            .credentialExpired,
            bundle: bundle(),
            verify: try verifiedToken(),
            now: Timestamps.parse("2099-07-03T12:00:00Z")!)
    }

    func testRejectsMasterDisabledAndServerReportedExpiredTokens() throws {
        assertCredentialError(
            .masterToken,
            bundle: bundle(),
            verify: try verifiedToken { $0["isMasterToken"] = true })
        assertCredentialError(
            .disabledToken,
            bundle: bundle(),
            verify: try verifiedToken { $0["isDisabled"] = true })
        assertCredentialError(
            .serverReportedExpired,
            bundle: bundle(),
            verify: try verifiedToken { $0["isExpired"] = true })
    }

    func testRejectsEveryMissingSecurityBoolean() throws {
        for field in [
            "isMasterToken",
            "isDisabled",
            "isExpired",
            "canManageBuckets",
            "canManageTokens",
            "canReadAllFileUploads",
        ] {
            assertCredentialError(
                .missingVerificationField(field),
                bundle: bundle(),
                verify: try verifiedToken { $0.removeValue(forKey: field) })
        }
    }

    func testRejectsEveryForbiddenPrivilege() throws {
        for field in ["canManageBuckets", "canManageTokens", "canReadAllFileUploads"] {
            assertCredentialError(
                .excessivePrivilege(field),
                bundle: bundle(),
                verify: try verifiedToken { $0[field] = true })
        }
    }

    func testRejectsMissingOrInconsistentBucketScope() throws {
        assertCredentialError(
            .missingBucketScope,
            bundle: bundle(tokenBucketScope: nil, sinkBucketId: nil),
            verify: try verifiedToken())
        assertCredentialError(
            .inconsistentBucketScope,
            bundle: bundle(tokenBucketScope: .sink, sinkBucketId: nil),
            verify: try verifiedToken())
        assertCredentialError(
            .inconsistentBucketScope,
            bundle: bundle(
                tokenBucketScope: JazzArchiveTokenBucketScope.none,
                sinkBucketId: "in.c-otlp-device-1"),
            verify: try verifiedToken())
    }

    func testRejectsMissingWrongOrAdditionalBucketPermissions() throws {
        assertCredentialError(
            .missingBucketPermissions,
            bundle: bundle(),
            verify: try verifiedToken { $0.removeValue(forKey: "bucketPermissions") })
        for permissions: [String: String] in [
            [:],
            ["in.c-otlp-device-1": "manage"],
            ["in.c-another-device": "write"],
            [
                "in.c-otlp-device-1": "write",
                "in.c-another-device": "read",
            ],
        ] {
            assertCredentialError(
                .bucketPermissionsMismatch,
                bundle: bundle(),
                verify: try verifiedToken { $0["bucketPermissions"] = permissions })
        }

        let noBucketBundle = bundle(
            tokenBucketScope: JazzArchiveTokenBucketScope.none,
            sinkBucketId: nil)
        assertCredentialError(
            .bucketPermissionsMismatch,
            bundle: noBucketBundle,
            verify: try verifiedToken {
                $0["bucketPermissions"] = ["in.c-otlp-device-1": "write"]
            })
    }

    // MARK: - Token shape helper

    func testLooksLikeStorageToken() {
        XCTAssertTrue(DeviceBundle.looksLikeStorageToken("2968-123456-abcdefghijklmnop0123"))
        XCTAssertFalse(DeviceBundle.looksLikeStorageToken(""))
        XCTAssertFalse(DeviceBundle.looksLikeStorageToken("no-numeric-project-id"))
        XCTAssertFalse(DeviceBundle.looksLikeStorageToken("2968-short"))
        XCTAssertFalse(DeviceBundle.looksLikeStorageToken("2968"))
    }
}
