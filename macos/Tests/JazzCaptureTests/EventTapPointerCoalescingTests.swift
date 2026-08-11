import CoreGraphics
import Foundation
import XCTest

@testable import JazzCapture

@MainActor
final class EventTapPointerCoalescingTests: XCTestCase {
    func testPhysicalOneThenTwoStartsTwoSamplesAndResolvesExactlyOneDoubleClick() {
        let tap = EventTap(doubleClickInterval: 0.03)
        var samples: [EventTap.PointerSample] = []
        var resolutions: [EventTap.PointerResolution] = []
        let delivered = expectation(description: "coalesced double click")
        tap.onPointerSample = { samples.append($0) }
        tap.onPointerResolution = {
            resolutions.append($0)
            delivered.fulfill()
        }

        tap.handle(
            type: .leftMouseDown,
            event: mouseEvent(type: .leftMouseDown, clickCount: 1))
        tap.handle(
            type: .leftMouseUp,
            event: mouseEvent(type: .leftMouseUp, clickCount: 1))
        XCTAssertEqual(samples.count, 1)
        XCTAssertTrue(resolutions.isEmpty)

        tap.handle(
            type: .leftMouseDown,
            event: mouseEvent(type: .leftMouseDown, clickCount: 2))
        tap.handle(
            type: .leftMouseUp,
            event: mouseEvent(type: .leftMouseUp, clickCount: 2))
        XCTAssertEqual(samples.count, 2)
        XCTAssertNotEqual(samples[0].sampleId, samples[1].sampleId)
        XCTAssertEqual(samples[0].gestureId, samples[1].gestureId)
        XCTAssertTrue(resolutions.isEmpty)

        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions[0].kind, .click)
        XCTAssertEqual(resolutions[0].clickCount, 2)
        XCTAssertEqual(resolutions[0].sampleId, samples[1].sampleId)
        XCTAssertEqual(resolutions[0].gestureId, samples[0].gestureId)
        tap.stop()
        XCTAssertEqual(resolutions.count, 1)
    }

    func testSingleSampleStartsImmediatelyAndResolutionRetainsPhysicalCompletionTime() {
        let tap = EventTap(doubleClickInterval: 0.03)
        var sample: EventTap.PointerSample?
        var resolution: EventTap.PointerResolution?
        var sampleDeliveredAt: Date?
        var resolutionDeliveredAt: Date?
        let delivered = expectation(description: "single click timeout")
        tap.onPointerSample = {
            sample = $0
            sampleDeliveredAt = Date()
        }
        tap.onPointerResolution = {
            resolution = $0
            resolutionDeliveredAt = Date()
            delivered.fulfill()
        }

        tap.handle(
            type: .leftMouseDown,
            event: mouseEvent(type: .leftMouseDown, clickCount: 1))
        tap.handle(
            type: .leftMouseUp,
            event: mouseEvent(type: .leftMouseUp, clickCount: 1))

        let immediateSample = try? XCTUnwrap(sample)
        XCTAssertNotNil(immediateSample)
        XCTAssertNil(resolution)
        XCTAssertLessThan(
            sampleDeliveredAt?.timeIntervalSince(immediateSample?.occurredAt ?? Date()) ?? 1,
            0.02)

        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(resolution?.sampleId, immediateSample?.sampleId)
        XCTAssertEqual(resolution?.occurredAt, immediateSample?.occurredAt)
        XCTAssertGreaterThanOrEqual(
            resolutionDeliveredAt?.timeIntervalSince(resolution?.occurredAt ?? Date()) ?? -1,
            0.015)
        tap.stop()
    }

    func testOrphanCountTwoWithoutObservedPrefixResolvesAsSingle() {
        let tap = EventTap(doubleClickInterval: 0.02)
        var samples: [EventTap.PointerSample] = []
        var resolutions: [EventTap.PointerResolution] = []
        let delivered = expectation(description: "honest orphan click")
        tap.onPointerSample = { samples.append($0) }
        tap.onPointerResolution = {
            resolutions.append($0)
            delivered.fulfill()
        }

        tap.handle(
            type: .leftMouseDown,
            event: mouseEvent(type: .leftMouseDown, clickCount: 2))
        tap.handle(
            type: .leftMouseUp,
            event: mouseEvent(type: .leftMouseUp, clickCount: 2))

        XCTAssertEqual(samples.map(\.clickCount), [1])
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(resolutions.map(\.clickCount), [1])
        tap.stop()
    }

    func testIndependentInputResolvesClickBeforePublishingThatInput() {
        let tap = EventTap(doubleClickInterval: 1)
        var order: [String] = []
        tap.onPointerSample = { _ in order.append("sample") }
        tap.onPointerResolution = { _ in order.append("resolution") }
        tap.onEvent = { order.append($0.kind == .rightClick ? "right" : "other") }

        tap.handle(
            type: .leftMouseDown,
            event: mouseEvent(type: .leftMouseDown, clickCount: 1))
        tap.handle(
            type: .leftMouseUp,
            event: mouseEvent(type: .leftMouseUp, clickCount: 1))
        tap.handle(
            type: .rightMouseDown,
            event: mouseEvent(type: .rightMouseDown, clickCount: 1))

        XCTAssertEqual(order, ["sample", "resolution", "right"])
        tap.stop()
    }

    func testExplicitBoundaryResolvesOnceWithoutStoppingFutureCapture() {
        let tap = EventTap(doubleClickInterval: 10)
        var samples: [EventTap.PointerSample] = []
        var resolutions: [EventTap.PointerResolution] = []
        tap.onPointerSample = { samples.append($0) }
        tap.onPointerResolution = { resolutions.append($0) }

        tap.handle(
            type: .leftMouseDown,
            event: mouseEvent(type: .leftMouseDown, clickCount: 1))
        tap.handle(
            type: .leftMouseUp,
            event: mouseEvent(type: .leftMouseUp, clickCount: 1))
        tap.flushPendingPointerGesture()
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(resolutions.map(\.clickCount), [1])

        tap.handle(
            type: .leftMouseDown,
            event: mouseEvent(type: .leftMouseDown, clickCount: 1))
        tap.handle(
            type: .leftMouseUp,
            event: mouseEvent(type: .leftMouseUp, clickCount: 1))
        tap.stop()
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(resolutions.map(\.clickCount), [1, 1])
    }

    func testDragStartsSampleAndResolvesImmediatelyWithoutTimerDuplicate() {
        let tap = EventTap(doubleClickInterval: 0.02)
        var order: [String] = []
        var sample: EventTap.PointerSample?
        var resolution: EventTap.PointerResolution?
        tap.onPointerSample = {
            sample = $0
            order.append("sample")
        }
        tap.onPointerResolution = {
            resolution = $0
            order.append("resolution")
        }

        tap.handle(
            type: .leftMouseDown,
            event: mouseEvent(
                type: .leftMouseDown, clickCount: 1,
                location: CGPoint(x: 10, y: 20)))
        tap.handle(
            type: .leftMouseDragged,
            event: mouseEvent(
                type: .leftMouseDragged, clickCount: 1,
                location: CGPoint(x: 20, y: 30)))
        tap.handle(
            type: .leftMouseUp,
            event: mouseEvent(
                type: .leftMouseUp, clickCount: 1,
                location: CGPoint(x: 40, y: 50)))

        XCTAssertEqual(order, ["sample", "resolution"])
        XCTAssertEqual(sample?.kind, .drag)
        XCTAssertEqual(sample?.location, CGPoint(x: 10, y: 20))
        XCTAssertEqual(sample?.dragEnd, CGPoint(x: 40, y: 50))
        XCTAssertEqual(resolution?.sampleId, sample?.sampleId)

        let noDuplicate = expectation(description: "no delayed pointer resolution")
        noDuplicate.isInverted = true
        tap.onPointerResolution = { _ in noDuplicate.fulfill() }
        wait(for: [noDuplicate], timeout: 0.08)
        tap.stop()
    }

    func testStopSynchronouslyResolvesCompletedSingleExactlyOnce() {
        let tap = EventTap(doubleClickInterval: 10)
        var samples: [EventTap.PointerSample] = []
        var resolutions: [EventTap.PointerResolution] = []
        tap.onPointerSample = { samples.append($0) }
        tap.onPointerResolution = { resolutions.append($0) }

        tap.handle(
            type: .leftMouseDown,
            event: mouseEvent(type: .leftMouseDown, clickCount: 1))
        tap.handle(
            type: .leftMouseUp,
            event: mouseEvent(type: .leftMouseUp, clickCount: 1))
        XCTAssertEqual(samples.count, 1)
        XCTAssertTrue(resolutions.isEmpty)

        tap.stop()
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions[0].sampleId, samples[0].sampleId)
        tap.stop()
        XCTAssertEqual(resolutions.count, 1)
    }

    private func mouseEvent(
        type: CGEventType,
        clickCount: Int,
        location: CGPoint = CGPoint(x: 100, y: 200)
    ) -> CGEvent {
        let button: CGMouseButton = type == .rightMouseDown ? .right : .left
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: button)!
        event.setIntegerValueField(
            .mouseEventClickState,
            value: Int64(clickCount))
        return event
    }
}

