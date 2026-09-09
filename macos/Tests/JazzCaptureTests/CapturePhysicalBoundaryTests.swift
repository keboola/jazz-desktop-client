import CoreGraphics
import Foundation
import XCTest

@testable import JazzCapture
@testable import JazzCaptureCore

@MainActor
final class CapturePhysicalBoundaryTests: XCTestCase {
    private actor Gate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    func testPauseBeforeScheduledScreenshotNeverAdmitsNativeWorkEvenAfterReopen() async throws {
        let flight = ScreenCaptureSingleFlight()
        XCTAssertTrue(flight.open(eligible: { true }))
        let oldAdmission = flight.admission
        let native = ScreenCapture.NativeOperations(
            prepare: { XCTFail("Pause before scheduled task must prevent native admission"); return nil },
            encode: { _ in XCTFail("no cross-boundary encoding"); return nil })
        let queued = Task { await ScreenCapture.focusedWindowShot(
            admission: oldAdmission, bundleID: "synthetic", privacyDenylist: [],
            flight: flight, native: native) }
        flight.close()
        XCTAssertTrue(flight.isClosedAndQuiescent)
        XCTAssertTrue(flight.open(eligible: { true }))
        let result = await queued.value
        XCTAssertEqual(result, .unavailable(.cancelled))
        XCTAssertEqual(flight.snapshot().admittedOperationCount, 0)
        flight.close()
    }

    func testQueuedPhysicalOperationRechecksAdmissionAfterSlotWasClaimed() async {
        let flight = ScreenCaptureSingleFlight()
        var checks = 0
        XCTAssertTrue(flight.open(eligible: {
            checks += 1
            if checks == 3 { flight.close() } // open, claim, then scheduled physical operation
            return true
        }))
        let result = await flight.run(admission: flight.admission, budgetNanoseconds: 1_000_000_000) {
            XCTFail("scheduled operation admitted native work after its gate was revoked")
            return 1
        }
        guard case .cancelled = result else { return XCTFail("revoked physical admission") }
        XCTAssertEqual(flight.snapshot().admittedOperationCount, 1)
        XCTAssertTrue(flight.isClosedAndQuiescent)
    }

    func testRevocationDuringContentOrFrameAwaitRejectsNextAdmissionAndJPEG() async throws {
        for revokeDuringContent in [true, false] {
            let flight = ScreenCaptureSingleFlight()
            XCTAssertTrue(flight.open(eligible: { true }))
            let admission = flight.admission
            let gate = Gate()
            let entered = expectation(description: "native stage entered")
            let image = try image()
            var frames = 0
            var encodes = 0
            let native = ScreenCapture.NativeOperations(prepare: {
                if revokeDuringContent {
                    entered.fulfill()
                    await gate.wait() // same preparation await used for SCShareableContent
                }
                return ScreenCapture.FrameRequest {
                    frames += 1
                    if !revokeDuringContent {
                        entered.fulfill()
                        await gate.wait() // same request await used for SCScreenshotManager
                    }
                    return ScreenCapture.CapturedFrame(
                        image: image, completedAt: Date(), completedUptime: ProcessInfo.processInfo.systemUptime,
                        scope: .window(ownerBundleID: "synthetic", windowID: 1))
                }
            }, encode: { _ in encodes += 1; return Data([1]) })
            let task = Task { await ScreenCapture.focusedWindowShot(
                admission: admission, bundleID: "synthetic", privacyDenylist: [],
                flight: flight, native: native) }
            await fulfillment(of: [entered], timeout: 1)
            flight.close()
            XCTAssertFalse(flight.isClosedAndQuiescent)
            XCTAssertFalse(flight.open(eligible: { true }))
            // A queued request with the old token cannot sneak in while closing.
            let queued = await ScreenCapture.focusedWindowShot(
                admission: admission, bundleID: "synthetic", privacyDenylist: [], flight: flight, native: native)
            XCTAssertEqual(queued, .unavailable(.cancelled))
            await gate.release()
            let result = await task.value
            XCTAssertEqual(result, .unavailable(.cancelled))
            await flight.waitForQuiescence()
            XCTAssertTrue(flight.isClosedAndQuiescent)
            XCTAssertEqual(frames, revokeDuringContent ? 0 : 1)
            XCTAssertEqual(encodes, 0)
            XCTAssertTrue(flight.open(eligible: { true }))
            XCTAssertFalse(flight.permits(admission))
            flight.close()
        }
    }

