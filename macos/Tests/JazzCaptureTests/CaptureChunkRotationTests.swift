import Foundation
import XCTest
@testable import JazzCapture
@testable import JazzCaptureCore

/// Exercises the owners called by CaptureController, with temporary archives and fake sources.
/// Does not instantiate the native controller, touch Keychain/TCC, or start any delivery services.
@MainActor
final class CaptureChunkRotationTests: XCTestCase {
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { open = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
    }
    private let durability = JazzArchiveFilesystemDurability(
        synchronizeRegularFile: { _, _ in }, synchronizeDirectory: { _ in })

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func arm(_ root: URL, continuous: Bool = false) async throws -> CaptureStartIntent {
        let intent = CaptureStartIntent(root: root, continuous: continuous, durability: durability)
        intent.completeRecovery(succeeded: true)
        let token = try XCTUnwrap(intent.requestStart(explicit: true))
        let started = await intent.runStart(token, recovery: { true }, prepare: { true }, enable: { true }, abort: {})
        XCTAssertTrue(started)
        return intent
    }

    func testConcurrentDurationAndByteTriggersWaitForCommitAndPhysicalReturnThenFreshIDs() async throws {
        let root = try root()
        let intent = try await arm(root)
        let screen = ScreenCaptureSingleFlight()
        XCTAssertTrue(screen.open(eligible: { true }))
        let oldAdmission = screen.admission
        let nativeGate = Gate()
        let nativeEntered = expectation(description: "native operation")
        let native = Task {
            await screen.run(admission: oldAdmission, budgetNanoseconds: 1_000_000) {
                nativeEntered.fulfill()
                await nativeGate.wait()
                return 1
            }
        }
        await fulfillment(of: [nativeEntered], timeout: 1)
        _ = await native.value // logical timeout is NOT physical quiescence
        let first = try await chunk(root: root)
        let firstBytes = try XCTUnwrap(first.journal.chunkBytes.measured)
        XCTAssertGreaterThan(firstBytes, 0, "production journal charges serialized metadata")
        let token = try XCTUnwrap(intent.requestRotation())
        XCTAssertNil(intent.requestRotation(reason: .bytes), "timer/byte trigger coalesces before Task scheduling")
        XCTAssertNil(intent.requestStart(explicit: false), "reconnect cannot manufacture a second intent")
        screen.close()
        let close = CaptureLocalClose()
        let narration = NarrationRecorder(canAdmit: { false }, makeSources: { _, _ in
            XCTFail("rotation never opens microphone"); throw NarrationRecorderError.recordingDidNotStart
        })
        var commits = 0
        var second: Chunk?
        let rotating = Task {
            await intent.runRotation(token, close: {
                let outcome = await close.run(budgetNanoseconds: 1_000_000_000, close: {
                    try await CaptureLocalClose.drain(narration: narration, screen: screen,
                        labelTail: nil, audioTail: nil, coachLive: nil, journalAdmission: { nil },
                        runtime: first.runtime, coachActions: nil, orderedProjection: nil) {
                            _ = try await first.runtime.close(endedAt: Timestamps.iso8601())
                            commits += 1
                        }
                }, recoveryRequired: { intent.completeRecovery(succeeded: false) })
                return outcome == .settled && close.settled && screen.isClosedAndQuiescent
            }, eligible: { true }, start: { token in
                await intent.runStart(token, recovery: { true }, prepare: {
                    do { second = try await self.chunk(root: root); return true }
                    catch { XCTFail("\(error)"); return false }
                }, enable: { screen.open(eligible: { true }) }, abort: {})
            })
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertNil(second)
        XCTAssertEqual(commits, 0)
        XCTAssertFalse(screen.isClosedAndQuiescent)
        await nativeGate.release()
        let resumed = await rotating.value
        XCTAssertTrue(resumed)
        XCTAssertEqual(commits, 1)
        XCTAssertFalse(screen.permits(oldAdmission))
        XCTAssertTrue(intent.isArmed, "manual arm survives only successful safety rotation")
        XCTAssertFalse(intent.isRotating)
        let next = try XCTUnwrap(second)
        XCTAssertNotEqual(first.manifest.archiveId, next.manifest.archiveId)
        XCTAssertNotEqual(first.session.captureId, next.session.captureId)
        XCTAssertNotEqual(first.session.streamIds, next.session.streamIds)
        XCTAssertNotEqual(first.event.eventId, next.event.eventId)
        XCTAssertEqual(first.manifest.originId, next.manifest.originId)
        XCTAssertEqual(first.session.area, next.session.area)
        XCTAssertNil(next.manifest.supersedesArchiveId)
        let snapshot = await first.journal.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .committed)
        // No finalized ZIP or delivery package was manufactured by rotation.
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        XCTAssertFalse(files.allObjects.compactMap { $0 as? URL }.contains { $0.pathExtension == "jazz-archive" })
        screen.close()
        _ = try await next.runtime.close(endedAt: Timestamps.iso8601())
        intent.pause()
        XCTAssertFalse(intent.isArmed)
        XCTAssertNil(intent.requestRotation())
        XCTAssertFalse(CaptureStartIntent(root: root, continuous: false, durability: durability).isArmed)
    }

