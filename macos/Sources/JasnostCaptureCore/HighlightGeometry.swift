import CoreGraphics

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
        axFrame: CGRect, primaryHeight: CGFloat, windowFrame: CGRect
    ) -> CGRect {
        let cocoaGlobal = CGRect(
            x: axFrame.minX,
            y: primaryHeight - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        )
        return cocoaGlobal.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
    }
}