@MainActor
final class PointerEnrichmentCoordinatorTests: XCTestCase {
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private struct Root: Sendable {
        var sequence: Int
    }

    private struct Context: Sendable {
        var app: String
        var label: String
    }

    private struct Snapshot: Sendable, Equatable {
        var app: String
        var ax: String
        var screenshotBytes: Data
        var screenshotHash: UInt64
    }

    private struct Output: Sendable, Equatable {
        var sequence: Int
        var sampleId: String
        var gestureId: String
        var clickCount: Int
        var timestamp: Date
        var label: String
        var snapshot: Snapshot
    }

    private final class State: @unchecked Sendable {
        var ui = Snapshot(
            app: "A",
            ax: "button-A",
            screenshotBytes: Data([0x41]),
            screenshotHash: 0xA)
        var beginCalls: [String] = []
        var callOrder: [String] = []
        var admissions = 0
        var finalizations = 0
        var admitted: Task<Output, Never>?
    }

    func testScreenRequestStartsBeforeBlockedAXWithoutClaimingMouseUpPixels() async {
        let state = State()
        let axGate = Gate()
        let frameGate = Gate()
        let screenStarted = expectation(description: "async screen request started")
        var requestedApp: String?

        let enrichment = PointerParallelEnrichment.begin(
            beginScreen: {
                requestedApp = state.ui.app
                state.callOrder.append("screen-request-\(state.ui.app)")
                return Task {
                    screenStarted.fulfill()
                    await frameGate.wait()
                    // Like ScreenCaptureKit, completion is asynchronous: the returned frame may
                    // reflect a later point inside its request/completion interval.
                    return state.ui
                }
            },
            beginAX: {
                let requestedAX = state.ui.ax
                state.callOrder.append("ax-request-\(state.ui.app)")
                return Task {
                    await axGate.wait()
                    return requestedAX
                }
            },
            combine: { frame, ax in
                Snapshot(
                    app: frame.app,
                    ax: ax,
                    screenshotBytes: frame.screenshotBytes,
                    screenshotHash: frame.screenshotHash)
            })

        // Proves request start, not physical pixels: AX is still deliberately blocked here.
        await fulfillment(of: [screenStarted], timeout: 1)
        state.ui = Snapshot(
            app: "B",
            ax: "button-B",
            screenshotBytes: Data([0x42]),
            screenshotHash: 0xB)
        await frameGate.release()
        await axGate.release()

        let result = await enrichment.value
        XCTAssertEqual(
            state.callOrder,
            ["screen-request-A", "ax-request-A"])
        XCTAssertEqual(requestedApp, "A")
        XCTAssertEqual(result.app, "B")
        XCTAssertEqual(result.ax, "button-A")
        XCTAssertEqual(result.screenshotBytes, Data([0x42]))
        XCTAssertEqual(result.screenshotHash, 0xB)
    }