    func testStopPausePrivacyAndModeChangeDuringClosingPreventContinuation() async throws {
        for boundary in ["stop", "pause", "sleep", "mode", "fault", "exit"] {
            let root = try root()
            let intent = try await arm(root, continuous: true)
            let environment = CaptureSourceEnvironment(consoleSession: { true })
            XCTAssertTrue(environment.acknowledgeCurrentUser())
            environment.onRevocation = { _ = intent.beginShutdown() }
            let token = try XCTUnwrap(intent.requestRotation())
            let gate = Gate()
            let entered = expectation(description: boundary)
            let rotating = Task {
                await intent.runRotation(token, close: { entered.fulfill(); await gate.wait(); return true },
                    eligible: { environment.permitsCapture }, start: { _ in XCTFail("\(boundary) restarted"); return true })
            }
            await fulfillment(of: [entered], timeout: 1)
            switch boundary {
            case "stop", "pause": intent.pause()
            case "sleep": environment.receive(.sleep); environment.receive(.wake)
            case "mode": intent.setContinuous(false)
            case "fault": intent.completeRecovery(succeeded: false)
            default: _ = intent.beginShutdown()
            }
            await gate.release()
            let resumed = await rotating.value
            XCTAssertFalse(resumed)
            XCTAssertFalse(intent.isArmed)
            XCTAssertFalse(intent.isRotating)
            XCTAssertNil(intent.requestRotation())
        }
    }

    func testIdleClockSurvivesShortRotationsAndExplicitSpansDeferOnlyIdle() async throws {
        let intent = try await arm(try root())
        var now: TimeInterval = 100
        var idle: TimeInterval? = 10_000
        var probes = 0
        let environment = CaptureSourceEnvironment(consoleSession: { true },
            idleSeconds: { probes += 1; return idle }, uptime: { now })
        XCTAssertTrue(environment.acknowledgeCurrentUser())
        environment.onRevocation = { _ = intent.beginShutdown() }
        let policy = try CaptureChunkBoundary(duration: 60)
        let eligible = {
            environment.permitsCapture && environment.revokeForInactivity(policy, hasOpenSpan: false) == nil
        }
        // Four short chunks cannot postpone the original five-minute inactivity deadline.
        for time: TimeInterval in [160, 220, 280, 340] {
            now = time
            let token = try XCTUnwrap(intent.requestRotation())
            let resumed = await intent.runRotation(token, close: { true }, eligible: eligible, start: { token in
                await intent.runStart(token, recovery: { true }, prepare: { true },
                    enable: { true }, abort: {}, eligible: eligible)
            })
            XCTAssertTrue(resumed)
        }
        now = 400
        let before = probes
        idle = nil
        XCTAssertNil(environment.revokeForInactivity(policy, hasOpenSpan: true))
        XCTAssertEqual(probes, before, "labels/narration/workshops do not even query idle input")
        XCTAssertTrue(environment.permitsCapture)
        idle = 10_000
        XCTAssertEqual(environment.revokeForInactivity(policy, hasOpenSpan: false), .idle)
        XCTAssertFalse(intent.isArmed)
        XCTAssertFalse(intent.userPaused)
        XCTAssertFalse(environment.permitsCapture)
        XCTAssertFalse(CaptureChunkBoundary.permitsContinuation(reason: .duration, hasOpenSpan: true),
            "idle exemption does not remove hard duration/size limits")
    }

