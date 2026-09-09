import Foundation
import XCTest
@testable import JazzCapture
@testable import JazzCaptureCore

/// Uses the resource/environment/source/close seams actually invoked by CaptureController.
/// No controller initialization, OS observers, native capture, credentials or delivery services.
@MainActor
final class CaptureResourceAdmissionTests: XCTestCase {
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

    func testInitialLowUnknownInvalidStaleAndFailedProbeDenyAdmissionWithoutArchiveOrClaims() async throws {
        for fault in ["low", "unknown", "invalid", "stale", "error", "setting"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let environment = CaptureSourceEnvironment(consoleSession: { true })
            XCTAssertTrue(environment.acknowledgeCurrentUser())
            let admission = CaptureResourceAdmission(environment: environment,
                reserveSetting: { fault == "setting" ? "-1" : "512" }, capacity: { _ in
                    if fault == "error" { throw NSError(domain: NSPOSIXErrorDomain, code: 5) }
                    return .init(availableBytes: fault == "unknown" ? nil : fault == "invalid" ? -1 : fault == "low" ? 511 : 1_024,
                        sampledAtUptime: fault == "stale" ? 1 : 10)
                }, uptime: { 10 })
            var revoked = 0
            environment.onRevocation = { revoked += 1 }
            var shownError: String?
            admission.onFailure = { shownError = $0 }
            // requestStart checks this BEFORE intent persistence, archive preparation or claims.
            if admission.check(paths: [root.appendingPathComponent("archives"), root], explicitRetry: true) {
                XCTFail("initial \(fault) capacity admitted archive preparation")
                _ = try JazzArchiveWritableFileClaim.prepare(root: root,
                    archiveId: Identifiers.newArchiveId(), captureId: Identifiers.newCaptureId(),
                    artifactId: Identifiers.newArtifactId(), fileExtension: "m4a")
            }
            let recorder = NarrationRecorder(canAdmit: {
                admission.check(paths: [root]) && environment.permitsCapture
            }, makeSources: { _, _ in
                XCTFail("disk failure admitted native recorder")
                throw NarrationRecorderError.recordingDidNotStart
            })
            XCTAssertThrowsError(try recorder.start(at: root.appendingPathComponent("never.m4a"),
                persistStart: { _ in XCTFail("no new narration admission metadata") }, persistStop: { _, _ in }))
            XCTAssertEqual(revoked, 1, "failure is latched, not a recursive close")
            XCTAssertNotNil(shownError)
            XCTAssertFalse(environment.permitsCapture)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "no archive, claim or intent created")
        }
    }

    func testFreshChecksCoverEachDestinationAndCapacityRecoveryCannotResumeOrErasePause() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archives")
        let paths = [archive, root]
        let intent = CaptureStartIntent(root: root, continuous: true,
            durability: JazzArchiveFilesystemPlatform.durability)
        intent.pause()
        let environment = CaptureSourceEnvironment(consoleSession: { true })
        XCTAssertTrue(environment.acknowledgeCurrentUser())
        var available: Int64 = 1_024
        var setting = "512"
        var seen: [URL] = []
        let admission = CaptureResourceAdmission(environment: environment,
            reserveSetting: { setting }, capacity: { path in
                seen.append(path)
                return .init(availableBytes: path == archive ? available : .max, sampledAtUptime: 10)
            }, uptime: { 10 })
        environment.onRevocation = { _ = intent.beginShutdown() }
        XCTAssertTrue(admission.check(paths: paths))
        available = 511 // Other volume's ample space must not compensate for the archive volume.
        XCTAssertFalse(admission.check(paths: paths))
        XCTAssertEqual(seen, paths + paths, "each check requests fresh capacity on the supplied destinations")
        available = 1_024
        XCTAssertFalse(admission.check(paths: paths), "capacity recovery is not Resume")
        XCTAssertTrue(admission.check(paths: paths, explicitRetry: true))
        XCTAssertFalse(environment.permitsCapture, "disk retry is not OS/user acknowledgment")
        XCTAssertTrue(intent.userPaused, "resource suspension never replaces persisted Pause")
        setting = "2048"
        XCTAssertFalse(admission.check(paths: paths), "live configuration is validated, not frozen/cached")
        XCTAssertTrue(CaptureStartIntent(root: root, continuous: true,
            durability: JazzArchiveFilesystemPlatform.durability).userPaused)
    }

    func testProspectiveDeliveryPolicySelectsOnlyItsDestinationsOnRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = root.appendingPathComponent("archives", isDirectory: true)
        let shots = root.appendingPathComponent("shots", isDirectory: true)
        for unavailable in [false, true] {
            let environment = CaptureSourceEnvironment(consoleSession: { true })
            var checked: [URL] = []
            let admission = CaptureResourceAdmission(environment: environment,
                reserveSetting: { "512" }, capacity: { path in
                    checked.append(path)
                    if path == shots && unavailable { throw CocoaError(.fileReadNoPermission) }
                    return .init(availableBytes: path == shots ? 0 : 1_024, sampledAtUptime: 10)
                }, uptime: { 10 })
            // Use the controller's production destination selection for BOTH policy switches.
            // A failed compatibility check must not poison a subsequent explicit local-only Start.
            for policy in [JazzCaptureDeliveryPolicy.liveCompatibility, .confirmedArchive, .liveCompatibility] {
                checked.removeAll()
                let paths = CaptureResourceAdmission.storagePaths(
                    archiveRoot: archive, spoolRoot: root, deliveryPolicy: policy, captureCoachLive: false)
                XCTAssertEqual(admission.check(paths: paths, explicitRetry: true),
                    policy == .confirmedArchive)
                XCTAssertEqual(checked.contains(shots), policy.usesLiveCompatibilityProjection)
                if policy == .confirmedArchive { XCTAssertEqual(checked, [archive, root]) }
            }
        }
    }

    func testNoCachedOrInitiallyFreshSampleCanBypassFinalFreshnessCheck() {
        let path = FileManager.default.temporaryDirectory
        for mode in ["old", "slow", "second-volume"] {
            let environment = CaptureSourceEnvironment(consoleSession: { true })
            var now: TimeInterval = 10
            var calls = 0
            let admission = CaptureResourceAdmission(environment: environment,
                reserveSetting: { "1" }, capacity: { _ in
                    calls += 1
                    if mode == "slow" { now += 4 }
                    if mode == "second-volume" && calls == 2 { now += 4 }
                    return .init(availableBytes: .max, sampledAtUptime: mode == "old" ? 1 : 10)
                }, uptime: { now })
            XCTAssertFalse(admission.check(paths: [path, path]), mode)
            XCTAssertTrue(admission.failure?.contains("stale") == true)
        }
    }

    func testLossBeforePostRecoveryPreparationDoesNotCreateArchiveOrEnableSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = CaptureStartIntent(root: root, continuous: true,
            durability: JazzArchiveFilesystemPlatform.durability)
        let environment = CaptureSourceEnvironment(consoleSession: { true })
        environment.onRevocation = { _ = intent.beginShutdown() }
        var available: Int64 = 512
        let admission = CaptureResourceAdmission(environment: environment, reserveSetting: { "512" },
            capacity: { _ in .init(availableBytes: available, sampledAtUptime: 10) }, uptime: { 10 })
        XCTAssertTrue(admission.check(paths: [root], explicitRetry: true))
        let token = try XCTUnwrap(intent.requestStart(explicit: true))
        let started = await intent.runStart(token, recovery: {
            available = 511
            intent.completeRecovery(succeeded: true)
            return true
        }, prepare: {
            guard admission.check(paths: [root]) else { return false }
            XCTFail("disk loss across recovery admitted an archive")
            return true
        }, enable: { XCTFail("disk loss enabled native sources"); return true }, abort: {})
        XCTAssertFalse(started)
        XCTAssertFalse(intent.userPaused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("archives").path))
    }

    func testActiveAndLabelCapacityLossFencesSourcesAndUsesBoundedRetainedClose() async throws {
        for mode in ["capture", "label", "label-drain"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let originals = ["canonical.draft", "journal.wal", "receipt.json", "package.jazz-archive", "queue.json"]
            let bytes = Data("synthetic original bytes — no eviction on pressure".utf8)
            for name in originals { try bytes.write(to: root.appendingPathComponent(name)) }
            let claim = try JazzArchiveWritableFileClaim.prepare(root: root,
                archiveId: Identifiers.newArchiveId(), captureId: Identifiers.newCaptureId(),
                artifactId: Identifiers.newArtifactId(), fileExtension: "m4a")
            try bytes.write(to: claim.recordingURL)
            let intent = CaptureStartIntent(root: root, continuous: true,
                durability: JazzArchiveFilesystemPlatform.durability)
            let environment = CaptureSourceEnvironment(consoleSession: { true })
            XCTAssertTrue(environment.acknowledgeCurrentUser())
            var available: Int64 = 512
            let admission = CaptureResourceAdmission(environment: environment, reserveSetting: { "512" },
                capacity: { _ in .init(availableBytes: available, sampledAtUptime: 10) }, uptime: { 10 })
            let screen = ScreenCaptureSingleFlight()
            let ax = CaptureAXAdmission(accepting: true)
            var recording = false
            var pcmStopped = false
            let narration = NarrationRecorder(canAdmit: {
                environment.permitsCapture && admission.check(paths: [root])
            }, makeSources: { _, _ in
                recording = true
                return .init(isRecording: { recording }, stopRecording: { recording = false },
                    stopPCM: { pcmStopped = true }, drainPCM: {})
            }, probe: { _ in })
            intent.completeRecovery(succeeded: true)
            let token = try XCTUnwrap(intent.requestStart(explicit: true))
            let started = await intent.runStart(token, recovery: { true }, prepare: {
                admission.check(paths: [root])
            }, enable: { screen.open(eligible: { admission.check(paths: [root]) && environment.permitsCapture }) }, abort: {})
            XCTAssertTrue(started)
            let oldScreen = screen.admission
            if mode != "capture" {
                _ = try narration.start(at: claim.recordingURL, persistStart: { _ in }, persistStop: { _, _ in })
            }
            let gate = Gate()
            defer { Task { await gate.release() } }
            let label = CaptureLabelClose()
            if mode == "label-drain" {
                screen.close()
                ax.revoke()
                _ = narration.stop()
                label.begin(drain: { await gate.wait() },
                    recoveryRequired: { intent.completeRecovery(succeeded: false) }, reopen: {
                        guard environment.permitsCapture, intent.generation == token else { return false }
                        return screen.open(eligible: { admission.check(paths: [root]) })
                    })
            }
            let close = CaptureLocalClose()
            var shutdown: Task<CaptureLocalClose.Outcome, Never>?
            var commits = 0
            environment.onRevocation = {
                _ = intent.beginShutdown()
                screen.close()
                ax.revoke()
                _ = narration.stop()
                let labelTask = label.task
                shutdown = Task {
                    await close.run(budgetNanoseconds: 30_000_000, close: {
                        _ = await labelTask?.value
                        try Task.checkCancellation()
                        try await CaptureLocalClose.drain(narration: narration, screen: screen, ax: ax,
                            labelTail: nil, audioTail: nil, coachLive: nil, journalAdmission: { nil },
                            runtime: nil, coachActions: nil, orderedProjection: nil, commit: { commits += 1 })
                    }, recoveryRequired: { intent.completeRecovery(succeeded: false) })
                }
            }
            available = 511
            // This is also the controller's periodic capability-timer resource check while a label
            // drain has fenced physical input but the logical capture remains active.
            XCTAssertFalse(admission.check(paths: [root]))
            XCTAssertFalse(screen.permits(oldScreen))
            XCTAssertFalse(ax.permitsReads)
            XCTAssertFalse(recording)
            if mode != "capture" { XCTAssertTrue(pcmStopped) }
            XCTAssertFalse(intent.userPaused)
            let result = await (try XCTUnwrap(shutdown)).value
            XCTAssertEqual(result, mode == "label-drain" ? .recoveryRequired : .settled)
            XCTAssertEqual(commits, mode == "label-drain" ? 0 : 1, "local commit is not package finalization/enqueue")
            available = 1_024
            XCTAssertFalse(admission.check(paths: [root]), "no automatic Resume")
            await gate.release()
            _ = await label.task?.value
            for _ in 0..<200 where !close.physicallyReturned { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(close.physicallyReturned)
            XCTAssertTrue(screen.isClosedAndQuiescent)
            XCTAssertEqual(close.outcome, result, "late label settlement cannot erase deadline failure")
            for name in originals { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), bytes) }
            XCTAssertEqual(try Data(contentsOf: claim.recordingURL), bytes)
            claim.abandon()
        }
    }

    func testKnownScreenshotAndSealedCopyBytesSuspendNewWorkButKeepOriginalOutcome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("already produced screenshot/audio".utf8)
        let writable = try JazzArchiveWritableFileClaim.prepare(root: root,
            archiveId: Identifiers.newArchiveId(), captureId: Identifiers.newCaptureId(),
            artifactId: Identifiers.newArtifactId(), fileExtension: "m4a")
        try bytes.write(to: writable.recordingURL)
        let claim = try writable.seal(durability: JazzArchiveFilesystemPlatform.durability)
        XCTAssertEqual(claim.byteLength, Int64(bytes.count))
        for payload in [CaptureJournalArtifactPayload.bytes(bytes), .claimedFile(claim)] {
            let environment = CaptureSourceEnvironment(consoleSession: { true })
            XCTAssertTrue(environment.acknowledgeCurrentUser())
            let admission = CaptureResourceAdmission(environment: environment, reserveSetting: { "512" },
                capacity: { _ in .init(availableBytes: 512 + Int64(bytes.count) - 1, sampledAtUptime: 10) }, uptime: { 10 })
            var artifact = CaptureJournalArtifactInput(bytes: bytes, kind: "screenshot", mediaType: "image/jpeg",
                role: "screenshot", sourceRole: "screen_capture", actorRole: "performer",
                privacy: .init(status: .captured, policyVersion: "consent-v1"))
            artifact.payload = payload
            let outcome = CaptureJournalActivityOutcome.observation(.init(event: ActivityEvent(
                sessionId: Identifiers.newSessionId(), eventId: "synthetic", sequence: 0,
                timestamp: Timestamps.iso8601(), eventType: "click", url: "app://synthetic"), artifact: artifact))
            XCTAssertTrue(admission.check(paths: [root]), "reserve alone fits")
            // Called by the controller's runtime.submit wrapper AFTER the producer's last await.
            XCTAssertEqual(admission.preservingAdmittedOutcome(outcome, paths: [root]), outcome)
            XCTAssertNotNil(admission.failure, "imminent bytes must be accounted for")
            XCTAssertFalse(environment.permitsCapture)
            XCTAssertEqual(try Data(contentsOf: claim.url), bytes)
        }
    }

    func testNativeProbeUsesExistingDestinationOrParentWithoutCreatingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let newArchive = root.appendingPathComponent("archives/new-capture")
        let sample = try CaptureVolumeCapacity.sample(at: newArchive)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sample.availableBytes), 0)
        XCTAssertLessThanOrEqual(sample.sampledAtUptime, ProcessInfo.processInfo.systemUptime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newArchive.path))
        let link = root.appendingPathComponent("archive-volume")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertNotNil(try CaptureVolumeCapacity.sample(at: link.appendingPathComponent("new")).availableBytes)
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try CaptureVolumeCapacity.sample(at: dangling))
        XCTAssertThrowsError(try CaptureVolumeCapacity.sample(at: URL(string: "https://example.invalid")!))
    }
}
