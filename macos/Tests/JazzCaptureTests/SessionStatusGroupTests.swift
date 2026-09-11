import JazzCaptureCore
import XCTest

@testable import JazzCapture

final class SessionStatusGroupTests: XCTestCase {
    func testEveryDeliveryStateHasAnHonestGroupAndOverridesStaleLocalReview() {
        let expected: [JazzArchiveUploadState: SessionStatusGroup] = [
            .queued: .queued, .retryable: .retrying,
            .creatingIntent: .uploading, .uploading: .uploading, .finalizing: .uploading,
            .verifying: .processing, .processing: .processing,
            .ready: .accepted, .rejected: .rejectedByServer,
            .reconnectRequired: .needsAttention, .failedTerminal: .needsAttention,
            .quarantined: .needsAttention, .conflict: .needsAttention,
            .cancelled: .cancelled,
        ]
        XCTAssertEqual(Set(expected.keys), Set(JazzArchiveUploadState.allCases))
        for state in JazzArchiveUploadState.allCases {
            XCTAssertEqual(
                SessionStatusGroup(
                    isCommitted: false, reviewDecision: .reject, uploadState: state),
                expected[state], "\(state)")
        }
    }

    func testLocalConfirmationIsNotServerAcceptanceAndCorrectionsNeedReview() {
        let expected: [(JazzArchiveAssertionDecision?, SessionStatusGroup)] = [
            (nil, .needsReview), (.confirm, .confirmed), (.correct, .needsReview),
            (.reject, .rejectedLocally), (.exclude, .setAside),
            (.delete, .setAside), (.split, .needsReview),
            (.merge, .needsReview), (.redact, .needsReview),
        ]
        for (decision, group) in expected {
            XCTAssertEqual(
                SessionStatusGroup(
                    isCommitted: true, reviewDecision: decision, uploadState: nil), group)
            XCTAssertEqual(
                SessionStatusGroup(
                    isCommitted: false, reviewDecision: decision, uploadState: nil), .open)
        }
    }
}
