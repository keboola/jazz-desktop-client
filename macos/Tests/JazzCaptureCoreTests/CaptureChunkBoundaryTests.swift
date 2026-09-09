import Foundation
import XCTest
@testable import JazzCaptureCore

final class CaptureChunkBoundaryTests: XCTestCase {
    func testEqualityAndMonotonicWallJumpSeparation() throws {
        let policy = try CaptureChunkBoundary()
        let bytes = policy.targetBytes - CaptureChunkBoundary.closeHeadroomBytes
        XCTAssertNil(policy.reason(started: 100, now: 1_899, measuredBytes: bytes - 1, pendingBytes: 0))
        XCTAssertEqual(policy.reason(started: 100, now: 1_900, measuredBytes: 0, pendingBytes: 0), .duration)
        XCTAssertEqual(policy.reason(started: 100, now: 100, measuredBytes: bytes - 7, pendingBytes: 7), .bytes)
        // UTC jumps are deliberately absent from the production decision API.
        for wall in [Date.distantPast, Date.distantFuture] {
            XCTAssertNotNil(Timestamps.iso8601(wall))
            XCTAssertNil(policy.reason(started: 100, now: 101, measuredBytes: 0, pendingBytes: 0))
        }
        XCTAssertEqual(policy.reason(started: 100, now: 99, measuredBytes: 0, pendingBytes: 0), .unknown)
        // A long elapsed interval yields one decision, not a backlog of missed chunks.
        XCTAssertEqual(policy.reason(started: 100, now: 1_000_000, measuredBytes: 0, pendingBytes: 0), .duration)
        XCTAssertNil(policy.reason(started: 1_000_000, now: 1_000_001, measuredBytes: 0, pendingBytes: 0))
    }

    func testValidatedBoundsUnknownBytesAndOverflowFailClosed() throws {
        for duration in [0, 59, 1_801, .infinity, .nan] {
            XCTAssertThrowsError(try CaptureChunkBoundary(duration: duration))
        }
        for bytes: Int64 in [-1, 0, 32 * 1024 * 1024 - 1, 250 * 1024 * 1024 + 1, .max] {
            XCTAssertThrowsError(try CaptureChunkBoundary(targetBytes: bytes))
        }
        _ = try CaptureChunkBoundary(duration: 60, targetBytes: 32 * 1024 * 1024)
        let policy = try CaptureChunkBoundary()
        for bytes: Int64? in [nil, -1, .max] {
            XCTAssertEqual(policy.reason(started: 0, now: 1, measuredBytes: bytes, pendingBytes: 1), .unknown)
            XCTAssertEqual(policy.reason(started: 0, now: 1, measuredBytes: 1, pendingBytes: bytes), .unknown)
        }
        XCTAssertEqual(policy.reason(started: 0, now: .nan, measuredBytes: 0, pendingBytes: 0), .unknown)
    }

    func testWriteBudgetCountsPendingCopiesAndRetainsUnknown() {
        let bytes = CaptureChunkBytes()
        bytes.add(10, copies: 3)
        bytes.add(20)
        XCTAssertEqual(bytes.measured, 50)
        bytes.add(.max, copies: 2)
        XCTAssertNil(bytes.measured)
        bytes.add(0)
        XCTAssertNil(bytes.measured)
        let unknown = CaptureChunkBytes()
        unknown.add(-1)
        XCTAssertNil(unknown.measured)
    }

    func testLabeledNarratedWorkshopOrUnknownBoundaryRequiresExplicitRestart() {
        for reason in [CaptureChunkBoundary.Reason.bytes, .duration, .unknown] {
            XCTAssertFalse(CaptureChunkBoundary.permitsContinuation(reason: reason, hasOpenSpan: true))
            XCTAssertEqual(CaptureChunkBoundary.permitsContinuation(reason: reason, hasOpenSpan: false), reason != .unknown)
        }
    }
}