    func testPhysicalAdapterDeadlineRetainsSlotAndLateFrameNeverEncodes() async throws {
        let flight = ScreenCaptureSingleFlight()
        XCTAssertTrue(flight.open(eligible: { true }))
        let admission = flight.admission
        let gate = Gate()
        let entered = expectation(description: "frame entered")
        let image = try image()
        let native = ScreenCapture.NativeOperations(prepare: {
            ScreenCapture.FrameRequest {
                entered.fulfill()
                await gate.wait()
                return ScreenCapture.CapturedFrame(
                    image: image, completedAt: Date(), completedUptime: 1,
                    scope: .window(ownerBundleID: "synthetic", windowID: 1))
            }
        }, encode: { _ in XCTFail("timed-out frame cannot reach JPEG/publication"); return nil })
        let task = Task { await ScreenCapture.focusedWindowShot(
            admission: admission, bundleID: "synthetic", privacyDenylist: [], budgetNanoseconds: 20_000_000,
            flight: flight, native: native) }
        await fulfillment(of: [entered], timeout: 1)
        let result = await task.value
        XCTAssertEqual(result, .unavailable(.deadlineExceeded))
        let busy = await ScreenCapture.focusedWindowShot(
            admission: admission, bundleID: "synthetic", privacyDenylist: [], flight: flight, native: native)
        XCTAssertEqual(busy, .unavailable(.priorRequestStillInFlight))
        flight.close()
        XCTAssertFalse(flight.isClosedAndQuiescent)
        await gate.release()
        await flight.waitForQuiescence()
        XCTAssertTrue(flight.isClosedAndQuiescent)
        XCTAssertEqual(flight.snapshot().admittedOperationCount, 1)
    }

