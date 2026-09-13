import Darwin
import Foundation
import XCTest

@testable import JazzCaptureCore

final class BestEffortTransportTests: XCTestCase {
    typealias Runtime = BestEffortTransport
    let generation = UUID()

    func runtime(
        units: Int = 4, bytes: Int = 64, encoding: Int = 4,
        flight: Int = 1, flightBytes: Int = 16
    ) throws -> Runtime {
        let r = Runtime(
            limits: try .init(
                units: units, bytes: bytes, partBytes: 16,
                encodingParts: encoding, inFlight: flight, inFlightBytes: flightBytes,
                attempts: 3, age: 20, attemptTime: 5, backoff: 1, backoffCap: 4))
        XCTAssertTrue(r.startExplicitly(generation: generation, now: 0))
        return r
    }
    @discardableResult
    func enqueue(_ r: Runtime, id: UUID = UUID(), media: Bool = false, now: Double = 0)
        -> Runtime.Ticket
    {
        let ticket = r.reserve(
            unitID: id, eventBytes: 8, mediaBytes: media ? 8 : 0,
            generation: generation, now: now)!
        r.finishEncoding(ticket, component: .event, data: Data(repeating: 1, count: 8), now: now)
        if media {
            r.finishEncoding(
                ticket, component: .media, data: Data(repeating: 2, count: 8), now: now)
        }
        return ticket
    }
    func take(_ r: Runtime, now: Double, token: UUID? = nil) -> Runtime.Attempt? {
        var attempt: Runtime.Attempt?
        r.withNextAttempt(generation: token ?? generation, now: now) { attempt = $0 }
        return attempt
    }

    func testExplicitBoundsAndStartupFailClosed() throws {
        XCTAssertThrowsError(try Runtime.Limits(bytes: 0))
        XCTAssertThrowsError(try Runtime.Limits(age: .nan))
        XCTAssertThrowsError(try Runtime.Limits(attempts: 0))
        XCTAssertThrowsError(try Runtime.Limits(partBytes: 20, inFlightBytes: 10))
        let r = Runtime(limits: try .init())
        XCTAssertNil(r.reserve(unitID: UUID(), eventBytes: 1, generation: generation, now: 0))
        XCTAssertTrue(r.snapshot.coverageUnknown)
        XCTAssertTrue(r.startExplicitly(generation: generation, now: 0))
        XCTAssertFalse(r.startExplicitly(generation: UUID(), now: 0))
        XCTAssertNil(r.reserve(unitID: UUID(), eventBytes: .max, generation: generation, now: 0))
        XCTAssertNil(
            r.reserve(unitID: UUID(), eventBytes: 1, mediaBytes: -1, generation: generation, now: 0)
        )
    }

    func testOutageBackoffAttemptsAndIdenticalRetryBytes() throws {
        let r = try runtime()
        enqueue(r)
        let first = take(r, now: 0)!
        r.finishAttempt(first.id, result: .retryable(after: nil), now: 0)
        XCTAssertNil(take(r, now: 0.99))
        let second = take(r, now: 1)!
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(first.payload, second.payload)
        XCTAssertNotEqual(first.id, second.id)
        // Duplicate old callback cannot settle the new physical owner.
        r.finishAttempt(first.id, result: .accepted, now: 1)
        XCTAssertEqual(r.snapshot.inFlight, 1)
        r.finishAttempt(second.id, result: .retryable(after: nil), now: 1)
        XCTAssertNil(take(r, now: 2.99))
        let third = take(r, now: 3)!
        r.finishAttempt(third.id, result: .retryable(after: nil), now: 3)
        XCTAssertNil(take(r, now: 10))
        XCTAssertEqual(r.snapshot.reservedBytes, 0)
        XCTAssertEqual(r.drainReports().first?.event, .unknown)
    }