    func testFinalPhysicalSampleReplacesProvisionalAWithoutDurableSideEffect() async throws {
        let state = State()
        let coordinator =
            PointerEnrichmentCoordinator<Root, Context, Snapshot, Output>(
                makeRoot: { _, _ in Root(sequence: 42) },
                beginEnrichment: { _, _ in
                    // This test isolates final-sample selection. Async screen timing and its honest
                    // request/completion interval are covered separately.
                    let captured = state.ui
                    state.beginCalls.append(captured.app)
                    state.callOrder.append("begin-\(captured.app)")
                    return Task { captured }
                },
                admit: { producer in
                    state.admissions += 1
                    state.callOrder.append("admit")
                    state.admitted = Task { await producer() }
                },
                finalize: { resolution, root, context, snapshot in
                    state.finalizations += 1
                    return Output(
                        sequence: root.sequence,
                        sampleId: resolution.sampleId,
                        gestureId: resolution.gestureId,
                        clickCount: resolution.clickCount,
                        timestamp: resolution.occurredAt,
                        label: context.label,
                        snapshot: snapshot)
                },
                missing: { _, root in
                    Output(
                        sequence: root.sequence,
                        sampleId: "missing",
                        gestureId: "missing",
                        clickCount: 0,
                        timestamp: .distantPast,
                        label: "missing",
                        snapshot: Snapshot(
                            app: "missing",
                            ax: "missing",
                            screenshotBytes: Data(),
                            screenshotHash: 0))
                })

        let rootGestureId = "gesture-root"
        let firstTime = Date(timeIntervalSince1970: 100)
        let first = EventTap.PointerSample(
            kind: .click,
            location: CGPoint(x: 1, y: 1),
            clickCount: 1,
            dragEnd: nil,
            sampleId: "sample-A",
            gestureId: rootGestureId,
            occurredAt: firstTime)
        coordinator.receive(first, context: Context(app: "A", label: "label-A"))

        state.ui = Snapshot(
            app: "B",
            ax: "button-B",
            screenshotBytes: Data([0x42, 0x42]),
            screenshotHash: 0xB)
        let finalTime = Date(timeIntervalSince1970: 101)
        let second = EventTap.PointerSample(
            kind: .click,
            location: CGPoint(x: 2, y: 2),
            clickCount: 2,
            dragEnd: nil,
            sampleId: "sample-B",
            gestureId: rootGestureId,
            occurredAt: finalTime)
        coordinator.receive(second, context: Context(app: "B", label: "label-B"))

        XCTAssertEqual(state.beginCalls, ["A", "B"])
        XCTAssertEqual(state.callOrder, ["admit", "begin-A", "begin-B"])
        XCTAssertEqual(state.admissions, 1)
        XCTAssertEqual(state.finalizations, 0)

        coordinator.resolve(
            EventTap.PointerResolution(
                kind: .click,
                location: second.location,
                clickCount: 2,
                dragEnd: nil,
                sampleId: second.sampleId,
                gestureId: rootGestureId,
                occurredAt: finalTime))

        let admitted = try XCTUnwrap(state.admitted)
        let output = await admitted.value
        XCTAssertEqual(state.finalizations, 1)
        XCTAssertEqual(
            output,
            Output(
                sequence: 42,
                sampleId: "sample-B",
                gestureId: rootGestureId,
                clickCount: 2,
                timestamp: finalTime,
                label: "label-B",
                snapshot: state.ui))
        XCTAssertNotEqual(output.snapshot.screenshotBytes, Data([0x41]))
        XCTAssertNotEqual(output.timestamp, firstTime)
    }

