import XCTest

@testable import JasnostCaptureCore

final class KeboolaStackTests: XCTestCase {
    func testNormalizesPublicAndDedicatedStacks() {
        XCTAssertEqual(
            KeboolaStack.normalize(" https://connection.europe-west3.gcp.keboola.com/ "),
            "https://connection.europe-west3.gcp.keboola.com")
        XCTAssertEqual(
            KeboolaStack.normalize("https://connection.groupon.keboola.cloud"),
            "https://connection.groupon.keboola.cloud")
    }

    func testRejectsTokenExfiltrationShapes() {
        for value in [
            "http://connection.groupon.keboola.cloud",
            "https://evil.example.com",
            "https://connection.evil.example.com",
            "https://user@connection.groupon.keboola.cloud",
            "https://connection.groupon.keboola.cloud:8443",
            "https://connection.groupon.keboola.cloud/v2/storage",
            "https://connection.groupon.keboola.cloud?next=evil",
            "https://connection.groupon.keboola.cloud#fragment",
        ] {
            XCTAssertNil(KeboolaStack.normalize(value), value)
        }
    }

    func testVerificationCandidatesPreferAndDeduplicatePersistedStack() {
        XCTAssertEqual(
            KeboolaStack.verificationCandidates(
                preferred: "https://connection.groupon.keboola.cloud/",
                known: [
                    "https://connection.europe-west3.gcp.keboola.com",
                    "https://connection.groupon.keboola.cloud",
                    "not-a-stack",
                ]),
            [
                "https://connection.groupon.keboola.cloud",
                "https://connection.europe-west3.gcp.keboola.com",
            ])
    }
}
