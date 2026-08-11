import XCTest

@testable import JazzCaptureCore

final class AutoStartTests: XCTestCase {
    func testOptOutWins() {
        // Disabled beats every other signal — even a stored, ready-to-verify token.
        XCTAssertEqual(autoStartPlan(enabled: false, hasStoredToken: true), .disabled)
        XCTAssertEqual(autoStartPlan(enabled: false, hasStoredToken: false), .disabled)
    }

    func testNoTokenWhenNeverConnected() {
        XCTAssertEqual(autoStartPlan(enabled: true, hasStoredToken: false), .noToken)
    }

    func testReconnectWhenTokenStored() {
        XCTAssertEqual(autoStartPlan(enabled: true, hasStoredToken: true), .reconnect)
    }

    func testPendingEnrollmentAlwaysResumesAfterRelaunch() {
        XCTAssertEqual(
            connectionLaunchPlan(
                hasPendingEnrollment: true,
                reconnectEnabled: false,
                hasStoredToken: false),
            .resumePendingEnrollment)
        XCTAssertEqual(
            connectionLaunchPlan(
                hasPendingEnrollment: true,
                reconnectEnabled: true,
                hasStoredToken: true),
            .resumePendingEnrollment)
        XCTAssertEqual(
            connectionLaunchPlan(
                hasPendingEnrollment: false,
                reconnectEnabled: true,
                hasStoredToken: true),
            .reconnectStoredCredential)
        XCTAssertEqual(
            connectionLaunchPlan(
                hasPendingEnrollment: false,
                reconnectEnabled: false,
                hasStoredToken: true),
            .none)
    }

    func testConfirmedArchiveAutoStartDoesNotNeedNetworkCredentials() {
        XCTAssertTrue(
            shouldAutoStartCapture(
                continuousCapture: true,
                deliveryPolicy: .confirmedArchive,
                hasStoredToken: false,
                accessibilityGranted: true))
        XCTAssertFalse(
            shouldAutoStartCapture(
                continuousCapture: false,
                deliveryPolicy: .confirmedArchive,
                hasStoredToken: false,
                accessibilityGranted: true))
        XCTAssertFalse(
            shouldAutoStartCapture(
                continuousCapture: true,
                deliveryPolicy: .confirmedArchive,
                hasStoredToken: false,
                accessibilityGranted: false))
    }

    func testLiveCompatibilityAutoStartStillRequiresToken() {
        XCTAssertTrue(
            shouldAutoStartCapture(
                continuousCapture: true,
                deliveryPolicy: .liveCompatibility,
                hasStoredToken: true,
                accessibilityGranted: true))
        XCTAssertFalse(
            shouldAutoStartCapture(
                continuousCapture: true,
                deliveryPolicy: .liveCompatibility,
                hasStoredToken: false,
                accessibilityGranted: true))
    }
}