    func testResolutionCancelsSupersededScreenAndAXHandles() async throws {
        let state = State()
        let screenStarted = expectation(description: "superseded screen started")
        let axStarted = expectation(description: "superseded AX started")
        let screenCancelled = expectation(description: "superseded screen cancelled")
        let axCancelled = expectation(description: "superseded AX cancelled")
        let coordinator =
            PointerEnrichmentCoordinator<Root, Context, Snapshot, Output>(
                makeRoot: { _, _ in Root(sequence: 7) },
                beginEnrichment: { sample, _ in
                    guard sample.sampleId == "sample-A" else {
                        let selected = state.ui
                        return Task { selected }
                    }
                    return PointerParallelEnrichment.begin(
                        beginScreen: {
                            Task {
                                screenStarted.fulfill()
                                return await withTaskCancellationHandler {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    return Snapshot(
                                        app: "stale",
                                        ax: "stale",
                                        screenshotBytes: Data([0x00]),
                                        screenshotHash: 0)
                                } onCancel: {
                                    screenCancelled.fulfill()
                                }
                            }
                        },
                        beginAX: {
                            Task {
                                axStarted.fulfill()
                                return await withTaskCancellationHandler {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    return "stale-ax"
                                } onCancel: {
                                    axCancelled.fulfill()
                                }
                            }
                        },
                        combine: { frame, ax in
                            Snapshot(
                                app: frame.app,
                                ax: ax,
                                screenshotBytes: frame.screenshotBytes,
                                screenshotHash: frame.screenshotHash)
                        })
                },
                admit: { producer in
                    state.admitted = Task { await producer() }
                },
                finalize: { resolution, root, context, snapshot in
                    Output(
                        sequence: root.sequence,
                        sampleId: resolution.sampleId,
                        gestureId: resolution.gestureId,
                        clickCount: resolution.clickCount,
                        timestamp: resolution.occurredAt,
                        label: context.label,
                        snapshot: snapshot)
                },
                missing: { _, root in
                    Output(
                        sequence: root.sequence,
                        sampleId: "missing",
                        gestureId: "missing",
                        clickCount: 0,
                        timestamp: .distantPast,
                        label: "missing",
                        snapshot: state.ui)
                })

        let root = "gesture-root"
        let first = EventTap.PointerSample(
            kind: .click,
            location: .zero,
            clickCount: 1,
            dragEnd: nil,
            sampleId: "sample-A",
            gestureId: root,
            occurredAt: Date(timeIntervalSince1970: 1))
        coordinator.receive(first, context: Context(app: "A", label: "A"))
        await fulfillment(of: [screenStarted, axStarted], timeout: 1)

        state.ui = Snapshot(
            app: "B",
            ax: "button-B",
            screenshotBytes: Data([0x42]),
            screenshotHash: 0xB)
        let second = EventTap.PointerSample(
            kind: .click,
            location: CGPoint(x: 1, y: 1),
            clickCount: 2,
            dragEnd: nil,
            sampleId: "sample-B",
            gestureId: root,
            occurredAt: Date(timeIntervalSince1970: 2))
        coordinator.receive(second, context: Context(app: "B", label: "B"))
        coordinator.resolve(
            EventTap.PointerResolution(
                kind: .click,
                location: second.location,
                clickCount: 2,
                dragEnd: nil,
                sampleId: second.sampleId,
                gestureId: root,
                occurredAt: second.occurredAt))

        await fulfillment(of: [screenCancelled, axCancelled], timeout: 1)
        let admitted = try XCTUnwrap(state.admitted)
        let output = await admitted.value
        XCTAssertEqual(output.sampleId, "sample-B")
        XCTAssertEqual(output.snapshot, state.ui)
    }

