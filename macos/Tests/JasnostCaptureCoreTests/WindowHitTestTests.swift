import XCTest

@testable import JasnostCaptureCore

final class WindowHitTestTests: XCTestCase {
    private let own: pid_t = 100
    private let foreign: pid_t = 200
    private let other: pid_t = 300

    private func rect(
        _ x: Double,
        _ y: Double,
        _ width: Double,
        _ height: Double
    ) -> CaptureRectangle {
        CaptureRectangle(x: x, y: y, width: width, height: height)
    }

    /// The click-through highlight overlay (ours, full-screen, topmost) is skipped; the foreign app
    /// window beneath it wins. This is the exact crash scenario (#ax-crash) the pick prevents.
    func testSkipsOwnOverlayPicksForeignBeneath() {
        let windows = [
            WindowDescriptor(ownerPID: own, bounds: rect(0, 0, 1440, 900)),  // overlay, front
            WindowDescriptor(ownerPID: foreign, bounds: rect(100, 100, 400, 300)),
        ]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CapturePoint(x: 200, y: 200), excluding: own)
        XCTAssertEqual(pid, foreign)
    }

    /// Front-to-back z-order: the first foreign window containing the point wins, not a lower one.
    func testRespectsZOrder() {
        let windows = [
            WindowDescriptor(ownerPID: foreign, bounds: rect(0, 0, 500, 500)),  // on top
            WindowDescriptor(ownerPID: other, bounds: rect(0, 0, 500, 500)),  // below, same area
        ]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CapturePoint(x: 250, y: 250), excluding: own)
        XCTAssertEqual(pid, foreign)
    }

    /// Window managers and voice-input tools can publish full-screen helper surfaces above the
    /// actual document. They are not click targets and must never replace the layer-0 owner.
    func testSkipsNonNormalOverlayLayers() {
        let windows = [
            WindowDescriptor(
                ownerPID: foreign,
                bounds: rect(-398, -1440, 2560, 1440),
                layer: 25),
            WindowDescriptor(
                ownerPID: other,
                bounds: rect(0, 0, 490, 888),
                layer: 1_000),
            WindowDescriptor(
                ownerPID: 400,
                bounds: rect(-398, -1409, 2560, 1409),
                layer: 0),
        ]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows,
            at: CapturePoint(x: 500, y: -500),
            excluding: own)
        XCTAssertEqual(pid, 400)
    }

    func testSkipsFullyTransparentNormalWindow() {
        let windows = [
            WindowDescriptor(
                ownerPID: foreign,
                bounds: rect(0, 0, 500, 500),
                alpha: 0),
            WindowDescriptor(ownerPID: other, bounds: rect(0, 0, 500, 500)),
        ]
        XCTAssertEqual(
            WindowHitTest.topmostForeignOwner(
                windows: windows,
                at: CapturePoint(x: 250, y: 250),
                excluding: own),
            other)
    }

    /// Only our own windows under the point -> nil (event falls back to frontmost-app attribution).
    func testOnlyOwnWindowsYieldsNil() {
        let windows = [
            WindowDescriptor(ownerPID: own, bounds: rect(0, 0, 1440, 900)),
            WindowDescriptor(ownerPID: own, bounds: rect(50, 50, 200, 100)),
        ]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CapturePoint(x: 100, y: 100), excluding: own)
        XCTAssertNil(pid)
    }

    /// Point outside every window (bare desktop) -> nil.
    func testPointOutsideAllWindowsYieldsNil() {
        let windows = [WindowDescriptor(ownerPID: foreign, bounds: rect(0, 0, 100, 100))]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CapturePoint(x: 500, y: 500), excluding: own)
        XCTAssertNil(pid)
    }

    /// A foreign window that does not contain the point is skipped in favour of one that does.
    func testSkipsForeignWindowNotContainingPoint() {
        let windows = [
            WindowDescriptor(ownerPID: foreign, bounds: rect(0, 0, 100, 100)),  // misses the point
            WindowDescriptor(ownerPID: other, bounds: rect(300, 300, 200, 200)),  // contains it
        ]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CapturePoint(x: 350, y: 350), excluding: own)
        XCTAssertEqual(pid, other)
    }

    /// Secondary display to the LEFT of primary (negative global x) still matches by bounds.
    func testNegativeCoordinatesOnSecondaryDisplay() {
        let windows = [
            WindowDescriptor(ownerPID: foreign, bounds: rect(-1440, 0, 1440, 900))
        ]
        let pid = WindowHitTest.topmostForeignOwner(
            windows: windows, at: CapturePoint(x: -1340, y: 100), excluding: own)
        XCTAssertEqual(pid, foreign)
    }

    /// No windows at all (empty snapshot) -> nil, no crash.
    func testEmptyWindowListYieldsNil() {
        let pid = WindowHitTest.topmostForeignOwner(
            windows: [], at: CapturePoint(x: 10, y: 10), excluding: own)
        XCTAssertNil(pid)
    }

    /// Keep the portable geometry byte-for-byte equivalent to CGRect containment at boundaries.
    func testRightAndBottomEdgesRemainOutsideLikeCGRect() {
        let windows = [
            WindowDescriptor(ownerPID: foreign, bounds: rect(10, 20, 100, 50))
        ]

        XCTAssertEqual(
            WindowHitTest.topmostForeignOwner(
                windows: windows,
                at: CapturePoint(x: 10, y: 20),
                excluding: own),
            foreign)
        XCTAssertNil(
            WindowHitTest.topmostForeignOwner(
                windows: windows,
                at: CapturePoint(x: 110, y: 30),
                excluding: own))
        XCTAssertNil(
            WindowHitTest.topmostForeignOwner(
                windows: windows,
                at: CapturePoint(x: 30, y: 70),
                excluding: own))
    }

    func testAXTargetFrameMustContainPhysicalPointWhenKnown() {
        let point = CapturePoint(x: 250, y: 250)
        XCTAssertTrue(
            WindowHitTest.targetFrameIsPlausible(
                rect(200, 200, 100, 100),
                at: point))
        XCTAssertFalse(
            WindowHitTest.targetFrameIsPlausible(
                rect(0, 0, 100, 30),
                at: point))
        XCTAssertTrue(WindowHitTest.targetFrameIsPlausible(nil, at: point))
    }

    func testNamedFocusedElementOutranksAnonymousCanvasGroup() {
        XCTAssertEqual(
            WindowHitTest.semanticScore(
                role: "AXGroup",
                label: nil,
                value: nil,
                selectedText: nil,
                identifier: nil),
            0)
        XCTAssertGreaterThan(
            WindowHitTest.semanticScore(
                role: "AXCell",
                label: "Invoice approved N13",
                value: nil,
                selectedText: nil,
                identifier: nil),
            1)
    }

    func testAnonymousCanvasUsesExactPointerInsteadOfWindowSizedFrame() {
        let frame = WindowHitTest.canonicalTargetFrame(
            role: "AXGroup",
            label: nil,
            value: nil,
            identifier: nil,
            axFrame: rect(-352, -1156, 2446, 1106),
            pointer: CapturePoint(x: 900, y: -950))
        XCTAssertEqual(frame, rect(899.5, -950.5, 1, 1))

        XCTAssertEqual(
            WindowHitTest.canonicalTargetFrame(
                role: "AXButton",
                label: "Approve",
                value: nil,
                identifier: nil,
                axFrame: rect(800, -980, 120, 32),
                pointer: CapturePoint(x: 900, y: -950)),
            rect(800, -980, 120, 32))
    }
}