    func testIdleDuringCloseOrPreparationPreventsReplacementInBothModes() async throws {
        for continuous in [false, true] {
            for stage in ["close", "prepare"] {
                let intent = try await arm(try root(), continuous: continuous)
                var now: TimeInterval = 0
                let environment = CaptureSourceEnvironment(consoleSession: { true },
                    idleSeconds: { 1_000 }, uptime: { now })
                XCTAssertTrue(environment.acknowledgeCurrentUser())
                var revocations = 0
                environment.onRevocation = { revocations += 1; _ = intent.beginShutdown() }
                let policy = try CaptureChunkBoundary()
                let eligible = {
                    environment.permitsCapture && environment.revokeForInactivity(policy, hasOpenSpan: false) == nil
                }
                let token = try XCTUnwrap(intent.requestRotation())
                let resumed = await intent.runRotation(token, close: {
                    if stage == "close" { now = 300 }
                    return true
                }, eligible: eligible, start: { token in
                    XCTAssertEqual(stage, "prepare")
                    return await intent.runStart(token, recovery: { true }, prepare: {
                        now = 300; return true
                    }, enable: { XCTFail("idle replacement enabled sources"); return true }, abort: {}, eligible: eligible)
                })
                XCTAssertFalse(resumed)
                XCTAssertFalse(intent.isArmed)
                XCTAssertFalse(intent.userPaused)
                XCTAssertEqual(revocations, 1)
                environment.receive(.wake)
                environment.receive(.active)
                environment.receive(.unlockHint)
                XCTAssertFalse(environment.permitsCapture, "reconnect/activity cannot acknowledge the user")
            }
        }
    }

    func testIdleAndUnknownActivityCloseCanonicalArchiveWithoutApprovalOrUserPause() async throws {
        for unknown in [false, true] {
            let root = try root()
            let intent = try await arm(root, continuous: true)
            let capture = try await chunk(root: root)
            var now: TimeInterval = 0
            var idle: TimeInterval? = 1_000
            let environment = CaptureSourceEnvironment(consoleSession: { true },
                idleSeconds: { idle }, uptime: { now })
            XCTAssertTrue(environment.acknowledgeCurrentUser())
            let screen = ScreenCaptureSingleFlight()
            XCTAssertTrue(screen.open(eligible: { environment.permitsCapture }))
            let close = CaptureLocalClose()
            var closing: Task<Void, Never>?
            var closes = 0
            environment.onRevocation = {
                _ = intent.beginShutdown()
                screen.close()
                closes += 1
                closing = Task {
                    _ = await close.run(budgetNanoseconds: 1_000_000_000, close: {
                        _ = try await capture.runtime.close(endedAt: Timestamps.iso8601())
                    }, recoveryRequired: { intent.completeRecovery(succeeded: false) })
                }
            }
            now = 300
            if unknown { idle = nil }
            XCTAssertEqual(environment.revokeForInactivity(try CaptureChunkBoundary(), hasOpenSpan: false),
                unknown ? .unknown : .idle)
            XCTAssertTrue(screen.isClosedAndQuiescent, "physical admission closes before awaited journal drain")
            XCTAssertFalse(intent.isArmed)
            XCTAssertFalse(intent.userPaused)
            await closing?.value
            XCTAssertEqual(closes, 1)
            XCTAssertTrue(close.settled)
            let snapshot = await capture.journal.snapshot()
            XCTAssertEqual(snapshot.lifecycle, .committed)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            XCTAssertFalse(files.allObjects.compactMap { $0 as? URL }.contains { $0.pathExtension == "jazz-archive" })
            let reopened = CaptureStartIntent(root: root, continuous: true, durability: durability)
            XCTAssertTrue(reopened.requiresResume)
            XCTAssertNil(reopened.requestStart(explicit: false))
            // A deliberate later Resume, not an idle/activity callback, establishes a new interval.
            idle = 1_000
            now = 600
            XCTAssertTrue(environment.acknowledgeCurrentUser())
            XCTAssertNil(environment.revokeForInactivity(try CaptureChunkBoundary(), hasOpenSpan: false))
        }
    }