    func testControllerCloseCannotTreatScreenshotLogicalTimeoutAsPhysicalSettlement() async throws {
        let flight = ScreenCaptureSingleFlight()
        XCTAssertTrue(flight.open(eligible: { true }))
        let admission = flight.admission
        let gate = Gate()
        defer { Task { await gate.release() } }
        let entered = expectation(description: "native content outstanding")
        let task = Task { await ScreenCapture.focusedWindowShot(
            admission: admission, bundleID: "synthetic", privacyDenylist: [], budgetNanoseconds: 10_000_000,
            flight: flight, native: ScreenCapture.NativeOperations(prepare: {
                entered.fulfill()
                await gate.wait()
                return nil
            }, encode: { _ in XCTFail("no frame after revoke"); return nil })) }
        await fulfillment(of: [entered], timeout: 1)
        let screenshot = await task.value
        XCTAssertEqual(screenshot, .unavailable(.deadlineExceeded))
        flight.close()
        let close = CaptureLocalClose()
        let recorder = NarrationRecorder(canAdmit: { false })
        let outcome = await close.run(budgetNanoseconds: 10_000_000, close: {
            try await CaptureLocalClose.drain(
                narration: recorder, screen: flight, labelTail: nil, audioTail: nil, coachLive: nil,
                journalAdmission: { nil }, runtime: nil, coachActions: nil, orderedProjection: nil,
                commit: { XCTFail("physical screenshot still owns the closing generation") })
        }, recoveryRequired: {})
        XCTAssertEqual(outcome, .recoveryRequired)
        XCTAssertFalse(close.settled)
        XCTAssertFalse(close.physicallyReturned)
        XCTAssertFalse(flight.open(eligible: { true }))
        await gate.release()
        await flight.waitForQuiescence()
        for _ in 0..<200 where !close.physicallyReturned {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(close.physicallyReturned)
        XCTAssertFalse(close.settled)
        XCTAssertEqual(close.outcome, .recoveryRequired)
    }

    func testEligibilityIsRecheckedAtPhysicalFrameAdmission() async throws {
        let flight = ScreenCaptureSingleFlight()
        var permission = true
        XCTAssertTrue(flight.open(eligible: { permission }))
        let native = ScreenCapture.NativeOperations(prepare: {
            permission = false // permission changes during content enumeration, without a notification
            return ScreenCapture.FrameRequest { XCTFail("revoked permission"); return nil }
        }, encode: { _ in XCTFail("revoked permission"); return nil })
        let result = await ScreenCapture.focusedWindowShot(
            admission: flight.admission, bundleID: "synthetic", privacyDenylist: [], flight: flight, native: native)
        XCTAssertEqual(result, .unavailable(.cancelled))
        flight.close()
        XCTAssertTrue(flight.isClosedAndQuiescent)
    }

    func testBothNativeAudioProducersStopBeforeBlockedDrainAndCloseReceiptSurvives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic-not-a-recording.m4a")
        let sentinel = Data("sole source synthetic bytes".utf8)
        try sentinel.write(to: url)
        let drainEntered = expectation(description: "advisory drain entered")
        let drainGate = DispatchSemaphore(value: 0)
        defer { drainGate.signal() }
        var order: [String] = []
        var recording = false
        var allowed = true
        let recorder = NarrationRecorder(canAdmit: { allowed }, makeSources: { _, _ in
            recording = true
            return NarrationRecorder.NativeSources(
                isRecording: { recording },
                stopRecording: { order.append("AAC stop"); recording = false },
                stopPCM: { order.append("PCM stop") },
                drainPCM: { drainEntered.fulfill(); drainGate.wait() })
        }, probe: { _ in }) // explicit fake container probe; never claims this is real audio
        let receipt = root.appendingPathComponent("native-stop.txt")
        _ = try recorder.start(at: url, persistStart: { _ in order.append("durable admission") },
            persistStop: { start, end in
                try Data("\(start)\n\(end)".utf8).write(to: receipt)
            })
        XCTAssertTrue(recorder.isRecording)
        allowed = false
        let close = try XCTUnwrap(recorder.stop())
        XCTAssertEqual(order, ["durable admission", "PCM stop", "AAC stop"])
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isQuiescent)
        XCTAssertTrue(recorder.stateDescription.contains("finalizing/blocked"))
        await fulfillment(of: [drainEntered], timeout: 1)
        let closed = try await close.value.get()
        XCTAssertEqual(closed.url, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path))
        XCTAssertEqual(try Data(contentsOf: url), sentinel)
        allowed = true
        XCTAssertThrowsError(try recorder.start(at: url,
            persistStart: { _ in XCTFail("old drain owns the microphone generation") }, persistStop: { _, _ in }))
        drainGate.signal()
        await recorder.waitForQuiescence()
        XCTAssertTrue(recorder.isQuiescent)
    }

    func testUnexpectedlyStoppedAudioRetainsFileAndNeverInventsCloseReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.m4a")
        let bytes = Data("incomplete synthetic source".utf8)
        try bytes.write(to: file)
        var nativeActive = true
        let recorder = NarrationRecorder(canAdmit: { true }, makeSources: { _, _ in
            NarrationRecorder.NativeSources(isRecording: { nativeActive }, stopRecording: {},
                stopPCM: {}, drainPCM: {})
        }, probe: { _ in XCTFail("inactive-at-stop cannot claim a verified end") })
        _ = try recorder.start(at: file, persistStart: { _ in },
            persistStop: { _, _ in XCTFail("must not invent a stop receipt") })
        nativeActive = false
        let task = try XCTUnwrap(recorder.stop())
        guard case .failure = await task.value else { return XCTFail("unobserved end exported") }
        await recorder.waitForQuiescence()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.stateDescription.contains("retained for recovery"))
        XCTAssertNotNil(recorder.closeError)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testAACUnexpectedStopStillEnforcesPermissionForIndependentPCMAndRetainsOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-original.m4a")
        let bytes = Data("sole-source synthetic AAC bytes".utf8)
        try bytes.write(to: file)
        var aacActive = true
        var pcmActive = true
        var permission = true
        var stops: [String] = []
        var checkOwnership: () -> Void = {}
        let recorder = NarrationRecorder(canAdmit: { permission }, makeSources: { _, _ in
            NarrationRecorder.NativeSources(isRecording: { aacActive },
                stopRecording: { checkOwnership(); stops.append("AAC"); aacActive = false },
                stopPCM: { checkOwnership(); stops.append("PCM"); pcmActive = false }, drainPCM: {})
        }, probe: { _ in XCTFail("unobserved AAC stop cannot invent a verified end") })
        checkOwnership = { [weak recorder] in
            XCTAssertEqual(recorder?.hasPotentiallyActiveProducers, true)
            XCTAssertEqual(recorder?.microphonePermissionSatisfied(false), false)
        }
        let environment = CaptureSourceEnvironment(consoleSession: { true })
        var finalization: Task<Result<NarrationRecorder.Recording, Error>, Never>?
        environment.onRevocation = { finalization = recorder.stop() }
        XCTAssertTrue(environment.acknowledgeCurrentUser())
        _ = try recorder.start(at: file, persistStart: { _ in },
            persistStop: { _, _ in XCTFail("original must remain recovery evidence") })
        aacActive = false // AAC can fail while its independent PCM engine keeps recording.
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.hasPotentiallyActiveProducers) // Also drives the controller's mic icon.
        XCTAssertTrue(pcmActive)
        XCTAssertTrue(recorder.microphonePermissionSatisfied(permission))
        XCTAssertEqual(recorder.stateDescription, "Microphone state unknown — sources may be active")
        permission = false
        // The exact permission predicate used by CaptureController.checkSourceEligibility.
        if !recorder.microphonePermissionSatisfied(permission) { environment.revoke() }
        XCTAssertFalse(environment.permitsCapture)
        XCTAssertFalse(pcmActive)
        XCTAssertEqual(stops, ["PCM", "AAC"])
        // Always stop the fake producer, even if the regression fails before revocation.
        let close = try XCTUnwrap(finalization ?? recorder.stop())
        guard case .failure = await close.value else { return XCTFail("unobserved AAC end exported") }
        await recorder.waitForQuiescence()
        XCTAssertTrue(recorder.isQuiescent)
        XCTAssertTrue(recorder.microphonePermissionSatisfied(false))
        XCTAssertFalse(recorder.hasPotentiallyActiveProducers)
        XCTAssertEqual(recorder.stateDescription, "Microphone off — recording retained for recovery")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testMicRevocationDuringDurableAdmissionCannotConstructNativeRecorder() throws {
        var allowed = true
        let recorder = NarrationRecorder(canAdmit: { allowed }, makeSources: { _, _ in
            XCTFail("revoked in pre-admission callback")
            throw NarrationRecorderError.recordingDidNotStart
        })
        XCTAssertThrowsError(try recorder.start(at: URL(fileURLWithPath: "/unused-synthetic"),
            persistStart: { _ in allowed = false }, persistStop: { _, _ in XCTFail("no native stop") }))
        XCTAssertTrue(recorder.isQuiescent)
    }

    func testPublicSessionPreflightRejectsUnknownIncompleteOrForeignUserMembership() {
        let session: [String: Any] = [kCGSessionOnConsoleKey as String: true,
            kCGSessionLoginDoneKey as String: true, kCGSessionUserIDKey as String: NSNumber(value: 501)]
        XCTAssertTrue(CaptureSourceEnvironment.isCurrentConsoleSession(session, userID: 501))
        XCTAssertFalse(CaptureSourceEnvironment.isCurrentConsoleSession(session, userID: 502))
        XCTAssertFalse(CaptureSourceEnvironment.isCurrentConsoleSession(nil, userID: 501))
        for key in [kCGSessionOnConsoleKey, kCGSessionLoginDoneKey, kCGSessionUserIDKey] {
            var unknown = session
            unknown.removeValue(forKey: key as String)
            XCTAssertFalse(CaptureSourceEnvironment.isCurrentConsoleSession(unknown, userID: 501))
        }
        var inactive = session
        inactive[kCGSessionOnConsoleKey as String] = false
        XCTAssertFalse(CaptureSourceEnvironment.isCurrentConsoleSession(inactive, userID: 501))
        // Successful public membership parsing deliberately makes no assertion about lock state.
    }

    func testWorkspaceRecoveryNeverErasesPauseOrAcknowledgesUnknownLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = CaptureStartIntent(root: root, continuous: true,
            durability: JazzArchiveFilesystemPlatform.durability)
        intent.completeRecovery(succeeded: true)
        var onConsole = true
        let environment = CaptureSourceEnvironment(consoleSession: { onConsole })
        let flight = ScreenCaptureSingleFlight()
        environment.onRevocation = { flight.close(); _ = intent.beginShutdown() }
        XCTAssertFalse(environment.permitsCapture) // launch cannot prove unlocked
        XCTAssertTrue(environment.acknowledgeCurrentUser())
        XCTAssertTrue(flight.open(eligible: { environment.permitsCapture }))
        let token = flight.admission
        _ = try XCTUnwrap(intent.requestStart(explicit: true))
        environment.receive(.sleep)
        XCTAssertTrue(flight.isClosedAndQuiescent)
        XCTAssertFalse(intent.userPaused) // environment suspension is NOT ordinary Pause
        environment.receive(.wake)
        XCTAssertFalse(environment.permitsCapture)
        XCTAssertFalse(flight.permits(token))
        intent.pause()
        environment.receive(.lockHint)
        environment.receive(.unlockHint)
        environment.receive(.screensSleep)
        environment.receive(.screensWake)
        environment.receive(.resigned)
        environment.receive(.active)
        XCTAssertFalse(environment.permitsCapture)
        XCTAssertTrue(intent.userPaused)
        XCTAssertNil(intent.requestStart(explicit: false))
        let reopened = CaptureStartIntent(root: root, continuous: true,
            durability: JazzArchiveFilesystemPlatform.durability)
        XCTAssertTrue(reopened.userPaused)
        onConsole = false
        XCTAssertFalse(environment.acknowledgeCurrentUser())
        onConsole = true
        XCTAssertTrue(environment.acknowledgeCurrentUser()) // acknowledgment, not lock attestation
        XCTAssertTrue(intent.userPaused)
    }
}