    func test429HonorsRetryAfterWithoutExtendingAgeDeadline() throws {
        let r = try runtime()
        enqueue(r)
        let first = take(r, now: 0)!
        r.finishAttempt(
            first.id,
            result: BestEffortOTLPAcknowledgement.classify(
                status: 429,
                body: Data(), retryAfter: 7), now: 0)
        XCTAssertNil(take(r, now: 6))
        XCTAssertNotNil(take(r, now: 7))
        let other = try runtime()
        enqueue(other)
        let request = take(other, now: 0)!
        other.finishAttempt(request.id, result: .retryable(after: 100), now: 0)
        XCTAssertNil(take(other, now: 19))
        XCTAssertEqual(other.drainReports().first?.event, .unknown)
        let invalid = try runtime()
        enqueue(invalid)
        invalid.finishAttempt(take(invalid, now: 0)!.id, result: .retryable(after: .nan), now: 0)
        XCTAssertEqual(invalid.drainReports().first?.event, .unknown)
    }

    func testLostAckAndPartialNeverReplayOrClaimRejectedIDs() throws {
        for result in [Runtime.Result.uncertain, .partial] {
            let r = try runtime()
            enqueue(r)
            r.finishAttempt(take(r, now: 0)!.id, result: result, now: 1)
            XCTAssertNil(take(r, now: 2))
            let report = r.drainReports().first!
            XCTAssertEqual(report.event, .unknown)
            XCTAssertTrue(report.coverageUnknown)
        }
    }

    func testLaterRejectionCannotEraseEarlierRetryUncertainty() throws {
        let r = try runtime()
        enqueue(r)
        r.finishAttempt(take(r, now: 0)!.id, result: .retryable(after: nil), now: 0)
        r.finishAttempt(take(r, now: 1)!.id, result: .rejected, now: 1)
        XCTAssertEqual(r.drainReports().first?.event, .unknown)
    }

    func testIndependentEventOnlyAndMediaOnlyLoss() throws {
        let r = try runtime()
        enqueue(r, media: true)
        let event = take(r, now: 0)!
        XCTAssertEqual(event.component, .event)
        r.finishAttempt(event.id, result: .accepted, now: 1)
        let media = take(r, now: 1)!
        XCTAssertEqual(media.component, .media)
        r.finishAttempt(media.id, result: .rejected, now: 2)
        let report = r.drainReports().first!
        XCTAssertEqual(report.event, .hopAccepted)
        XCTAssertEqual(report.media, .unavailable)
        XCTAssertEqual(report.generation, generation)
        XCTAssertTrue(report.coverageUnknown)
        let other = try runtime()
        let ticket = other.reserve(
            unitID: UUID(), eventBytes: 8, mediaBytes: 8, generation: generation, now: 0)!
        other.finishEncoding(ticket, component: .event, data: nil, now: 0)
        other.finishEncoding(ticket, component: .media, data: Data(repeating: 4, count: 8), now: 0)
        other.finishAttempt(take(other, now: 0)!.id, result: .accepted, now: 1)
        let orphan = other.drainReports().first!
        XCTAssertEqual(orphan.event, .unavailable)
        XCTAssertEqual(orphan.media, .hopAccepted)
    }

    func testFullQueueFavorsFreshPendingButCannotEvictPhysicalOwners() throws {
        let r = try runtime(units: 2, bytes: 16, encoding: 2)
        let oldest = UUID()
        enqueue(r, id: oldest)
        enqueue(r)
        enqueue(r)
        XCTAssertEqual(r.snapshot.units, 2)
        XCTAssertEqual(r.snapshot.reservedBytes, 16)
        XCTAssertEqual(r.drainReports().first?.unitID, oldest)
        let a = take(r, now: 0)!
        let ticket = r.reserve(unitID: UUID(), eventBytes: 8, generation: generation, now: 0)!
        XCTAssertNil(r.reserve(unitID: UUID(), eventBytes: 8, generation: generation, now: 0))
        XCTAssertEqual(r.snapshot.inFlightBytes, 8)
        XCTAssertEqual(r.snapshot.reservedBytes, 16)
        r.advance(generation: generation, now: 100)
        XCTAssertEqual(r.snapshot.reservedBytes, 16)  // Timeout is not physical termination.
        XCTAssertEqual(r.snapshot.cancellations, [a.id])
        XCTAssertEqual(r.snapshot.encodingCancellations, [ticket])
        r.finishEncoding(ticket, component: .event, data: Data(repeating: 9, count: 8), now: 100)
        r.finishAttempt(a.id, result: .accepted, now: 100)
        XCTAssertEqual(r.snapshot.reservedBytes, 0)
        XCTAssertTrue(r.drainReports().contains { $0.event == .unknown })
    }

