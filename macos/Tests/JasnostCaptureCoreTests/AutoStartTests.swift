import XCTest

@testable import JasnostCaptureCore

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

    func testAutoStartCaptureNeedsAllThreeSignals() {
        // Opt-in AND a stored token AND Accessibility — all required.
        XCTAssertTrue(
            shouldAutoStartCapture(
                continuousCapture: true, hasStoredToken: true, accessibilityGranted: true))
        XCTAssertFalse(
            shouldAutoStartCapture(
                continuousCapture: false, hasStoredToken: true, accessibilityGranted: true))
        XCTAssertFalse(
            shouldAutoStartCapture(
                continuousCapture: true, hasStoredToken: false, accessibilityGranted: true))
        XCTAssertFalse(
            shouldAutoStartCapture(
                continuousCapture: true, hasStoredToken: true, accessibilityGranted: false))
    }
}
