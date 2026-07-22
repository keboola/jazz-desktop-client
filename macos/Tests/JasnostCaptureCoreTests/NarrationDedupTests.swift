import XCTest

@testable import JasnostCaptureCore

/// Tests for the pure narration-dedup decision (which complete copy to reuse, which dangling
/// records to delete). This is the idempotence guard against the duplicate/dangling-record bug.
final class NarrationDedupTests: XCTestCase {
    private func candidate(_ id: Int, _ present: Bool?) -> NarrationDedup.Candidate {
        NarrationDedup.Candidate(fileId: id, present: present)
    }

    func testNoCandidatesMeansFreshUpload() {
        let d = NarrationDedup.decide([])
        XCTAssertNil(d.reuseFileId)
        XCTAssertTrue(d.danglingToDelete.isEmpty)
    }

    func testReusesTheOnlyCompleteCopy() {
        let d = NarrationDedup.decide([candidate(42, true)])
        XCTAssertEqual(d.reuseFileId, 42)
        XCTAssertTrue(d.danglingToDelete.isEmpty)
    }

    func testDeletesDanglingAndDoesNotReuseWhenNoneComplete() {
        // The exact bug scenario: 4 dangling prepare-only records, no bytes anywhere.
        let d = NarrationDedup.decide([
            candidate(85269008, false), candidate(85269044, false),
            candidate(85269082, false), candidate(85269171, false),
        ])
        XCTAssertNil(d.reuseFileId)  // nothing complete → caller does a fresh upload
        XCTAssertEqual(d.danglingToDelete, [85269008, 85269044, 85269082, 85269171])
    }

    func testReusesFirstCompleteAndCleansDanglingMix() {
        // Earlier attempts left dangling records; a later one completed. Reuse the complete one,
        // clean up the empties.
        let d = NarrationDedup.decide([
            candidate(1, false), candidate(2, true), candidate(3, false),
        ])
        XCTAssertEqual(d.reuseFileId, 2)
        XCTAssertEqual(d.danglingToDelete, [1, 3])
    }

    func testFirstCompleteWinsAndSurplusCompleteIsLeftUntouched() {
        // Two complete copies: reuse the first (oldest-first input), but do NOT delete the
        // surplus complete one — deleting a record that has real bytes is destructive.
        let d = NarrationDedup.decide([candidate(10, true), candidate(11, true)])
        XCTAssertEqual(d.reuseFileId, 10)
        XCTAssertTrue(d.danglingToDelete.isEmpty)
    }

    func testUncertainCandidatesAreNeitherReusedNorDeleted() {
        // nil = HEAD was inconclusive (network/5xx): never act on a guess.
        let d = NarrationDedup.decide([candidate(7, nil), candidate(8, nil)])
        XCTAssertNil(d.reuseFileId)
        XCTAssertTrue(d.danglingToDelete.isEmpty)
    }

    func testUncertainAmongDanglingStillCleansOnlyTheKnownEmpties() {
        let d = NarrationDedup.decide([
            candidate(1, nil), candidate(2, false), candidate(3, true),
        ])
        XCTAssertEqual(d.reuseFileId, 3)
        XCTAssertEqual(d.danglingToDelete, [2])  // the nil is left alone
    }
}