    func testIndependentInflightByteCeilingAndCallerBufferIsolation() throws {
        let r = try runtime(flight: 3, flightBytes: 16)
        let ticket = r.reserve(
            unitID: UUID(), eventBytes: 8, mediaBytes: 8, generation: generation, now: 0)!
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 1024 * 1024, alignment: 8)
        defer { memory.deallocate() }
        memory.initializeMemory(as: UInt8.self, repeating: 7, count: 1024 * 1024)
        let backing = Data(bytesNoCopy: memory, count: 1024 * 1024, deallocator: .none)
        r.finishEncoding(ticket, component: .event, data: backing.prefix(8), now: 0)
        memory.storeBytes(of: UInt8(9), as: UInt8.self)
        r.finishEncoding(ticket, component: .media, data: Data(repeating: 2, count: 8), now: 0)
        enqueue(r)
        let event = take(r, now: 0)!
        XCTAssertEqual(event.payload, Data(repeating: 7, count: 8))
        XCTAssertNotNil(take(r, now: 0))
        XCTAssertEqual(r.snapshot.inFlight, 2)
        XCTAssertEqual(r.snapshot.inFlightBytes, 16)
        XCTAssertNil(take(r, now: 0))  // Byte ceiling, despite one free count slot.
        r.finishAttempt(event.id, result: .accepted, now: 1)
        XCTAssertNotNil(take(r, now: 1))
        XCTAssertEqual(r.snapshot.inFlightBytes, 16)
    }

    func testQueuedAgeExpiresWithoutCatchUpOrDeadlineExtension() throws {
        let r = try runtime()
        enqueue(r)
        XCTAssertNil(take(r, now: 20))
        XCTAssertEqual(r.snapshot.reservedBytes, 0)
        XCTAssertEqual(r.drainReports().first?.event, .unavailable)
        enqueue(r, now: 1000)
        XCTAssertEqual(take(r, now: 1000)?.number, 1)
    }

    func testSlowUploadAndDeadlineKeepSlotUntilActualReturn() throws {
        let r = try runtime()
        enqueue(r)
        enqueue(r)
        let stalled = take(r, now: 0)!
        XCTAssertNil(take(r, now: 1))
        XCTAssertEqual(r.advance(generation: generation, now: 5).cancellations, [stalled.id])
        XCTAssertNil(take(r, now: 6))
        XCTAssertEqual(r.snapshot.inFlight, 1)
        r.finishAttempt(stalled.id, result: .uncertain, now: 7)
        XCTAssertEqual(r.snapshot.inFlight, 0)
        XCTAssertNotNil(take(r, now: 7))
    }

    func testEncoderReservationCeilingAndOversizedEncoding() throws {
        let r = try runtime(encoding: 2)
        let ticket = r.reserve(
            unitID: UUID(), eventBytes: 8, mediaBytes: 8, generation: generation, now: 0)!
        XCTAssertNil(r.reserve(unitID: UUID(), eventBytes: 1, generation: generation, now: 0))
        XCTAssertEqual(r.snapshot.encodingParts, 2)
        r.finishEncoding(ticket, component: .event, data: Data(repeating: 1, count: 9), now: 0)
        r.finishEncoding(ticket, component: .media, data: nil, now: 0)
        XCTAssertEqual(r.snapshot.reservedBytes, 0)
        XCTAssertEqual(r.drainReports().first?.event, .unavailable)
    }

    func testPauseStopLockSleepRevokeFenceLateWorkAndNoReconnectResume() throws {
        for reason in [Runtime.Fence.pause, .stop, .lock, .sleep, .revoked] {
            let r = try runtime()
            enqueue(r, media: true)
            let active = take(r, now: 0)!
            let encoding = r.reserve(unitID: UUID(), eventBytes: 8, generation: generation, now: 0)!
            XCTAssertEqual(r.suspend(reason), [active.id])
            XCTAssertNil(take(r, now: 1))
            XCTAssertNil(r.reserve(unitID: UUID(), eventBytes: 1, generation: generation, now: 1))
            let fresh = UUID()
            XCTAssertFalse(r.startExplicitly(generation: fresh, now: 1))
            r.finishEncoding(
                encoding, component: .event, data: Data(repeating: 1, count: 8), now: 1)
            r.finishAttempt(active.id, result: .accepted, now: 1)
            XCTAssertEqual(r.snapshot.units, 0)
            XCTAssertNil(take(r, now: 2))  // Recovery/time passage grants nothing.
            XCTAssertFalse(r.startExplicitly(generation: generation, now: 2))
            XCTAssertEqual(r.startExplicitly(generation: fresh, now: 2), reason != .revoked)
            r.finishAttempt(active.id, result: .accepted, now: 2)
            XCTAssertTrue(r.drainReports().contains { $0.event == .unknown })
        }
    }

    func testAuthRevocationClockRollbackAndRestartFailClosed() throws {
        let r = try runtime()
        enqueue(r)
        let old = take(r, now: 0)!
        r.finishAttempt(old.id, result: .unauthorized, now: 1)
        XCTAssertEqual(r.snapshot.fence, .revoked)
        XCTAssertFalse(r.startExplicitly(generation: UUID(), now: 2))
        let rebooted = Runtime(limits: r.limits)
        rebooted.finishAttempt(old.id, result: .accepted, now: 2)
        XCTAssertNil(take(rebooted, now: 2))
        XCTAssertTrue(rebooted.snapshot.coverageUnknown)
        XCTAssertEqual(rebooted.snapshot.units, 0)
        XCTAssertTrue(rebooted.drainReports().isEmpty)
        let clock = try runtime()
        enqueue(clock, now: 5)
        XCTAssertNil(take(clock, now: 4))
        XCTAssertEqual(clock.snapshot.fence, .clock)
        XCTAssertFalse(clock.startExplicitly(generation: UUID(), now: 6))
    }

    func testStaleOwnersCannotPoisonFreshGenerationClock() throws {
        let r = try runtime()
        let oldTicket = enqueue(r)
        let oldAttempt = take(r, now: 0)!
        r.finishAttempt(oldAttempt.id, result: .accepted, now: 1)
        _ = r.drainReports()
        r.suspend(.stop)
        let fresh = UUID()
        XCTAssertTrue(r.startExplicitly(generation: fresh, now: 100))
        r.finishEncoding(oldTicket, component: .event, data: Data([1]), now: 0)
        r.finishAttempt(oldAttempt.id, result: .unauthorized, now: 0)
        XCTAssertNil(take(r, now: 0))
        XCTAssertNil(r.reserve(unitID: UUID(), eventBytes: 1, generation: generation, now: 0))
        XCTAssertFalse(r.startExplicitly(generation: generation, now: 0))
        _ = r.advance(generation: generation, now: 0)
        XCTAssertNil(r.snapshot.fence)
        XCTAssertNotNil(r.reserve(unitID: UUID(), eventBytes: 1, generation: fresh, now: 100))
    }

    func testCaptureHandoffDoesNotWaitOnWorkerLock() throws {
        let r = try runtime()
        enqueue(r)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            r.withNextAttempt(generation: self.generation, now: 0) { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 3)  // Deliberately misbehaving adapter fault.
            }
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let start = ProcessInfo.processInfo.systemUptime
        let refused = r.reserve(unitID: UUID(), eventBytes: 1, generation: generation, now: 0)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        release.signal()
        XCTAssertNil(refused)
        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    }

    func testSustainedBoundedAccountingReportsAndNoTempFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try runtime()
        for i in 0..<10_000 {
            let now = Double(i)
            enqueue(r, now: now)
            if let attempt = take(r, now: now) {
                r.finishAttempt(attempt.id, result: .uncertain, now: now)
            }
            let s = r.snapshot
            XCTAssertLessThanOrEqual(s.units, r.limits.units)
            XCTAssertLessThanOrEqual(s.reservedBytes, r.limits.bytes)
            XCTAssertLessThanOrEqual(s.inFlight, r.limits.inFlight)
            XCTAssertLessThanOrEqual(s.inFlightBytes, r.limits.inFlightBytes)
            XCTAssertLessThanOrEqual(s.reports, r.limits.units)
            XCTAssertEqual(s.temporaryFileBytes, 0)
        }
        XCTAssertTrue(r.snapshot.reportOverflow)
        XCTAssertTrue(r.snapshot.coverageUnknown)
        XCTAssertEqual(r.snapshot.reservedBytes, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        // Owned byte/slot bounds are deterministic; allocator RSS and external encoder/HTTP
        // copies are NOT equated with these counters or qualified by this test.
    }

    func testActualProcessDeathLosesRAMAndRestartsDisarmed() throws {
        let environment = ProcessInfo.processInfo.environment
        let rootKey = "JAZZ_BEST_EFFORT_TEST_ROOT"
        let modeKey = "JAZZ_BEST_EFFORT_TEST_MODE"
        if let path = environment[rootKey], let mode = environment[modeKey] {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            if mode == "restart" {
                let fresh = Runtime(limits: try .init())
                XCTAssertEqual(fresh.snapshot.units, 0)
                XCTAssertEqual(fresh.snapshot.fence, .startup)
                XCTAssertTrue(fresh.snapshot.coverageUnknown)
                XCTAssertTrue(fresh.drainReports().isEmpty)
                XCTAssertNil(take(fresh, now: 0))
                try Data("disarmed-unknown".utf8).write(
                    to: root.appendingPathComponent("restarted"))
                return
            }
            let r = try runtime()
            enqueue(r, media: true)
            XCTAssertNotNil(take(r, now: 0))
            XCTAssertNotNil(
                r.reserve(unitID: UUID(), eventBytes: 8, generation: generation, now: 0))
            XCTAssertEqual(r.snapshot.reservedBytes, 24)
            try Data("owned".utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
            withExtendedLifetime(r) { while true { usleep(10_000) } }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "best-effort-kill-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func child(_ mode: String) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "xctest", "-XCTest",
                "JazzCaptureCoreTests.BestEffortTransportTests/testActualProcessDeathLosesRAMAndRestartsDisarmed",
                Bundle(for: Self.self).bundleURL.path,
            ]
            var childEnvironment = environment
            childEnvironment[rootKey] = root.path
            childEnvironment[modeKey] = mode
            process.environment = childEnvironment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        let killed = try child("kill")
        defer {
            if killed.isRunning {
                _ = kill(killed.processIdentifier, SIGKILL)
                killed.waitUntilExit()
            }
        }
        for _ in 0..<1000
        where killed.isRunning
            && !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path)
        { usleep(10_000) }
        guard killed.isRunning,
            FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path)
        else {
            return XCTFail("Owned child did not reach its kill boundary")
        }
        XCTAssertEqual(kill(killed.processIdentifier, SIGKILL), 0)
        killed.waitUntilExit()
        XCTAssertEqual(killed.terminationReason, .uncaughtSignal)
        XCTAssertEqual(killed.terminationStatus, SIGKILL)
        let restarted = try child("restart")
        for _ in 0..<1000 where restarted.isRunning { usleep(10_000) }
        if restarted.isRunning { _ = kill(restarted.processIdentifier, SIGKILL) }
        restarted.waitUntilExit()
        XCTAssertEqual(restarted.terminationStatus, 0)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("restarted"), encoding: .utf8),
            "disarmed-unknown")
        // Only test rendezvous markers exist: no payload spool/receipt was restored or replayed.
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
            ["ready", "restarted"])
    }

    func testResidentHighWaterGrowthWithRealPayloadPressure() throws {
        func peak() -> Int {
            var usage = rusage()
            XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
            return Int(usage.ru_maxrss)  // Darwin reports bytes, not Linux KiB.
        }
        let mib = 1024 * 1024
        let r = Runtime(
            limits: try .init(
                units: 8, bytes: 8 * mib, partBytes: mib,
                encodingParts: 2, inFlight: 2, inFlightBytes: 2 * mib))
        XCTAssertTrue(r.startExplicitly(generation: generation, now: 0))
        let before = peak()
        for i in 0..<512 {
            let now = Double(i) / 1000
            let ticket = r.reserve(
                unitID: UUID(), eventBytes: mib, generation: generation, now: now)!
            r.finishEncoding(
                ticket, component: .event, data: Data(repeating: UInt8(i % 255), count: mib),
                now: now)
            if i % 4 == 0, let a = take(r, now: now) {
                r.finishAttempt(a.id, result: .uncertain, now: now)
            }
            XCTAssertLessThanOrEqual(r.snapshot.reservedBytes, 8 * mib)
        }
        let growth = max(0, peak() - before)
        print("S2 synthetic 8MiB queue, 512MiB turnover, process peak RSS growth bytes: \(growth)")
        // Generous process-level regression guard includes allocator/test overhead, not a claim
        // that a native encoder/URLSession/application will fit the queue's 8MiB accounting cap.
        XCTAssertLessThanOrEqual(growth, 64 * mib)
        r.suspend(.stop)
        XCTAssertEqual(r.snapshot.reservedBytes, 0)
    }

    func testOTLPClassificationIsBoundedHopLocalAndNeverReplaysPartial() {
        func ack(_ body: String, _ status: Int = 200) -> Runtime.Result {
            BestEffortOTLPAcknowledgement.classify(status: status, body: Data(body.utf8))
        }
        XCTAssertEqual(ack("{}"), .accepted)
        XCTAssertEqual(ack("{\"partialSuccess\":{\"rejectedLogRecords\":\"2\"}}"), .partial)
        XCTAssertEqual(ack("{\"partialSuccess\":{}}"), .accepted)
        for body in [
            "", "[]", "{", "{\"partialSuccess\":null}",
            "{\"partialSuccess\":{\"rejectedLogRecords\":true}}",
            "{\"partialSuccess\":{\"rejectedLogRecords\":-1}}",
            "{\"partialSuccess\":{\"rejectedLogRecords\":1.5}}",
            "{\"partialSuccess\":{\"rejectedLogRecords\":\"9223372036854775808\"}}",
            String(repeating: "[", count: 2000) + String(repeating: "]", count: 2000),
            "{}" + String(repeating: " ", count: 65536),
        ] { XCTAssertEqual(ack(body), .uncertain, String(body.prefix(80))) }
        XCTAssertEqual(ack("", 401), .unauthorized)
        XCTAssertEqual(ack("", 403), .unauthorized)
        XCTAssertEqual(ack("", 429), .retryable(after: nil))
        XCTAssertEqual(ack("", 503), .retryable(after: nil))
        XCTAssertEqual(ack("", 400), .rejected)
        XCTAssertEqual(ack("", 499), .uncertain)
        XCTAssertEqual(ack("{}", 201), .uncertain)
    }
}
