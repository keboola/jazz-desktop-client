import XCTest

@testable import JasnostCaptureCore

final class ActivityEventTests: XCTestCase {
    func testRequiredFieldsEncodedAndNilsOmitted() throws {
        let event = ActivityEvent(
            sessionId: "s-1",
            eventId: "s-1-0",
            sequence: 0,
            timestamp: "2026-05-30T10:00:00.000Z",
            eventType: "click",
            url: "app://com.apple.finder",
            system: "Finder",
            target: EventTarget(tag: "AXButton", role: "AXButton", accessibleName: "New Folder")
        )
        let data = try JSON.encode(event)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Required fields present.
        for key in ["sessionId", "eventId", "timestamp", "eventType", "url"] {
            XCTAssertNotNil(obj[key], "missing required field \(key)")
        }
        // Nested target encoded.
        let target = obj["target"] as! [String: Any]
        XCTAssertEqual(target["accessibleName"] as? String, "New Folder")
        XCTAssertEqual(target["role"] as? String, "AXButton")
        // Nil optionals omitted (additionalProperties:false on the schema).
        XCTAssertNil(obj["value"])
        XCTAssertNil(obj["audioFileId"])
        XCTAssertNil(obj["screenshotId"])
        // No unescaped-slash mangling of the url.
        XCTAssertEqual(obj["url"] as? String, "app://com.apple.finder")
    }
}

final class RedactionTests: XCTestCase {
    func testDenylistExcludesOnlyListedApps() {
        let policy = RedactionPolicy(denylist: ["com.1password.1password"])
        // Everything is captured by default...
        XCTAssertTrue(policy.isCaptureAllowed(bundleID: "com.apple.finder"))
        XCTAssertTrue(policy.isCaptureAllowed(bundleID: "com.microsoft.Excel"))
        // ...except the denylisted app.
        XCTAssertFalse(policy.isCaptureAllowed(bundleID: "com.1password.1password"))
        // A nil bundle id can't be attributed -> skipped.
        XCTAssertFalse(policy.isCaptureAllowed(bundleID: nil))
    }

    func testEmptyDenylistCapturesEverything() {
        let policy = RedactionPolicy(denylist: [])
        XCTAssertTrue(policy.isCaptureAllowed(bundleID: "com.apple.finder"))
        XCTAssertTrue(policy.isCaptureAllowed(bundleID: "com.any.app"))
    }

    func testActualFocusedOwnerOverridesAllowedFrontmostApp() {
        let policy = RedactionPolicy(denylist: ["com.1password.1password"])
        XCTAssertFalse(policy.isCaptureAllowed(
            preliminaryBundleID: "com.apple.finder",
            actualOwnerBundleID: "com.1password.1password"))
        XCTAssertTrue(policy.isCaptureAllowed(
            preliminaryBundleID: "com.1password.1password",
            actualOwnerBundleID: "com.apple.finder"))
    }

    func testSecureFieldIsSensitive() {
        XCTAssertTrue(
            Sensitivity.isSensitiveField(role: "AXTextField", subrole: "AXSecureTextField", label: nil)
        )
    }

    func testSensitiveLabelDetected() {
        XCTAssertTrue(Sensitivity.isSensitiveField(role: "AXTextField", subrole: nil, label: "Password"))
        XCTAssertTrue(Sensitivity.isSensitiveField(role: "AXTextField", subrole: nil, label: "API key"))
        XCTAssertFalse(Sensitivity.isSensitiveField(role: "AXTextField", subrole: nil, label: "Search"))
    }

    func testSanitizeTrimsAndCaps() {
        XCTAssertNil(Sensitivity.sanitize("   "))
        XCTAssertEqual(Sensitivity.sanitize("  hi  "), "hi")
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(Sensitivity.sanitize(long, maxLength: 10)?.count, 11)  // 10 + ellipsis
    }
}

final class IdentifierTests: XCTestCase {
    func testEventIdFormat() {
        XCTAssertEqual(Identifiers.eventId(sessionId: "s-1", sequence: 3), "s-1-3")
        XCTAssertTrue(Identifiers.newSessionId().hasPrefix("s-"))
    }

    func testNewLabelIdFormat() {
        let a = Identifiers.newLabelId()
        XCTAssertTrue(a.hasPrefix("l-"))
        XCTAssertNotEqual(a, Identifiers.newLabelId(), "each label id is unique")
    }

    func testTimestampIsISO8601WithFractionalSeconds() {
        let ts = Timestamps.iso8601(Date(timeIntervalSince1970: 0))
        XCTAssertTrue(ts.hasPrefix("1970-01-01T"))
        XCTAssertTrue(ts.contains("."), "expected fractional seconds")
    }
}
