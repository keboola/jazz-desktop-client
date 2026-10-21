import XCTest
@testable import JazzCaptureCore

final class ContinuousCaptureTests: XCTestCase {
    func testRolloverRequiresCommitAndNeverResumesPauseOrShutdown() {
        for bits in 0..<16 {
            XCTAssertEqual(bits == 3, ContinuousCapture.shouldContinue(
                enabled: bits & 1 != 0, committed: bits & 2 != 0,
                paused: bits & 4 != 0, terminating: bits & 8 != 0))
        }
        XCTAssertEqual(ContinuousCapture.pauseReminderInterval, 30 * 60)
        for bits in 0..<8 {
            XCTAssertEqual(bits == 3, ContinuousCapture.shouldRemind(
                enabled: bits & 1 != 0, paused: bits & 2 != 0, recording: bits & 4 != 0))
        }
    }

    func testReconnectNeverUndoesPauseButRelaunchStartsFresh() {
        for policy: JazzCaptureDeliveryPolicy in [.confirmedArchive, .liveCompatibility] {
            XCTAssertFalse(shouldAutoStartCapture(continuousCapture: true,
                deliveryPolicy: policy, hasStoredToken: true,
                accessibilityGranted: true, paused: true))
            XCTAssertTrue(shouldAutoStartCapture(continuousCapture: true,
                deliveryPolicy: policy, hasStoredToken: true,
                accessibilityGranted: true, paused: false))
        }
    }
}
