import CoreGraphics
import XCTest

@testable import JasnostCaptureCore

final class WindowHitTestTests: XCTestCase {
    private let own: pid_t = 100
    private let foreign: pid_t = 200
    private let other: pid_t = 300

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// The click-through highlight overlay (ours, full-screen, topmost) is skipped; the foreign app
    /// window beneath it wins. This is the exact crash scenario (#ax-crash) the pick prevents.
    func testSkipsOwnOverlayPicksForeignBeneath() {
        let windows = [
            WindowDescriptor(ownerPID: own, bounds: rect(0, 0, 1440, 900)),  // overlay, front
            WindowDescriptor(ownerPID: foreign, bounds: rect(100, 100, 400, 300)),
        ]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CGPoint(x: 200, y: 200), excluding: own)
        XCTAssertEqual(pid, foreign)
    }

    /// Front-to-back z-order: the first foreign window containing the point wins, not a lower one.
    func testRespectsZOrder() {
        let windows = [
            WindowDescriptor(ownerPID: foreign, bounds: rect(0, 0, 500, 500)),  // on top
            WindowDescriptor(ownerPID: other, bounds: rect(0, 0, 500, 500)),  // below, same area
        ]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CGPoint(x: 250, y: 250), excluding: own)
        XCTAssertEqual(pid, foreign)
    }

    /// Only our own windows under the point -> nil (event falls back to frontmost-app attribution).
    func testOnlyOwnWindowsYieldsNil() {
        let windows = [
            WindowDescriptor(ownerPID: own, bounds: rect(0, 0, 1440, 900)),
            WindowDescriptor(ownerPID: own, bounds: rect(50, 50, 200, 100)),
        ]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CGPoint(x: 100, y: 100), excluding: own)
        XCTAssertNil(pid)
    }

    /// Point outside every window (bare desktop) -> nil.
    func testPointOutsideAllWindowsYieldsNil() {
        let windows = [WindowDescriptor(ownerPID: foreign, bounds: rect(0, 0, 100, 100))]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CGPoint(x: 500, y: 500), excluding: own)
        XCTAssertNil(pid)
    }

    /// A foreign window that does not contain the point is skipped in favour of one that does.
    func testSkipsForeignWindowNotContainingPoint() {
        let windows = [
            WindowDescriptor(ownerPID: foreign, bounds: rect(0, 0, 100, 100)),  // misses the point
            WindowDescriptor(ownerPID: other, bounds: rect(300, 300, 200, 200)),  // contains it
        ]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CGPoint(x: 350, y: 350), excluding: own)
        XCTAssertEqual(pid, other)
    }

    /// Secondary display to the LEFT of primary (negative global x) still matches by bounds.
    func testNegativeCoordinatesOnSecondaryDisplay() {
        let windows = [
            WindowDescriptor(ownerPID: foreign, bounds: rect(-1440, 0, 1440, 900))
        ]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CGPoint(x: -1340, y: 100), excluding: own)
        XCTAssertEqual(pid, foreign)
    }

    /// No windows at all (empty snapshot) -> nil, no crash.
    func testEmptyWindowListYieldsNil() {
        let pid = WindowHitTest.topmostForeignOwner(
            windows: [], at: CGPoint(x: 10, y: 10), excluding: own)
        XCTAssertNil(pid)
    }
}
