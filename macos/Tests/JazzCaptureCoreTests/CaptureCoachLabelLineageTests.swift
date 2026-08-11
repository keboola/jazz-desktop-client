import XCTest

@testable import JazzCaptureCore

final class CaptureCoachLabelLineageTests: XCTestCase {
    func testReopeningCreatesNewSegmentButResumesTheFirstBaseline() {
        var lineage = CaptureCoachLabelLineage()

        let firstA = lineage.open(
            labelId: "l-aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa",
            semanticKey: "process:invoice")
        let firstB = lineage.open(
            labelId: "l-bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb",
            semanticKey: "process:payment")
        let resumedA = lineage.open(
            labelId: "l-cccccccc-cccc-7ccc-8ccc-cccccccccccc",
            semanticKey: "process:invoice")

        XCTAssertEqual(
            firstA,
            CaptureCoachLabelLineageBinding(
                baselineId: "l-aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"))
        XCTAssertEqual(
            firstB,
            CaptureCoachLabelLineageBinding(
                baselineId: "l-bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb"))
        XCTAssertEqual(
            resumedA,
            CaptureCoachLabelLineageBinding(
                baselineId: "l-aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa",
                resumesLabelId: "l-aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"))
    }

    func testFreeTextIdentityIsExactAfterWhitespaceCaseAndDiacriticNormalization() {
        XCTAssertEqual(
            CaptureCoachLabelLineage.semanticKey(
                processId: nil,
                declaredText: "  Měsíční   Faktury "),
            CaptureCoachLabelLineage.semanticKey(
                processId: nil,
                declaredText: "mesicni faktury"))
        XCTAssertNotEqual(
            CaptureCoachLabelLineage.semanticKey(
                processId: nil,
                declaredText: "monthly invoice"),
            CaptureCoachLabelLineage.semanticKey(
                processId: nil,
                declaredText: "monthly invoices"))
    }

    func testResetPreventsCrossCaptureLineage() {
        var lineage = CaptureCoachLabelLineage()
        _ = lineage.open(labelId: "segment-a", semanticKey: "process:invoice")

        lineage.resetCapture()
        let newCapture = lineage.open(
            labelId: "segment-b",
            semanticKey: "process:invoice")

        XCTAssertEqual(
            newCapture,
            CaptureCoachLabelLineageBinding(baselineId: "segment-b"))
    }

    func testBaselineCursorRemainsIndependentAcrossResumedLineages() {
        var lineage = CaptureCoachLabelLineage()
        var cursor = CaptureCoachBaselineCursor()
        let a1 = lineage.open(labelId: "a-1", semanticKey: "process:a")
        let b1 = lineage.open(labelId: "b-1", semanticKey: "process:b")
        XCTAssertFalse(
            cursor.advance(
                labelId: a1.baselineId,
                issuedIndex: 0,
                templateCount: 7))
        XCTAssertFalse(
            cursor.advance(
                labelId: b1.baselineId,
                issuedIndex: 0,
                templateCount: 7))

        let a2 = lineage.open(labelId: "a-2", semanticKey: "process:a")

        XCTAssertEqual(cursor.nextIndex(for: a2.baselineId, templateCount: 7), 1)
        XCTAssertEqual(cursor.nextIndex(for: b1.baselineId, templateCount: 7), 1)
    }
}