    func testLabeledNarratedAndWorkshopLimitsDisarmOriginalOwnerWithoutMicrophoneContinuation() async throws {
        for kind in ["label", "narration", "workshop", "unknown"] {
            let root = try root()
            let intent = try await arm(root, continuous: true)
            let environment = CaptureSourceEnvironment(consoleSession: { true })
            XCTAssertTrue(environment.acknowledgeCurrentUser())
            environment.onRevocation = { _ = intent.beginShutdown() }
            let generation = intent.generation
            // Controller passes hasOpenSpan for open labels, native narration, retained label
            // closes and workshops, before synchronously fencing/closing those same sources.
            XCTAssertNil(intent.requestRotation(reason: kind == "unknown" ? .unknown : .bytes,
                hasOpenSpan: kind != "unknown"))
            XCTAssertFalse(intent.isArmed, kind)
            XCTAssertNotEqual(intent.generation, generation)
            XCTAssertNil(intent.requestRotation())
            environment.revoke() // controller's STOP path also removes live OS acknowledgment
            environment.receive(.wake)
            XCTAssertFalse(environment.permitsCapture, "even continuous reconnect cannot re-arm")
            XCTAssertFalse(intent.userPaused, "boundary stop does not manufacture user Pause")
        }
    }

    func testPauseBeforeRotationTaskAndAfterReplacementAwaitCannotRearmOrReportResume() async throws {
        for stage in ["scheduled", "returned"] {
            let intent = try await arm(try root())
            let token = try XCTUnwrap(intent.requestRotation())
            if stage == "scheduled" { intent.pause() }
            let resumed = await intent.runRotation(token, close: {
                XCTAssertEqual(stage, "returned"); return true
            }, eligible: { true }, start: { token in
                let started = await intent.runStart(token, recovery: { true }, prepare: { true }, enable: { true }, abort: {})
                intent.pause() // same interleaving as Stop before the caller resumes from task.value
                return started
            })
            XCTAssertFalse(resumed)
            XCTAssertFalse(intent.isArmed)
            XCTAssertFalse(intent.isRotating)
            XCTAssertFalse(intent.isStarting)
        }
    }

    func testStopDuringReplacementPreparationNeverEnablesSources() async throws {
        for continuous in [false, true] {
            let intent = try await arm(try root(), continuous: continuous)
            let token = try XCTUnwrap(intent.requestRotation())
            let gate = Gate()
            let entered = expectation(description: "replacement preparing")
            var aborted = 0
            let rotating = Task {
                await intent.runRotation(token, close: { true }, eligible: { true }, start: { token in
                    await intent.runStart(token, recovery: { true }, prepare: {
                        entered.fulfill(); await gate.wait(); return true
                    }, enable: { XCTFail("Stop re-enabled sources"); return true }, abort: { aborted += 1 })
                })
            }
            await fulfillment(of: [entered], timeout: 1)
            intent.pause()
            await gate.release()
            let resumed = await rotating.value
            XCTAssertFalse(resumed)
            XCTAssertEqual(aborted, 1)
            XCTAssertFalse(intent.isStarting)
            XCTAssertFalse(intent.isArmed)
        }
    }

