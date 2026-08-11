import XCTest

@testable import JazzCapture
@testable import JazzCaptureCore

/// The scheduler's lifecycle. `stop()` is wired to app termination and to
/// ``KeboolaConnection`` revoking network authority, so a disconnected Mac must not keep a
/// once-a-minute poll, a wake observer, a reachability monitor, or a URLSession alive.
@MainActor
final class DeviceTokenRenewerLifecycleTests: XCTestCase {
    func testStopEndsThePollAndGoesQuiet() {
        let renewer = DeviceTokenRenewer()
        var statusChanges = 0
        renewer.onStatusChange = { statusChanges += 1 }
        XCTAssertEqual(renewer.status.phase, .inactive)
        // `kickOff: false` installs the timers and observers without an immediate attempt, so this
        // test touches neither the credential store nor the network.
        renewer.start(kickOff: false)
        XCTAssertTrue(renewer.isRunning)

        renewer.stop()

        XCTAssertFalse(renewer.isRunning)
        // A deliberately revoked enrollment is not a renewal failure — the menu line clears.
        XCTAssertEqual(renewer.status.phase, .inactive)
        XCTAssertNil(renewer.status.menuMessage)
        // Publishing is deduplicated: standing down a renewer that was already quiet must not
        // churn the menu.
        XCTAssertEqual(statusChanges, 0)
    }

    func testStopIsIdempotentAndStartResumesAfterIt() {
        let renewer = DeviceTokenRenewer()
        renewer.stop()
        XCTAssertFalse(renewer.isRunning)

        renewer.start(kickOff: false)
        renewer.start(kickOff: false)
        XCTAssertTrue(renewer.isRunning)

        renewer.stop()
        renewer.stop()
        XCTAssertFalse(renewer.isRunning)

        // A newly imported enrollment brings the schedule back without a relaunch.
        renewer.start(kickOff: false)
        XCTAssertTrue(renewer.isRunning)
        renewer.stop()
    }
}
