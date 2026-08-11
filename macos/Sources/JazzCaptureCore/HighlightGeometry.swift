import Foundation

/// Portable point used by the Foundation-only capture core. Native targets convert to and from
/// their platform geometry at the boundary instead of making CoreGraphics part of the shared
/// contract.
public struct CapturePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Portable rectangle used by geometry and hit-test policy in the Foundation-only capture core.
public struct CaptureRectangle: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ point: CapturePoint) -> Bool {
        width > 0 && height > 0
            && point.x >= minX && point.x < maxX
            && point.y >= minY && point.y < maxY
    }

    public func offsetBy(dx: Double, dy: Double) -> CaptureRectangle {
        CaptureRectangle(x: x + dx, y: y + dy, width: width, height: height)
    }
}

/// Pure coordinate math for the on-screen click highlight (#4), split out so the flip — the easy
/// thing to get wrong — is unit-testable without AppKit.
public enum HighlightGeometry {
    /// Convert an Accessibility frame to a rect local to an overlay window.
    ///
    /// AX/Quartz frames are **top-left origin, y-down**, measured from the top of the PRIMARY
    /// display. Cocoa (NSView) is **bottom-left origin, y-up**. So a rect's Cocoa-global bottom edge
    /// is `primaryHeight - axFrame.maxY`. Then we offset by the overlay window's origin (the window
    /// spans the union of all screens) to get window-local coordinates. Points, not pixels — both
    /// systems use points, so no Retina scaling is involved.
    public static func toLocal(
        axFrame: CaptureRectangle,
        primaryHeight: Double,
        windowFrame: CaptureRectangle
    ) -> CaptureRectangle {
        let cocoaGlobal = CaptureRectangle(
            x: axFrame.minX,
            y: primaryHeight - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        )
        return cocoaGlobal.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
    }
}
