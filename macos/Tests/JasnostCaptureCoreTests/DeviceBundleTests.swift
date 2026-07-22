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
          "expiresAt": "2026-07-03T12:00:00.000Z",
          "componentAccess": ["keboola.sandboxes"]
        }
        """

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
        // Compare against the same instant parsed independently (validJSON expires at
        // 2026-07-03T12:00:00.000Z) rather than a magic epoch constant.
        let formatter = ISO8601DateFormatter()
        let expected = try XCTUnwrap(formatter.date(from: "2026-07-03T12:00:00Z"))
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

    // MARK: - Token shape helper

    func testLooksLikeStorageToken() {
        XCTAssertTrue(DeviceBundle.looksLikeStorageToken("2968-123456-abcdefghijklmnop0123"))
        XCTAssertFalse(DeviceBundle.looksLikeStorageToken(""))
        XCTAssertFalse(DeviceBundle.looksLikeStorageToken("no-numeric-project-id"))
        XCTAssertFalse(DeviceBundle.looksLikeStorageToken("2968-short"))
        XCTAssertFalse(DeviceBundle.looksLikeStorageToken("2968"))
    }
}
