import XCTest

@testable import JasnostCaptureCore

final class HighlightGeometryTests: XCTestCase {
    /// Single 1440x900 primary display, overlay window == that display.
    func testSingleDisplayFlip() {
        // An element 100pt from the top-left, 200x50, on a 1440x900 primary.
        let ax = CaptureRectangle(x: 100, y: 100, width: 200, height: 50)
        let local = HighlightGeometry.toLocal(
            axFrame: ax,
            primaryHeight: 900,
            windowFrame: CaptureRectangle(x: 0, y: 0, width: 1440, height: 900))
        // Cocoa bottom edge = 900 - (100 + 50) = 750; x unchanged; size unchanged.
        XCTAssertEqual(local, CaptureRectangle(x: 100, y: 750, width: 200, height: 50))
    }

    /// Element at the very top-left maps to the top of the Cocoa window.
    func testTopLeftElement() {
        let ax = CaptureRectangle(x: 0, y: 0, width: 80, height: 20)
        let local = HighlightGeometry.toLocal(
            axFrame: ax,
            primaryHeight: 900,
            windowFrame: CaptureRectangle(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(
            local,
            CaptureRectangle(x: 0, y: 880, width: 80, height: 20))  // 900 - 20
    }

    /// A second display to the LEFT of the primary (negative x): the overlay spans the union, so the
    /// window origin is negative and the local rect is offset back into positive view space.
    func testSecondDisplayLeftOfPrimary() {
        // Primary 1440x900 at (0,0); secondary 1440x900 at (-1440, 0). Union origin x = -1440.
        let ax = CaptureRectangle(
            x: -1340, y: 100, width: 200, height: 50)  // on the left display
        let union = CaptureRectangle(x: -1440, y: 0, width: 2880, height: 900)
        let local = HighlightGeometry.toLocal(axFrame: ax, primaryHeight: 900, windowFrame: union)
        // cocoaGlobal = (x:-1340, y: 900-150=750); offset by -union.origin (+1440, 0) -> x=100.
        XCTAssertEqual(local, CaptureRectangle(x: 100, y: 750, width: 200, height: 50))
    }
}
