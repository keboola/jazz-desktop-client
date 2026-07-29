import AppKit
import JasnostCaptureCore
import ScreenCaptureKit

/// Sparse one-shot screenshots (ScreenCaptureKit). Captures the focused window of the active app,
/// falling back to a privacy-filtered physical target display only when the window is unavailable,
/// and returns **JPEG** bytes, a **perceptual hash**, an honest asynchronous request/completion
/// interval, and the selected window/display scope. The hash lets the capture path skip
/// near-identical frames; interval/scope prevent a later processor from mistaking the frame for
/// exact mouse-up pixels or a display fallback for focused-window evidence.
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
    /// A screenshot is local enrichment, never permission to hold an admitted archive producer
    /// open indefinitely. ScreenCaptureKit cancellation is best-effort, so the deadline race does
    /// not structurally await a late OS result.
    nonisolated static let captureBudgetNanoseconds: UInt64 = 2_000_000_000
    /// One physical SCK request process-wide. A timed-out request keeps this slot until its actual
    /// callback returns; later logical captures fail immediately instead of piling up IPC.
    private static let physicalCapture = ScreenCaptureSingleFlight()

    enum Scope: Equatable, Sendable {
        case window(ownerBundleID: String?, windowID: CGWindowID)
        case display(
            displayID: CGDirectDisplayID,
            excludedApplicationBundleIDs: [String])
    }

    /// A captured frame. ScreenCaptureKit is asynchronous, so the honest timestamp is an interval:
    /// the frame was acquired sometime after the request began and no later than completion.
    struct Shot: Equatable, Sendable {
        let data: Data
        let hash: UInt64
        let requestStartedAt: Date
        let frameCompletedAt: Date
        let monotonicDurationMillis: Int64
        let scope: Scope
    }

    enum Unavailability: Equatable, Sendable {
        case sourceUnavailable
        case deadlineExceeded
        case cancelled
        case priorRequestStillInFlight

        var detail: String {
            switch self {
            case .sourceUnavailable:
                return "focused window screenshot returned no image"
            case .deadlineExceeded:
                return "focused window screenshot deadline exceeded"
            case .cancelled:
                return "focused window screenshot was cancelled"
            case .priorRequestStillInFlight:
                return "a prior physical screenshot request is still in flight"
            }
        }
    }

    enum Attempt: Equatable, Sendable {
        case captured(Shot)
        case unavailable(Unavailability)
    }

    struct EvidenceAssessment: Equatable, Sendable {
        let accepted: Bool
        let captureInterval: JazzArchiveArtifactCaptureInterval?
        let quality: JazzArchiveQuality
        let extensions: [String: JazzArchiveJSONValue]?
    }

    private struct CapturedFrame {
        let image: CGImage
        let completedAt: Date
        let completedUptime: TimeInterval
        let scope: Scope
    }

    struct DisplayGeometry: Equatable, Sendable {
        let displayID: CGDirectDisplayID
        let frame: CGRect
    }

    @MainActor
    static func focusedWindowShot(
        bundleID: String?,
        targetRect: CGRect? = nil,
        privacyDenylist: Set<String>,
        requireWindowAtTarget: Bool = false,
        budgetNanoseconds: UInt64 = captureBudgetNanoseconds
    ) async -> Attempt {
        // Pair conservatively: monotonic start first, wall anchor second, then OS request. The
        // elapsed duration therefore includes pairing/preemption delay instead of understating the
        // latest possible acquisition time.
        let requestStartedUptime = ProcessInfo.processInfo.systemUptime
        let requestStartedAt = Date()
        let capture = await physicalCapture.run(
            budgetNanoseconds: budgetNanoseconds
        ) { @MainActor in
            await captureImage(
                bundleID: bundleID,
                targetRect: targetRect,
                privacyDenylist: privacyDenylist,
                requireWindowAtTarget: requireWindowAtTarget)
        }
        let frame: CapturedFrame
        switch capture {
        case .value(let value):
            guard let value else { return .unavailable(.sourceUnavailable) }
            frame = value
        case .timedOut:
            return .unavailable(.deadlineExceeded)
        case .cancelled:
            return .unavailable(.cancelled)
        case .busy:
            return .unavailable(.priorRequestStillInFlight)
        }
        guard let data = jpeg(frame.image) else {
            return .unavailable(.sourceUnavailable)
        }
        let monotonicDurationMillis = Int64(
            ceil(max(0, frame.completedUptime - requestStartedUptime) * 1_000))
        let hash: UInt64
        if let samples = grayscaleSamples(frame.image, width: hashWidth, height: hashHeight) {
            hash = PerceptualHash.dHash(grayscale: samples, width: hashWidth, height: hashHeight)
        } else {
            hash = 0  // no hash → never matches a stored hash, so the frame is kept (not skipped)
        }
        return .captured(
            Shot(
                data: data,
                hash: hash,
                requestStartedAt: requestStartedAt,
                frameCompletedAt: frame.completedAt,
                monotonicDurationMillis: monotonicDurationMillis,
                scope: frame.scope))
    }

    /// Converts asynchronous acquisition into portable interval + scope evidence. A window-owner
    /// mismatch is rejected before bytes can enter the archive. Display fallback remains usable,
    /// but is explicitly partial rather than pretending to be an exact focused-window frame.
    static func assess(
        _ shot: Shot,
        expectedOwnerBundleID: String?
    ) -> EvidenceAssessment {
        let durationMillis = max(0, shot.monotonicDurationMillis)
        // Wall clocks can step backwards while ScreenCaptureKit is awaiting a frame. Anchor the
        // interval at the request wall time and derive its end from monotonic elapsed time.
        let normalizedFrameCompletedAt = shot.requestStartedAt.addingTimeInterval(
            Double(durationMillis) / 1_000)
        let normalizedFrameCompletedTimestamp = Timestamps.iso8601(
            normalizedFrameCompletedAt)
        let interval = JazzArchiveArtifactCaptureInterval(
            startedAt: Timestamps.iso8601(shot.requestStartedAt),
            endedAt: normalizedFrameCompletedTimestamp)
        var reasons = [JazzArchiveScreenshotEvidenceV1.temporalIntervalReason]
        let evidenceScope: JazzArchiveScreenshotEvidenceV1.Scope

        switch shot.scope {
        case .window(let ownerBundleID, let windowID):
            guard
                let expectedOwnerBundleID,
                let ownerBundleID,
                expectedOwnerBundleID == ownerBundleID
            else {
                return EvidenceAssessment(
                    accepted: false,
                    captureInterval: nil,
                    quality: JazzArchiveQuality(
                        status: .partial,
                        reasons: [JazzArchiveScreenshotEvidenceV1.ownerMismatchReason]),
                    extensions: nil)
            }
            evidenceScope = .window(
                ownerBundleId: ownerBundleID,
                windowId: Int64(windowID))
        case .display(let displayID, let excludedApplicationBundleIDs):
            evidenceScope = .display(
                displayId: Int64(displayID),
                excludedApplicationBundleIds: excludedApplicationBundleIDs)
            reasons.append(JazzArchiveScreenshotEvidenceV1.displayFallbackReason)
        }

        let evidence = JazzArchiveScreenshotEvidenceV1(
            requestStartedAt: interval.startedAt,
            frameCompletedAt: normalizedFrameCompletedTimestamp,
            monotonicDurationMillis: durationMillis,
            scope: evidenceScope)
        return EvidenceAssessment(
            accepted: true,
            captureInterval: interval,
            quality: JazzArchiveQuality(
                status: .partial,
                reasons: reasons,
                timingErrorMillis: Double(durationMillis)),
            extensions: evidence.extensions)
    }

    @MainActor
    private static func captureImage(
        bundleID: String?,
        targetRect: CGRect?,
        privacyDenylist: Set<String>,
        requireWindowAtTarget: Bool
    ) async -> CapturedFrame? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let filter: SCContentFilter
            let scope: Scope
            if let window = pickWindow(
                content.windows,
                bundleID: bundleID,
                targetRect: targetRect,
                requireTargetHit: requireWindowAtTarget)
            {
                filter = SCContentFilter(desktopIndependentWindow: window)
                scope = .window(
                    ownerBundleID: window.owningApplication?.bundleIdentifier,
                    windowID: window.windowID)
            } else {
                let displayGeometries = content.displays.map {
                    DisplayGeometry(displayID: $0.displayID, frame: $0.frame)
                }
                guard
                    let displayID = selectedDisplayID(
                        displayGeometries,
                        targetRect: targetRect),
                    let display = content.displays.first(where: {
                        $0.displayID == displayID
                    }),
                    let excludedBundleIDs = displayFallbackExcludedBundleIDs(
                        denylist: privacyDenylist,
                        runningBundleIDs: Set(
                            NSWorkspace.shared.runningApplications.compactMap(
                                \.bundleIdentifier)),
                        shareableBundleIDs: Set(
                            content.applications.map(\.bundleIdentifier)))
                else {
                    // A display frame can contain windows from every application. If every
                    // currently-running denylisted bundle cannot be represented in the SCK filter,
                    // no display fallback is safe enough to persist.
                    return nil
                }
                let excludedApplications = content.applications.filter {
                    excludedBundleIDs.contains($0.bundleIdentifier)
                }
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: excludedApplications,
                    exceptingWindows: [])
                scope = .display(
                    displayID: display.displayID,
                    excludedApplicationBundleIDs: excludedBundleIDs.sorted())
            }
            let config = SCStreamConfiguration()
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            return CapturedFrame(
                image: image,
                completedAt: Date(),
                completedUptime: ProcessInfo.processInfo.systemUptime,
                scope: scope)
        } catch {
            return nil
        }
    }

    /// Select the display containing the physical target's midpoint. For a target spanning a
    /// boundary, fall back to the greatest positive intersection. Only a missing location hint may
    /// use the provider's first display; an out-of-bounds hint fails closed.
    static func selectedDisplayID(
        _ displays: [DisplayGeometry],
        targetRect: CGRect?
    ) -> CGDirectDisplayID? {
        guard let targetRect else { return displays.first?.displayID }
        guard
            targetRect.width > 0,
            targetRect.height > 0,
            targetRect.origin.x.isFinite,
            targetRect.origin.y.isFinite,
            targetRect.width.isFinite,
            targetRect.height.isFinite
        else { return nil }

        let midpoint = CGPoint(x: targetRect.midX, y: targetRect.midY)
        let midpointHits = displays.filter { $0.frame.contains(midpoint) }
        if let displayID = midpointHits.map(\.displayID).min() {
            return displayID
        }
        return displays.compactMap { display -> (CGDirectDisplayID, CGFloat)? in
            let intersection = display.frame.intersection(targetRect)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            return (display.displayID, intersection.width * intersection.height)
        }
        .max(by: {
            if $0.1 == $1.1 {
                // Smaller stable display identity wins an exact geometry tie; provider order must
                // not change canonical screenshot scope or archive digests.
                return $0.0 > $1.0
            }
            return $0.1 < $1.1
        })?
        .0
    }

    /// Return every shareable denylisted application to exclude from a display capture. If a
    /// currently-running denied bundle has no shareable application representation, ScreenCaptureKit
    /// cannot prove that the display filter hides it and the caller must fail closed.
    static func displayFallbackExcludedBundleIDs(
        denylist: Set<String>,
        runningBundleIDs: Set<String>,
        shareableBundleIDs: Set<String>
    ) -> Set<String>? {
        let runningDenied = denylist.intersection(runningBundleIDs)
        let shareableDenied = denylist.intersection(shareableBundleIDs)
        guard runningDenied.isSubset(of: shareableDenied) else { return nil }
        return shareableDenied
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
        _ windows: [SCWindow],
        bundleID: String?,
        targetRect: CGRect?,
        requireTargetHit: Bool
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
            if requireTargetHit { return nil }
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
