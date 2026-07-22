import AppKit
import JasnostCaptureCore

/// A click-through overlay that briefly highlights the element the user just clicked (#4) — the
/// visible half of "record what you show". A single borderless window spans all displays; each
/// flash draws a rounded rectangle over the clicked element's Accessibility frame and fades out.
@MainActor
final class HighlightOverlay {
    private var window: NSWindow?
    private var view: HighlightView?

    /// Highlight the given Accessibility frame (top-left origin, global). No-op if the frame is empty.
    func flash(axFrame: CGRect) {
        guard axFrame.width > 1, axFrame.height > 1 else { return }
        ensureWindow()
        guard let window, let view else { return }
        let primaryHeight =
            (NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height)
            ?? NSScreen.main?.frame.height ?? window.frame.height
        let local = HighlightGeometry.toLocal(
            axFrame: axFrame, primaryHeight: primaryHeight, windowFrame: window.frame
        )
        window.orderFrontRegardless()
        view.show(rect: local)
    }

    /// Tear down the overlay window (call when capture stops).
    func hide() {
        view?.stop()
        window?.orderOut(nil)
        window = nil
        view = nil
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let frame = union.isNull ? (NSScreen.main?.frame ?? .zero) : union
        let w = NSWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true  // never steal clicks from the app being recorded
        w.level = .screenSaver  // float above ordinary windows
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let v = HighlightView(frame: CGRect(origin: .zero, size: frame.size))
        w.contentView = v
        window = w
        view = v
    }
}

/// Draws a single highlight rectangle that fades from fully visible to invisible over ~0.6 s.
private final class HighlightView: NSView {
    private var rect: CGRect = .zero
    private var alpha: CGFloat = 0
    private var fadeTimer: Timer?

    override var isFlipped: Bool { false }  // Cocoa default (bottom-left origin) — matches the geometry

    func show(rect: CGRect) {
        self.rect = rect
        alpha = 1.0
        needsDisplay = true
        fadeTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else {
                    t.invalidate()
                    return
                }
                self.alpha -= 0.05
                if self.alpha <= 0 {
                    self.alpha = 0
                    t.invalidate()
                }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    func stop() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        alpha = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard alpha > 0, rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.systemBlue.withAlphaComponent(0.16 * alpha).setFill()
        path.fill()
        NSColor.systemBlue.withAlphaComponent(0.9 * alpha).setStroke()
        path.lineWidth = 2.5
        path.stroke()
    }
}
