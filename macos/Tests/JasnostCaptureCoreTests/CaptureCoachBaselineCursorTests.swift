import XCTest

@testable import JasnostCaptureCore

final class CaptureCoachBaselineCursorTests: XCTestCase {
    func testEachLabelOwnsFullBaselineAndReopenResumesOnlyThatLabel() {
        let templateCount = 7
        let firstLabel = Identifiers.newLabelId()
        let secondLabel = Identifiers.newLabelId()
        var cursor = CaptureCoachBaselineCursor()

        XCTAssertEqual(
            cursor.nextIndex(for: firstLabel, templateCount: templateCount),
            0)
        XCTAssertFalse(cursor.advance(
            labelId: firstLabel,
            issuedIndex: 0,
            templateCount: templateCount))
        XCTAssertEqual(
            cursor.nextIndex(for: firstLabel, templateCount: templateCount),
            1)

        // Closing the first label and opening another starts a complete independent baseline.
        XCTAssertEqual(
            cursor.nextIndex(for: secondLabel, templateCount: templateCount),
            0)
        XCTAssertFalse(cursor.advance(
            labelId: secondLabel,
            issuedIndex: 0,
            templateCount: templateCount))

        // Reopening the first logical label resumes its cursor and does not spend the second.
        XCTAssertEqual(
            cursor.nextIndex(for: firstLabel, templateCount: templateCount),
            1)
        XCTAssertEqual(
            cursor.nextIndex(for: secondLabel, templateCount: templateCount),
            1)

        for index in 1..<templateCount {
            _ = cursor.advance(
                labelId: firstLabel,
                issuedIndex: index,
                templateCount: templateCount)
        }
        XCTAssertNil(
            cursor.nextIndex(for: firstLabel, templateCount: templateCount))
        XCTAssertEqual(
            cursor.nextIndex(for: secondLabel, templateCount: templateCount),
            1)
    }

    func testCaptureResetRestoresEveryLabelToFirstSlot() {
        let labelId = Identifiers.newLabelId()
        var cursor = CaptureCoachBaselineCursor()
        _ = cursor.advance(labelId: labelId, issuedIndex: 0, templateCount: 7)

        cursor.resetCapture()

        XCTAssertEqual(cursor.nextIndex(for: labelId, templateCount: 7), 0)
    }
}
