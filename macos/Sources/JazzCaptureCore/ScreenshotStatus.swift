import Foundation

/// The closed `screenshot.status` vocabulary: why an exported record has, or lacks, a
/// `screenshot_id`. Mirrors `screenshotStatuses` in `contract/identifiers.json` (pinned by
/// `IdentifierParityTests`). A value names a cause only — never a path, title, identity or error.
///
/// macOS currently emits only `captured`, `not_attempted` and `unknown`, derived in the OTLP mapper
/// (see `OtlpMapper.screenshotStatus(for:)`); the remaining cases are produced by the Windows client
/// and are listed so both clients share one vocabulary.
public enum ScreenshotStatus: String, CaseIterable, Sendable {
    case captured
    case deliveryNotConfigured = "delivery_not_configured"
    case deliveryPrepareFailed = "delivery_prepare_failed"
    case notAttempted = "not_attempted"
    case disabled
    case busy
    case timeout
    case noWindowAtTarget = "no_window_at_target"
    case ownerMismatch = "owner_mismatch"
    case sourceUnavailable = "source_unavailable"
    case evidenceRejected = "evidence_rejected"
    case unknown
}