    func testNoticeScopeAuthorityManagedAndResourcesRecheckedAfterCloseAndPreparation() async throws {
        for change in ["notice", "scope", "authority", "managed", "resource"] {
            for stage in ["close", "prepare"] {
                let root = try root()
                let intent = try await arm(root)
                var input = CaptureSetupInput(snapshot: .init(user: "test", machine: "fake", company: "company",
                    area: "area", destination: "offline", enrollmentIdentity: "device", enrollmentProfile: "synthetic",
                    continuous: false, screenshots: false, narration: false, coachLive: false,
                    delivery: .confirmedArchive, localOnly: true, exclusions: [], managedConfiguration: ""),
                    accessibilityGranted: true, screenGranted: false, microphoneGranted: false)
                let setup = CaptureSetupReadiness(input: { input }, read: { nil }, write: { _ in })
                XCTAssertTrue(setup.acknowledge())
                XCTAssertTrue(setup.admit())
                setup.onRevocation = { _ = intent.beginShutdown() }
                let environment = CaptureSourceEnvironment(consoleSession: { true })
                XCTAssertTrue(environment.acknowledgeCurrentUser())
                environment.onRevocation = { _ = intent.beginShutdown() }
                var free: Int64 = 1_024
                let resources = CaptureResourceAdmission(environment: environment, reserveSetting: { "512" },
                    capacity: { _ in .init(availableBytes: free, sampledAtUptime: 1) }, uptime: { 1 })
                let eligible = { setup.permitsAdmission() && environment.permitsCapture && resources.check(paths: [root]) }
                let mutate = {
                    switch change {
                    case "notice": input.snapshot.noticeVersion += 1
                    case "scope": input.snapshot.area = "other"
                    case "authority": setup.revoke()
                    case "managed": input.managedPresent = true; input.snapshot.managedConfiguration = "removed/changed"
                    default: free = 511
                    }
                }
                let token = try XCTUnwrap(intent.requestRotation())
                let resumed = await intent.runRotation(token, close: {
                    if stage == "close" { mutate() }; return true
                }, eligible: eligible, start: { token in
                    await intent.runStart(token, recovery: { true }, prepare: {
                        mutate(); return true
                    }, enable: { XCTFail("\(change) after \(stage) enabled"); return true }, abort: {}, eligible: eligible)
                })
                XCTAssertFalse(resumed, "\(change)/\(stage)")
                XCTAssertFalse(intent.isArmed)
            }
        }
    }

