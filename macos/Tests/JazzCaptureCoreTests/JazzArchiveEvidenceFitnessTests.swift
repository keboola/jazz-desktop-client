import XCTest

@testable import JazzCaptureCore

final class JazzArchiveEvidenceFitnessTests: XCTestCase {
    func testPromisedScreenshotsWithPointerEvidenceAndNoImagesBlockConfirmation() {
        let fitness = JazzArchiveEvidenceFitness(
            screenshotsExpected: true,
            pointerEventCount: 12,
            semanticallyAnchoredPointerEventCount: 0,
            screenshotArtifactCount: 0)

        XCTAssertTrue(fitness.blocksConfirmation)
        XCTAssertTrue(fitness.blockerMessage?.contains("12 pointer interactions") == true)
        XCTAssertNil(fitness.warningMessage)
    }

    func testVisualEvidenceMakesSemanticTargetGapAdvisory() {
        let fitness = JazzArchiveEvidenceFitness(
            screenshotsExpected: true,
            pointerEventCount: 12,
            semanticallyAnchoredPointerEventCount: 0,
            screenshotArtifactCount: 3)

        XCTAssertFalse(fitness.blocksConfirmation)
        XCTAssertNil(fitness.blockerMessage)
        XCTAssertTrue(fitness.warningMessage?.contains("3 saved screenshots") == true)
    }

    func testNamedTargetsAndScreenshotsAreReadyForReview() {
        let fitness = JazzArchiveEvidenceFitness(
            screenshotsExpected: true,
            pointerEventCount: 12,
            semanticallyAnchoredPointerEventCount: 9,
            screenshotArtifactCount: 3)

        XCTAssertFalse(fitness.blocksConfirmation)
        XCTAssertNil(fitness.blockerMessage)
        XCTAssertNil(fitness.warningMessage)
    }
}
