import XCTest

@testable import JazzCapture

final class WebCanvasTests: XCTestCase {
    func testArchiveEvidenceUsesProcessGovernanceRouteInsteadOfLegacySessionLookup() throws {
        let fragment = try XCTUnwrap(
            WebCanvas.processGovernanceFragment(
                areaId: "finance",
                processId: "monthly-booking"))
        let url = try XCTUnwrap(
            WebCanvas.embedURL(
                reviewAppURL: "https://jazz.example.test",
                sessionId: nil,
                routeFragment: fragment,
                live: false))

        XCTAssertEqual(
            url.absoluteString,
            "https://jazz.example.test/?embed=macos#/area/finance/process/monthly-booking/governance")
    }

    func testFreeTextCaptureRoutesToUnassignedEvidenceIntake() throws {
        let fragment = try XCTUnwrap(
            WebCanvas.processGovernanceFragment(
                areaId: "general",
                processId: "__unassigned__"))

        XCTAssertEqual(
            fragment,
            "/area/general/process/__unassigned__/governance")
    }

    func testLegacySessionEmbedRemainsAvailableForLiveCompatibilityViews() throws {
        let url = try XCTUnwrap(
            WebCanvas.embedURL(
                reviewAppURL: "https://jazz.example.test/",
                sessionId: "s-123",
                live: false))

        XCTAssertEqual(
            url.absoluteString,
            "https://jazz.example.test/?embed=macos&session=s-123")
    }
}