    func testFailedOrTimedOutCloseRetainsClaimAndNeverRevisesContinuation() async throws {
        for timeout in [false, true] {
            let root = try root()
            let bytes = Data("sole synthetic original".utf8)
            let claim = try JazzArchiveWritableFileClaim.prepare(root: root, archiveId: Identifiers.newArchiveId(),
                captureId: Identifiers.newCaptureId(), artifactId: Identifiers.newArtifactId(), fileExtension: "m4a")
            try bytes.write(to: claim.recordingURL)
            let intent = try await arm(root)
            let token = try XCTUnwrap(intent.requestRotation())
            let gate = Gate()
            let close = CaptureLocalClose()
            let resumed = await intent.runRotation(token, close: {
                let outcome = await close.run(budgetNanoseconds: 5_000_000, close: {
                    if timeout { await gate.wait() } else { throw CocoaError(.fileWriteOutOfSpace) }
                }, recoveryRequired: { intent.completeRecovery(succeeded: false) })
                return outcome == .settled && close.settled
            }, eligible: { true }, start: { _ in XCTFail("failed close restarted"); return true })
            XCTAssertFalse(resumed)
            XCTAssertFalse(intent.isArmed)
            await gate.release()
            for _ in 0..<100 where !close.physicallyReturned { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(close.outcome, .recoveryRequired)
            XCTAssertFalse(close.settled)
            XCTAssertEqual(try Data(contentsOf: claim.recordingURL), bytes)
            claim.abandon()
        }
    }

    func testRuntimeAndJournalBudgetIncludeProducedMediaAndCanonicalCopy() async throws {
        let root = try root()
        let capture = try await chunk(root: root)
        let before = try XCTUnwrap(capture.journal.chunkBytes.measured)
        var event = capture.event
        event.sequence = 1
        event.eventId = Identifiers.eventId(sessionId: event.sessionId, sequence: 1)
        event.eventType = "narration"
        let outcome = CaptureJournalActivityOutcome.observation(.init(event: event,
            artifact: .init(bytes: Data(repeating: 1, count: 1_048_576), kind: "narration_audio",
                mediaType: "audio/mp4", role: "narration_audio", sourceRole: "microphone_capture", actorRole: "narrator",
                privacy: .init(status: .captured, policyVersion: "test-v1"))))
        _ = try await capture.runtime.submit { _ in outcome }
        await capture.runtime.waitForAdmittedWork()
        let after = try XCTUnwrap(capture.journal.chunkBytes.measured)
        XCTAssertGreaterThanOrEqual(after - before, 2 * 1_048_576)
        _ = try await capture.runtime.close(endedAt: Timestamps.iso8601())
    }

    func testNativePendingAndClosedBytesAreChargedBeforeFinalizationWithoutDeletingMedia() async throws {
        let root = try root()
        let file = root.appendingPathComponent("synthetic.m4a")
        let data = Data(repeating: 1, count: 512)
        try data.write(to: file)
        let budget = CaptureChunkBytes()
        let recorder = NarrationRecorder(canAdmit: { true }, makeSources: { _, _ in
            .init(isRecording: { true }, stopRecording: {}, stopPCM: {}, drainPCM: {})
        }, probe: { _ in })
        recorder.onClosedBytes = { budget.add($0 ?? -1, copies: 2) }
        _ = try recorder.start(at: file, persistStart: { _ in }, persistStop: { _, _ in })
        XCTAssertEqual(recorder.pendingByteCount, 1_024)
        let stopped = recorder.stop()
        XCTAssertEqual(budget.measured, 1_024, "pending original charged synchronously, before first await")
        XCTAssertEqual(recorder.pendingByteCount, 0, "closed bytes now belong to cumulative budget")
        _ = await stopped?.value
        await recorder.waitForQuiescence()
        XCTAssertEqual(try Data(contentsOf: file), data)
        _ = try recorder.start(at: root.appendingPathComponent("missing.m4a"), persistStart: { _ in }, persistStop: { _, _ in })
        XCTAssertNil(recorder.pendingByteCount, "unknown active native file must not count as zero")
        _ = await recorder.stop()?.value
        await recorder.waitForQuiescence()
        XCTAssertNil(budget.measured, "unknown native close is sticky until explicit fresh capture")
    }

    private struct Chunk {
        let journal: CaptureJournal
        let runtime: CaptureJournalRuntime
        let manifest: JazzArchiveManifest
        let session: JazzArchiveSession
        let event: ActivityEvent
    }
    private let origin = Identifiers.newOriginId()
    private let actor = Identifiers.newActorId()
    private let source = Identifiers.newSourceId()

    private func chunk(root: URL) async throws -> Chunk {
        let archive = Identifiers.newArchiveId(), capture = Identifiers.newCaptureId()
        let stream = Identifiers.newStreamId(), legacy = Identifiers.newSessionId()
        let time = Timestamps.iso8601()
        let producer = JazzArchiveProducer(name: "Synthetic", version: "test", platform: "macOS")
        let manifest = JazzArchiveManifest(archiveId: archive, originId: origin, createdAt: time, producer: producer,
            actors: [.init(actorId: actor, kind: .human, identityStatus: .identified, displayName: "Fake",
                provenance: .init(factClass: .declared, sources: []))],
            sources: [.init(sourceId: source, kind: "macos.native", actorId: actor, producer: producer,
                capabilities: [], provenance: .init(factClass: .observed, sources: []))],
            sessions: [.init(captureId: capture, legacySessionId: legacy)])
        let session = JazzArchiveSession(captureId: capture, legacySessionId: legacy, archiveId: archive,
            streamIds: [stream], startedAt: time, recorderActorId: actor, sourceIds: [source],
            area: .init(areaId: "test-area", nameSnapshot: "Synthetic Area"),
            capturePolicy: .init(policyVersion: "test-v1", consentedAt: time, modalities: [.pointer, .narration],
                excludedApplications: [], businessDataCapture: false), quality: .init(status: .complete))
        let journal = CaptureJournal(root: root, durability: durability,
            leaseProvider: JazzArchiveFilesystemPlatform.captureJournalLeaseProvider)
        _ = try await journal.begin(manifest: manifest, session: session)
        let runtime = CaptureJournalRuntime(journal: journal, context: .init(originId: origin, captureId: capture,
            streamId: stream, sourceId: source, actorId: actor, policyVersion: "test-v1"))
        let event = ActivityEvent(sessionId: legacy, eventId: Identifiers.eventId(sessionId: legacy, sequence: 0),
            sequence: 0, timestamp: time, eventType: "session_start", url: "app://synthetic")
        _ = try await runtime.submit { _ in .observation(.init(event: event)) }
        await runtime.waitForAdmittedWork()
        return Chunk(journal: journal, runtime: runtime, manifest: manifest, session: session, event: event)
    }
}
