import JazzCaptureCore

/// Sidebar-only projection; never changes canonical review or delivery state.
enum SessionStatusGroup: String, CaseIterable, Identifiable {
    // Actionable groups first, settled archives last.
    case open = "Open / recovering"
    case needsReview = "Needs review"
    case needsAttention = "Upload needs attention"
    case confirmed = "Confirmed · local only"
    case queued = "Waiting to upload"
    case retrying = "Waiting to retry"
    case uploading = "Uploading"
    case processing = "Uploaded · processing"
    case accepted = "Accepted by server"
    case rejectedLocally = "Rejected in review"
    case setAside = "Set aside in review"
    case rejectedByServer = "Rejected by server"
    case cancelled = "Upload cancelled"

    var id: Self { self }

    init(
        isCommitted: Bool,
        reviewDecision: JazzArchiveAssertionDecision?,
        uploadState: JazzArchiveUploadState?
    ) {
        // Delivery is authoritative for an existing immutable package, even if its local
        // summary has not reloaded yet. READY means ingest acceptance, not AI/human approval.
        if let uploadState {
            switch uploadState {
            case .queued: self = .queued
            case .retryable: self = .retrying
            case .creatingIntent, .uploading, .finalizing: self = .uploading
            case .verifying, .processing: self = .processing
            case .ready: self = .accepted
            case .rejected: self = .rejectedByServer
            case .reconnectRequired, .failedTerminal, .quarantined, .conflict:
                self = .needsAttention
            case .cancelled: self = .cancelled
            }
        } else if !isCommitted {
            // An uncommitted archive may be recording, closing, or awaiting crash recovery.
            self = .open
        } else {
            switch reviewDecision {
            case .confirm: self = .confirmed
            case .reject: self = .rejectedLocally
            case .exclude, .delete: self = .setAside
            default: self = .needsReview
            }
        }
    }
}
