import CoreGraphics
import Foundation
import XCTest

@testable import JasnostCapture
@testable import JasnostCaptureCore

@MainActor
final class ScreenCaptureEvidenceTests: XCTestCase {
    private actor Gate {
        private var open = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            open = true
            continuation?.resume()
            continuation = nil
        }
    }

    private actor PhysicalOperationProbe {
        private var active = 0
        private var maximumActive = 0
        private var starts = 0

        func begin() {
            active += 1
            starts += 1
            maximumActive = max(maximumActive, active)
        }

        func end() {
            active -= 1
        }

        func snapshot() -> (active: Int, maximumActive: Int, starts: Int) {
            (active, maximumActive, starts)
        }
    }

    func testFocusedAXTargetMustCoverClickBeforeReplacingAnonymousHitTest() {
        var anonymous = AXTargetInfo()
        anonymous.role = "AXGroup"
        anonymous.frame = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        var focused = AXTargetInfo()
        focused.role = "AXTextField"
        focused.label = "Invoice status"
        focused.frame = CGRect(x: 20, y: 20, width: 200, height: 40)

        XCTAssertFalse(
            Accessibility.shouldPreferFocusedTarget(
                focused,
                over: anonymous,
                atScreenPoint: CGPoint(x: 800, y: 600)))
        XCTAssertTrue(
            Accessibility.shouldPreferFocusedTarget(
                focused,
                over: anonymous,
                atScreenPoint: CGPoint(x: 100, y: 30)))
    }

    func testTimedOutPhysicalCaptureKeepsSingleSlotUntilActualLateReturn() async {
        let flight = ScreenCaptureSingleFlight()
        let physicalGate = Gate()
        let probe = PhysicalOperationProbe()
        let started = expectation(description: "one physical capture admitted")

        let first = Task {
            await flight.run(budgetNanoseconds: 20_000_000) {
                await probe.begin()
                started.fulfill()
                // Deliberately ignores cooperative cancellation, as a wedged SCK continuation may.
                await physicalGate.wait()
                await probe.end()
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 1)
        guard case .timedOut = await first.value else {
            return XCTFail("the admitted logical request must time out")
        }

        // These model hundreds of post-timeout interactions plus Stop/Quit callers. They must
        // return immediately without allocating another physical operation or IPC request.
        for index in 0..<500 {
            let result = await flight.run(budgetNanoseconds: 1_000_000) {
                await probe.begin()
                await probe.end()
                return index + 2
            }
            guard case .busy = result else {
                return XCTFail("attempt \(index) escaped the occupied physical slot")
            }
        }
        var flightSnapshot = await flight.snapshot()
        var probeSnapshot = await probe.snapshot()
        XCTAssertTrue(flightSnapshot.physicalOperationActive)
        XCTAssertEqual(flightSnapshot.admittedOperationCount, 1)
        XCTAssertEqual(probeSnapshot.active, 1)
        XCTAssertEqual(probeSnapshot.maximumActive, 1)
        XCTAssertEqual(probeSnapshot.starts, 1)

        // A real late OS return only re-opens the slot. It cannot revise the already-returned
        // timeout or deliver data into an old capture generation.
        await physicalGate.release()
        for _ in 0..<100 {
            if !(await flight.snapshot().physicalOperationActive) { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        flightSnapshot = await flight.snapshot()
        XCTAssertFalse(flightSnapshot.physicalOperationActive)

        let recovered = await flight.run(budgetNanoseconds: 100_000_000) {
            await probe.begin()
            await probe.end()
            return 501
        }
        guard case .value(let value) = recovered else {
            return XCTFail("late return did not safely re-open the physical slot")
        }
        XCTAssertEqual(value, 501)
        flightSnapshot = await flight.snapshot()
        probeSnapshot = await probe.snapshot()
        XCTAssertEqual(flightSnapshot.admittedOperationCount, 2)
        XCTAssertEqual(probeSnapshot.active, 0)
        XCTAssertEqual(probeSnapshot.maximumActive, 1)
        XCTAssertEqual(probeSnapshot.starts, 2)
    }

    func testDelayedAsyncFrameProducesHonestIntervalAndTimingUncertainty() async {
        let frameGate = Gate()
        let requestStarted = Date(timeIntervalSince1970: 200)
        let frameCompleted = Date(timeIntervalSince1970: 201.25)
        let physicalMouseUp = Date(timeIntervalSince1970: 199)
        let frameRequested = expectation(description: "frame request started")

        let assessment = PointerParallelEnrichment.begin(
            beginScreen: {
                Task {
                    frameRequested.fulfill()
                    await frameGate.wait()
                    return ScreenCapture.Shot(
                        data: Data([0xAA]),
                        hash: 0xA,
                        requestStartedAt: requestStarted,
                        frameCompletedAt: frameCompleted,
                        monotonicDurationMillis: 1_250,
                        scope: .window(
                            ownerBundleID: "com.example.a",
                            windowID: 17))
                }
            },
            beginAX: {
                Task { "com.example.a" }
            },
            combine: { shot, owner in
                ScreenCapture.assess(
                    shot,
                    expectedOwnerBundleID: owner)
            })

        await fulfillment(of: [frameRequested], timeout: 1)
        await frameGate.release()
        let result = await assessment.value

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(
            result.captureInterval?.startedAt,
            Timestamps.iso8601(requestStarted))
        XCTAssertEqual(
            result.captureInterval?.endedAt,
            Timestamps.iso8601(frameCompleted))
        XCTAssertNotEqual(
            result.captureInterval?.startedAt,
            Timestamps.iso8601(physicalMouseUp))
        XCTAssertEqual(result.quality.status, .partial)
        XCTAssertEqual(
            result.quality.reasons,
            [JazzArchiveScreenshotEvidenceV1.temporalIntervalReason])
        XCTAssertEqual(result.quality.timingErrorMillis, 1_250)
        XCTAssertEqual(
            result.extensions?[JazzArchiveScreenshotEvidenceV1.scopeKey],
            .string("window"))
        XCTAssertEqual(
            result.extensions?[JazzArchiveScreenshotEvidenceV1.ownerBundleIdKey],
            .string("com.example.a"))
    }

    func testWindowOwnerMismatchRejectsBytesBeforeArchivePersistence() {
        let shot = ScreenCapture.Shot(
            data: Data([0xAB]),
            hash: 0xB,
            requestStartedAt: Date(timeIntervalSince1970: 300),
            frameCompletedAt: Date(timeIntervalSince1970: 301),
            monotonicDurationMillis: 1_000,
            scope: .window(
                ownerBundleID: "com.example.window-a",
                windowID: 18))

        let result = ScreenCapture.assess(
            shot,
            expectedOwnerBundleID: "com.example.ax-owner-b")

        XCTAssertFalse(result.accepted)
        XCTAssertNil(result.captureInterval)
        XCTAssertNil(result.extensions)
        XCTAssertEqual(result.quality.status, .partial)
        XCTAssertEqual(
            result.quality.reasons,
            [JazzArchiveScreenshotEvidenceV1.ownerMismatchReason])
    }

    func testDisplayFallbackIsExplicitlyPartialAndScoped() {
        let shot = ScreenCapture.Shot(
            data: Data([0xAC]),
            hash: 0xC,
            requestStartedAt: Date(timeIntervalSince1970: 400),
            frameCompletedAt: Date(timeIntervalSince1970: 400.5),
            monotonicDurationMillis: 500,
            scope: .display(
                displayID: 7,
                excludedApplicationBundleIDs: [
                    "com.example.password-manager"
                ]))

        let result = ScreenCapture.assess(
            shot,
            expectedOwnerBundleID: "com.example.a")

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.quality.status, .partial)
        XCTAssertEqual(
            result.quality.reasons,
            [
                JazzArchiveScreenshotEvidenceV1.temporalIntervalReason,
                JazzArchiveScreenshotEvidenceV1.displayFallbackReason,
            ])
        XCTAssertEqual(result.quality.timingErrorMillis, 500)
        XCTAssertEqual(
            result.extensions?[JazzArchiveScreenshotEvidenceV1.scopeKey],
            .string("display"))
        XCTAssertEqual(
            result.extensions?[JazzArchiveScreenshotEvidenceV1.displayIdKey],
            .integer(7))
        XCTAssertEqual(
            result.extensions?[
                JazzArchiveScreenshotEvidenceV1.excludedApplicationBundleIdsKey
            ],
            .array([.string("com.example.password-manager")]))
    }

    func testClockStepBackUsesMonotonicDurationForNonReversedInterval() {
        let requestStarted = Date(timeIntervalSince1970: 500)
        let rawWallCompletionAfterStepBack = Date(timeIntervalSince1970: 490)
        let result = ScreenCapture.assess(
            ScreenCapture.Shot(
                data: Data([0xAD]),
                hash: 0xD,
                requestStartedAt: requestStarted,
                frameCompletedAt: rawWallCompletionAfterStepBack,
                monotonicDurationMillis: 750,
                scope: .window(
                    ownerBundleID: "com.example.a",
                    windowID: 19)),
            expectedOwnerBundleID: "com.example.a")

        XCTAssertEqual(
            result.captureInterval?.startedAt,
            Timestamps.iso8601(requestStarted))
        XCTAssertEqual(
            result.captureInterval?.endedAt,
            Timestamps.iso8601(
                requestStarted.addingTimeInterval(0.75)))
        XCTAssertGreaterThanOrEqual(
            Timestamps.parse(result.captureInterval?.endedAt)!,
            Timestamps.parse(result.captureInterval?.startedAt)!)
        XCTAssertEqual(result.quality.timingErrorMillis, 750)
    }

    func testPhysicalTargetChoosesItsDisplayInsteadOfProviderFirst() {
        let displays = [
            ScreenCapture.DisplayGeometry(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)),
            ScreenCapture.DisplayGeometry(
                displayID: 2,
                frame: CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440)),
        ]

        XCTAssertEqual(
            ScreenCapture.selectedDisplayID(
                displays,
                targetRect: CGRect(x: 2_400, y: 300, width: 20, height: 20)),
            2)
        XCTAssertEqual(ScreenCapture.selectedDisplayID(displays, targetRect: nil), 1)
        XCTAssertNil(
            ScreenCapture.selectedDisplayID(
                displays,
                targetRect: CGRect(x: 10_000, y: 10_000, width: 20, height: 20)))
    }

    func testSpanningTargetUsesGreatestDisplayIntersection() {
        let displays = [
            ScreenCapture.DisplayGeometry(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            ScreenCapture.DisplayGeometry(
                displayID: 2,
                frame: CGRect(x: 200, y: 0, width: 100, height: 100)),
        ]
        // Midpoint is outside both displays, so display 2 wins by positive intersection area.
        XCTAssertEqual(
            ScreenCapture.selectedDisplayID(
                displays,
                targetRect: CGRect(x: 90, y: -20, width: 150, height: 40)),
            2)
    }

    func testEqualDisplayIntersectionUsesSmallestStableDisplayID() {
        let displays = [
            ScreenCapture.DisplayGeometry(
                displayID: 9,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            ScreenCapture.DisplayGeometry(
                displayID: 3,
                frame: CGRect(x: 200, y: 0, width: 100, height: 100)),
        ]
        let target = CGRect(x: 50, y: -20, width: 200, height: 40)

        XCTAssertEqual(
            ScreenCapture.selectedDisplayID(displays, targetRect: target),
            3)
        XCTAssertEqual(
            ScreenCapture.selectedDisplayID(Array(displays.reversed()), targetRect: target),
            3)
    }

    func testOverlappingMidpointUsesSmallestStableDisplayID() {
        let displays = [
            ScreenCapture.DisplayGeometry(
                displayID: 9,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            ScreenCapture.DisplayGeometry(
                displayID: 3,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
        ]
        let target = CGRect(x: 40, y: 40, width: 20, height: 20)

        XCTAssertEqual(
            ScreenCapture.selectedDisplayID(displays, targetRect: target),
            3)
        XCTAssertEqual(
            ScreenCapture.selectedDisplayID(Array(displays.reversed()), targetRect: target),
            3)
    }

    func testRightClickWithoutAXStillTargetsItsPhysicalDisplay() {
        let displays = [
            ScreenCapture.DisplayGeometry(
                displayID: 2,
                frame: CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080)),
            ScreenCapture.DisplayGeometry(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)),
        ]
        let hint = CaptureController.screenshotTargetHint(
            kind: .rightClick,
            location: CGPoint(x: 2_400, y: 300),
            dragEnd: nil,
            axFrame: nil)

        XCTAssertTrue(hint.requireWindowAtTarget)
        XCTAssertEqual(
            ScreenCapture.selectedDisplayID(displays, targetRect: hint.rect),
            2)
    }

    func testClipboardWithoutAXDoesNotPretendCursorIsTheFocusedTarget() {
        let hint = CaptureController.screenshotTargetHint(
            kind: .paste,
            location: CGPoint(x: 2_400, y: 300),
            dragEnd: nil,
            axFrame: nil)

        XCTAssertNil(hint.rect)
        XCTAssertFalse(hint.requireWindowAtTarget)
    }

    func testCrossDisplayDragScreenshotTargetsReleaseWhileAXCanDescribeSource() {
        let displays = [
            ScreenCapture.DisplayGeometry(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)),
            ScreenCapture.DisplayGeometry(
                displayID: 2,
                frame: CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080)),
        ]
        let sourceAXFrame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let hint = CaptureController.screenshotTargetHint(
            kind: .drag,
            location: CGPoint(x: 200, y: 200),
            dragEnd: CGPoint(x: 2_400, y: 300),
            axFrame: sourceAXFrame)

        XCTAssertNotEqual(hint.rect, sourceAXFrame)
        XCTAssertTrue(hint.requireWindowAtTarget)
        XCTAssertEqual(
            ScreenCapture.selectedDisplayID(
                Array(displays.reversed()),
                targetRect: hint.rect),
            2)
    }

    func testPreliminaryDeniedActualAllowedFallbackExcludesSensitiveForegroundApp() {
        let denied = "com.example.password-manager"
        let allowed = "com.example.finance"
        let exclusions = ScreenCapture.displayFallbackExcludedBundleIDs(
            denylist: [denied],
            runningBundleIDs: [denied, allowed],
            shareableBundleIDs: [denied, allowed])

        XCTAssertEqual(exclusions, [denied])
        XCTAssertNil(
            ScreenCapture.displayFallbackExcludedBundleIDs(
                denylist: [denied],
                runningBundleIDs: [denied, allowed],
                // If SCK cannot represent the sensitive foreground app, display fallback must
                // fail closed even though AX authorized the other app.
                shareableBundleIDs: [allowed]))
    }
}
