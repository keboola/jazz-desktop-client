@testable import JasnostCaptureCore

/// Builds a zero-duration, window-scoped screenshot profile for tests whose concern is the
/// surrounding archive lifecycle rather than capture timing. Keeping these fixtures contract-valid
/// prevents them from relying on the legacy profileless screenshot shape.
func testScreenshotEvidence(
    at timestamp: String,
    ownerBundleId: String = "com.example.test-fixture",
    windowId: Int64 = 1
) -> JazzArchiveScreenshotEvidenceV1 {
    JazzArchiveScreenshotEvidenceV1(
        requestStartedAt: timestamp,
        frameCompletedAt: timestamp,
        monotonicDurationMillis: 0,
        scope: .window(
            ownerBundleId: ownerBundleId,
            windowId: windowId))
}

func testScreenshotCaptureInterval(
    at timestamp: String
) -> JazzArchiveArtifactCaptureInterval {
    JazzArchiveArtifactCaptureInterval(
        startedAt: timestamp,
        endedAt: timestamp)
}

func testScreenshotQuality() -> JazzArchiveQuality {
    JazzArchiveQuality(
        status: .partial,
        reasons: [JazzArchiveScreenshotEvidenceV1.temporalIntervalReason],
        timingErrorMillis: 0)
}
