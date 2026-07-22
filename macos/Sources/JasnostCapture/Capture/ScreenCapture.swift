import AppKit
import JasnostCaptureCore
import ScreenCaptureKit

/// Sparse one-shot screenshots (ScreenCaptureKit). Captures the focused window of the active app
/// (falling back to the main display) and returns **JPEG** bytes plus a **perceptual hash** of the
/// frame. The prepare-early flow uploads the bytes straight to Keboola Files (GCS) while the event
/// carries only the `screenshot_id`; the hash lets the capture path skip near-identical frames
/// (e.g. repeated clicks in the same view) so it doesn't waste an upload per click.
///
/// JPEG (q≈0.85) instead of PNG: a focused-window screenshot is typically several× smaller as JPEG
/// while staying legible for the downstream VLM extraction — a deliberate bandwidth trade-off
/// (bump the quality or switch back to PNG if VLM legibility ever suffers). Requires Screen
/// Recording permission.
enum ScreenCapture {
    /// JPEG compression quality (0…1). High enough to keep on-screen text legible for the VLM.
    private static let jpegQuality = 0.85
    /// dHash grid: 9×8 grayscale → exactly 64 bits (see ``PerceptualHash/dHash``).
    private static let hashWidth = 9
    private static let hashHeight = 8

    /// A captured frame: the JPEG bytes to upload and the dHash used for near-duplicate gating.
    struct Shot {
        let data: Data
        let hash: UInt64
    }

    static func focusedWindowShot(bundleID: String?, targetRect: CGRect? = nil) async -> Shot? {
        guard let image = await captureImage(bundleID: bundleID, targetRect: targetRect),
            let data = jpeg(image)
        else { return nil }
        let hash: UInt64
        if let samples = grayscaleSamples(image, width: hashWidth, height: hashHeight) {
            hash = PerceptualHash.dHash(grayscale: samples, width: hashWidth, height: hashHeight)
        } else {
            hash = 0  // no hash → never matches a stored hash, so the frame is kept (not skipped)
        }
        return Shot(data: data, hash: hash)
    }

    private static func captureImage(bundleID: String?, targetRect: CGRect?) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let filter: SCContentFilter
            if let window = pickWindow(content.windows, bundleID: bundleID, targetRect: targetRect) {
                filter = SCContentFilter(desktopIndependentWindow: window)
            } else if let display = content.displays.first {
                filter = SCContentFilter(display: display, excludingWindows: [])
            } else {
                return nil
            }
            let config = SCStreamConfiguration()
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            return nil
        }
    }

    /// Pick the window the user actually interacted with — NOT just "the first on-screen window of
    /// the app". Among the owning app's on-screen, **normal-layer** windows (`windowLayer == 0`
    /// excludes menu-bar extras, Control Center, and other overlay panels), prefer the one that
    /// CONTAINS the clicked element (`targetRect`); otherwise the largest (the main document window).
    ///
    /// The old `windows.first(where:)` grabbed a background / off-Space window or a system overlay in
    /// multi-window setups, which ScreenCaptureKit then captured as a blank placeholder frame — the
    /// dedup baseline would then lock onto that blank and suppress every later (good) shot. Returning
    /// nil here (no normal window of the app) falls back to a full-display capture, which still shows
    /// the real screen behind a transient panel.
    private static func pickWindow(
        _ windows: [SCWindow], bundleID: String?, targetRect: CGRect?
    ) -> SCWindow? {
        guard let bundleID else { return nil }
        let candidates = windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID
                && $0.isOnScreen
                && $0.windowLayer == 0
                && $0.frame.width > 1 && $0.frame.height > 1
        }
        if candidates.isEmpty { return nil }
        if let rect = targetRect, rect.width > 0, rect.height > 0 {
            let point = CGPoint(x: rect.midX, y: rect.midY)
            if let hit = candidates.first(where: { $0.frame.contains(point) }) { return hit }
        }
        return candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        })
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg, properties: [.compressionFactor: jpegQuality]
        )
    }

    /// Downscale to a tiny grayscale grid for the dHash (`width * height` bytes, row-major).
    private static func grayscaleSamples(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height)
        let gray = CGColorSpaceCreateDeviceGray()
        let ctx = buffer.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }
        guard let ctx else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