    func testMissingResolutionCancelsEverySampleAndProducesOneMissingOutcome() async throws {
        let state = State()
        let firstStarted = expectation(description: "first sample started")
        let secondStarted = expectation(description: "second sample started")
        let firstCancelled = expectation(description: "first sample discarded")
        let secondCancelled = expectation(description: "second sample discarded")
        var finalizations = 0
        var missingOutcomes = 0
        let coordinator =
            PointerEnrichmentCoordinator<Root, Context, Snapshot, Output>(
                makeRoot: { _, _ in Root(sequence: 9) },
                beginEnrichment: { sample, _ in
                    Task {
                        if sample.sampleId == "sample-A" {
                            firstStarted.fulfill()
                        } else {
                            secondStarted.fulfill()
                        }
                        return await withTaskCancellationHandler {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            return Snapshot(
                                app: sample.sampleId,
                                ax: "discarded",
                                screenshotBytes: Data([0]),
                                screenshotHash: 0)
                        } onCancel: {
                            if sample.sampleId == "sample-A" {
                                firstCancelled.fulfill()
                            } else {
                                secondCancelled.fulfill()
                            }
                        }
                    }
                },
                admit: { producer in
                    state.admitted = Task { await producer() }
                },
                finalize: { resolution, root, context, snapshot in
                    finalizations += 1
                    return Output(
                        sequence: root.sequence,
                        sampleId: resolution.sampleId,
                        gestureId: resolution.gestureId,
                        clickCount: resolution.clickCount,
                        timestamp: resolution.occurredAt,
                        label: context.label,
                        snapshot: snapshot)
                },
                missing: { _, root in
                    missingOutcomes += 1
                    return Output(
                        sequence: root.sequence,
                        sampleId: "missing",
                        gestureId: "missing",
                        clickCount: 0,
                        timestamp: .distantPast,
                        label: "missing",
                        snapshot: state.ui)
                })

        let root = "gesture-missing"
        for (sampleId, clickCount) in [("sample-A", 1), ("sample-B", 2)] {
            coordinator.receive(
                EventTap.PointerSample(
                    kind: .click,
                    location: .zero,
                    clickCount: clickCount,
                    dragEnd: nil,
                    sampleId: sampleId,
                    gestureId: root,
                    occurredAt: Date()),
                context: Context(app: sampleId, label: sampleId))
        }
        await fulfillment(of: [firstStarted, secondStarted], timeout: 1)

        coordinator.resolve(
            EventTap.PointerResolution(
                kind: .click,
                location: .zero,
                clickCount: 3,
                dragEnd: nil,
                sampleId: "sample-never-observed",
                gestureId: root,
                occurredAt: Date()))

        await fulfillment(of: [firstCancelled, secondCancelled], timeout: 1)
        let admitted = try XCTUnwrap(state.admitted)
        let output = await admitted.value
        XCTAssertEqual(output.sampleId, "missing")
        XCTAssertEqual(finalizations, 0)
        XCTAssertEqual(missingOutcomes, 1)
    }

    func testSelectedNonCooperativeEnrichmentTimesOutOnceAndLateResultIsInert() async throws {
        let state = State()
        let lateGate = Gate()
        let operationStarted = expectation(description: "non-cooperative operation started")
        let timedOut = Snapshot(
            app: "timeout",
            ax: "timeout",
            screenshotBytes: Data(),
            screenshotHash: 0)
        let late = Snapshot(
            app: "late",
            ax: "late",
            screenshotBytes: Data([0xFF]),
            screenshotHash: 0xFF)
        let coordinator =
            PointerEnrichmentCoordinator<Root, Context, Snapshot, Output>(
                makeRoot: { _, _ in Root(sequence: 10) },
                beginEnrichment: { _, _ in
                    Task {
                        let result = await LocalAsyncDeadline.race(
                            nanoseconds: 20_000_000
                        ) {
                            operationStarted.fulfill()
                            // CheckedContinuation deliberately ignores Task cancellation.
                            await lateGate.wait()
                            return late
                        }
                        switch result {
                        case .value(let value):
                            return value
                        case .timedOut, .cancelled:
                            return timedOut
                        }
                    }
                },
                admit: { producer in
                    state.admitted = Task { await producer() }
                },
                finalize: { resolution, root, context, snapshot in
                    state.finalizations += 1
                    return Output(
                        sequence: root.sequence,
                        sampleId: resolution.sampleId,
                        gestureId: resolution.gestureId,
                        clickCount: resolution.clickCount,
                        timestamp: resolution.occurredAt,
                        label: context.label,
                        snapshot: snapshot)
                },
                missing: { _, root in
                    Output(
                        sequence: root.sequence,
                        sampleId: "missing",
                        gestureId: "missing",
                        clickCount: 0,
                        timestamp: .distantPast,
                        label: "missing",
                        snapshot: timedOut)
                })

        let sample = EventTap.PointerSample(
            kind: .click,
            location: .zero,
            clickCount: 1,
            dragEnd: nil,
            sampleId: "sample-timeout",
            gestureId: "gesture-timeout",
            occurredAt: Date(timeIntervalSince1970: 1))
        coordinator.receive(sample, context: Context(app: "A", label: "A"))
        coordinator.resolve(
            EventTap.PointerResolution(
                kind: .click,
                location: sample.location,
                clickCount: sample.clickCount,
                dragEnd: nil,
                sampleId: sample.sampleId,
                gestureId: sample.gestureId,
                occurredAt: sample.occurredAt))

        await fulfillment(of: [operationStarted], timeout: 1)
        let admitted = try XCTUnwrap(state.admitted)
        let output = await admitted.value
        XCTAssertEqual(output.snapshot, timedOut)
        XCTAssertEqual(state.finalizations, 1)

        await lateGate.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.finalizations, 1)
        XCTAssertNotEqual(output.snapshot, late)
    }
}
