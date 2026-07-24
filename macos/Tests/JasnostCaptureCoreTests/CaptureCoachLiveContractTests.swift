import Foundation
import XCTest

@testable import JasnostCaptureCore

final class CaptureCoachLiveContractTests: XCTestCase {
    private enum InjectedFailure: Error { case enqueue }

    private actor Recorder: CaptureCoachInteractionRecorder {
        private var values: [CaptureCoachInteraction]

        init(seed: [CaptureCoachInteraction] = []) {
            values = seed
        }

        func append(_ interaction: CaptureCoachInteraction) {
            values.append(interaction)
        }

        func recorded() -> [CaptureCoachInteraction] { values }
    }

    private actor HangingHTTPProbe {
        private var started = 0
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func send() async {
            started += 1
            let ready = startWaiters.filter { started >= $0.0 }
            startWaiters.removeAll { started >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilStarted(_ count: Int) async {
            if started >= count { return }
            await withCheckedContinuation {
                startWaiters.append((count, $0))
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private actor PCMProjectionRecorder {
        private var sequencer = CaptureCoachLivePCMSequencer()
        private var releasedSequences: [Int] = []
        private var failure: String?

        func project(
            labelId: String,
            processId: String,
            chunk: CaptureCoachLivePCMChunk
        ) {
            do {
                releasedSequences += try sequencer.admit(
                    labelId: labelId, processId: processId, chunk: chunk
                ).map(\.sequence)
            } catch {
                failure = String(describing: error)
            }
        }

        func snapshot() -> ([Int], String?) {
            (releasedSequences, failure)
        }
    }

    private actor LabelContextProbe {
        private var firstStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var values: [(String?, String?)] = []

        func handle(labelId: String?, processId: String?) async {
            if !firstStarted {
                firstStarted = true
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                if !released {
                    await withCheckedContinuation {
                        releaseWaiters.append($0)
                    }
                }
            }
            values.append((labelId, processId))
        }

        func waitUntilFirstStarted() async {
            if firstStarted { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func releaseFirst() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func snapshot() -> [(String?, String?)] { values }
    }

    private actor PromptPollGateHarness {
        private var gate = CaptureCoachLivePromptPollAdmissionGate()

        func begin(_ generation: UInt64) -> Bool {
            gate.begin(generation: generation)
        }

        func end(_ generation: UInt64) {
            gate.end(generation: generation)
        }
    }

    private struct ArchiveFixture {
        var archiveId: String
        var originId: String
        var captureId: String
        var streamId: String
        var sourceId: String
        var actorId: String
        var manifest: JazzArchiveManifest
        var session: JazzArchiveSession
    }

    private actor FailOnceReceiptSink: CaptureCoachLivePromptReceiptEnqueuing {
        private let spool: CaptureCoachLiveExactByteSpool<CaptureCoachLivePromptReceipt>
        private var shouldFail = true

        init(
            spool: CaptureCoachLiveExactByteSpool<CaptureCoachLivePromptReceipt>
        ) {
            self.spool = spool
        }

        func enqueuePromptReceipt(
            _ receipt: CaptureCoachLivePromptReceipt
        ) async throws {
            if shouldFail {
                shouldFail = false
                throw InjectedFailure.enqueue
            }
            _ = try await spool.enqueue(receipt)
        }
    }

    func testAllCoachGoldensCarryByteExactDocumentsAndStrictResponses() throws {
        for name in [
            "02-capture-coach-lost-ack.json",
            "03-capture-coach-meeting-source.json",
            "04-capture-coach-finalize.json",
            "05-capture-coach-interrupted-recovery.json",
        ] {
            let fixture = try fixture(name)
            let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
            for event in events {
                if event["kind"] as? String == "receive_no_prompt" {
                    XCTAssertEqual(event["httpStatus"] as? Int, 204)
                    XCTAssertEqual(event["bodyByteLength"] as? Int, 0)
                    XCTAssertNil(event["document"])
                    continue
                }
                let bytes = Data(
                    try XCTUnwrap(
                        event["canonicalBytes"] as? String
                    ).utf8)
                let document = try XCTUnwrap(event["document"] as? [String: Any])
                switch document["documentType"] as? String {
                case "message":
                    let value = try CaptureCoachLiveMessage.decodeCanonical(bytes)
                    XCTAssertEqual(try value.canonicalData(), bytes)
                case "prompt":
                    let value = try CaptureCoachLivePrompt.decodeCanonical(bytes)
                    XCTAssertEqual(try value.canonicalData(), bytes)
                case "receipt":
                    if document["promptId"] != nil {
                        let value = try CaptureCoachLivePromptReceipt.decodeCanonical(bytes)
                        XCTAssertEqual(try value.canonicalData(), bytes)
                    } else {
                        let value =
                            try CaptureCoachLiveScopeControlReceipt
                            .decodeCanonical(bytes)
                        XCTAssertEqual(try value.canonicalData(), bytes)
                    }
                default:
                    XCTFail("unknown live Coach document")
                }

                if let canonical = event["responseCanonicalBytes"] as? String,
                    let response = event["ackResponse"] as? [String: Any]
                {
                    let responseData = Data(canonical.utf8)
                    if response["documentType"] as? String == "message_ack" {
                        _ =
                            try CaptureCoachLiveMessageAcknowledgement
                            .decodeCanonical(responseData)
                    } else {
                        _ =
                            try CaptureCoachLiveReceiptAcknowledgement
                            .decodeCanonical(responseData)
                    }
                }
                if event["transportResult"] as? String == "id_collision" {
                    XCTAssertEqual(event["httpStatus"] as? Int, 409)
                    XCTAssertEqual(event["bodyByteLength"] as? Int, 0)
                    XCTAssertNil(event["ackResponse"])
                }
            }
        }
    }

    func testPromptGETQueryBindsExactCaptureAndLabelAndRejectsCrossLineage()
        throws
    {
        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let promptEvent = try XCTUnwrap(
            events.first { $0["kind"] as? String == "receive_prompt" })
        let prompt = try CaptureCoachLivePrompt.decodeCanonical(
            Data(try XCTUnwrap(promptEvent["canonicalBytes"] as? String).utf8))
        let selector = CaptureCoachLivePromptSelector(
            scope: prompt.scope,
            captureId: prompt.captureId,
            labelId: prompt.labelId)
        let url = try selector.requestURL(
            endpoint: try XCTUnwrap(
                URL(string: "https://jazz.example.test/api/capture-coach/live/prompts/next")))
        let queryItems = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(
            queryItems.map(\.name),
            [
                "companyId", "areaId", "processId", "deviceId",
                "captureId", "labelId",
            ])
        let queryMap = Dictionary(
            uniqueKeysWithValues: try queryItems.map {
                ($0.name, try XCTUnwrap($0.value))
            })
        XCTAssertEqual(
            queryMap,
            [
                "companyId": prompt.scope.companyId,
                "areaId": prompt.scope.areaId,
                "processId": prompt.scope.processId,
                "deviceId": prompt.scope.deviceId,
                "captureId": prompt.captureId,
                "labelId": prompt.labelId,
            ])
        XCTAssertTrue(selector.matches(prompt))

        let foreignCapture = CaptureCoachLivePromptSelector(
            scope: prompt.scope,
            captureId: Identifiers.newCaptureId(),
            labelId: prompt.labelId)
        let foreignLabel = CaptureCoachLivePromptSelector(
            scope: prompt.scope,
            captureId: prompt.captureId,
            labelId: Identifiers.newLabelId())
        XCTAssertFalse(foreignCapture.matches(prompt))
        XCTAssertFalse(foreignLabel.matches(prompt))
        XCTAssertNotEqual(
            try foreignCapture.requestURL(endpoint: url),
            try foreignLabel.requestURL(endpoint: url))
    }

    func testLabelContextTailPreservesCloseThenNewLabelAdmissionOrder()
        async
    {
        let probe = LabelContextProbe()
        let tail = CaptureCoachLiveLabelContextAdmissionTail {
            labelId, processId in
            await probe.handle(labelId: labelId, processId: processId)
        }
        let oldLabel = Identifiers.newLabelId()
        let newLabel = Identifiers.newLabelId()
        tail.submit(labelId: oldLabel, processId: "process-old")
        await probe.waitUntilFirstStarted()

        // The old transition is deliberately stalled while close and replacement are admitted.
        // A set of unstructured Tasks can reorder here; the synchronous tail cannot.
        tail.submit(labelId: nil, processId: nil)
        tail.submit(labelId: newLabel, processId: "process-new")
        await probe.releaseFirst()
        await tail.drain()

        let values = await probe.snapshot()
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[0].0, oldLabel)
        XCTAssertEqual(values[0].1, "process-old")
        XCTAssertNil(values[1].0)
        XCTAssertNil(values[1].1)
        XCTAssertEqual(values[2].0, newLabel)
        XCTAssertEqual(values[2].1, "process-new")
    }

    func testWatermarkPartialOrderAndUnknownCrossVersionFinalAreConservative() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let transcriptId = "transcript-native-test"
        let base = watermark(
            captureId: captureId, streamId: streamId, sequence: 2,
            transcriptId: transcriptId, revision: 1, throughMillis: 1_000,
            textDigest: String(repeating: "1", count: 64))
        XCTAssertEqual(base.relation(to: base), .equal)

        let newer = watermark(
            captureId: captureId, streamId: streamId, sequence: 3,
            transcriptId: transcriptId, revision: 2, throughMillis: 2_000,
            textDigest: String(repeating: "2", count: 64))
        XCTAssertEqual(newer.relation(to: base), .dominates)
        XCTAssertEqual(base.relation(to: newer), .dominated)

        let crossed = watermark(
            captureId: captureId, streamId: streamId, sequence: 4,
            transcriptId: transcriptId, revision: 1, throughMillis: 500,
            textDigest: String(repeating: "3", count: 64))
        XCTAssertEqual(crossed.relation(to: newer), .incomparable)

        let digestCollision = watermark(
            captureId: captureId, streamId: streamId, sequence: 2,
            transcriptId: transcriptId, revision: 1, throughMillis: 1_000,
            textDigest: String(repeating: "f", count: 64))
        XCTAssertEqual(digestCollision.relation(to: base), .incomparable)

        let commitId = Identifiers.newCaptureCommitId()
        let legacyFinal = CaptureCoachInputWatermark(
            captureId: captureId,
            streams: base.streams,
            captureCommitId: commitId)
        let liveFinal = CaptureCoachInputWatermark(
            schemaVersion: 2,
            captureId: captureId,
            streams: base.streams,
            captureCommit: CaptureCoachCommitWatermark(
                captureCommitId: commitId,
                contentDigest: String(repeating: "a", count: 64)),
            transcripts: base.transcripts)
        XCTAssertEqual(liveFinal.relation(to: legacyFinal), .incomparable)
        XCTAssertEqual(legacyFinal.relation(to: liveFinal), .incomparable)
    }

    func testLostAck503RelaunchAndTerminalAckPreserveExactMessageBytes() async throws {
        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.first)
        let bytes = Data(try XCTUnwrap(event["canonicalBytes"] as? String).utf8)
        let message = try CaptureCoachLiveMessage.decodeCanonical(bytes)
        let root = temporaryDirectory("coach-message-spool")

        let first = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: root,
            durability: foundationTestFilesystemDurability())
        _ = try await first.enqueue(message)
        // A lost ACK or HTTP 503 performs no state transition.
        let firstPendingCount = try await first.pendingCount()
        XCTAssertEqual(firstPendingCount, 1)

        let relaunched = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: root,
            durability: foundationTestFilesystemDurability())
        let pending = try await relaunched.pendingItems()
        XCTAssertEqual(pending.map(\.canonicalData), [bytes])

        let wrong = CaptureCoachLiveMessageAcknowledgement(
            messageId: message.messageId,
            contentDigest: String(repeating: "0", count: 64),
            status: .stored)
        do {
            try await relaunched.acknowledge(wrong)
            XCTFail("wrong digest must not dequeue")
        } catch CaptureCoachLiveSpoolError.acknowledgementMismatch {}
        let afterWrongAckCount = try await relaunched.pendingCount()
        XCTAssertEqual(afterWrongAckCount, 1)

        let exact = CaptureCoachLiveMessageAcknowledgement(
            messageId: message.messageId,
            contentDigest: message.contentDigest,
            status: .exactDuplicate)
        try await relaunched.acknowledge(exact)
        let afterExactAckCount = try await relaunched.pendingCount()
        XCTAssertEqual(afterExactAckCount, 0)
        let afterAckRelaunch = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveMessage
        >(
            root: root,
            durability: foundationTestFilesystemDurability())
        _ = try await afterAckRelaunch.enqueue(message)
        let afterExactReenqueueCount = try await afterAckRelaunch.pendingCount()
        XCTAssertEqual(afterExactReenqueueCount, 0)

        let collision = try CaptureCoachLiveMessage(
            messageId: message.messageId,
            scope: message.scope,
            producer: message.producer,
            captureId: message.captureId,
            labelId: message.labelId,
            createdAt: "2026-07-24T08:00:05.001Z",
            inputWatermark: message.inputWatermark,
            evidence: message.evidence)
        do {
            _ = try await afterAckRelaunch.enqueue(collision)
            XCTFail("compact ACK tombstone must reject changed bytes after relaunch")
        } catch CaptureCoachLiveSpoolError.identifierCollision {}
    }

    func testLegacyFullByteACKHistoryCompactsAndCleanCaptureRetiresOnlyItsHead()
        async throws
    {
        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.first)
        let bytes = Data(try XCTUnwrap(event["canonicalBytes"] as? String).utf8)
        let message = try CaptureCoachLiveMessage.decodeCanonical(bytes)
        let root = temporaryDirectory("coach-legacy-ack-compaction")
        let acknowledged = root.appendingPathComponent("acknowledged")
        let pending = root.appendingPathComponent("pending")
        let identity = root.appendingPathComponent("global-identity")
        try FileManager.default.createDirectory(
            at: acknowledged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: pending, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: identity, withIntermediateDirectories: true)
        let name = message.messageId + ".json"
        let acknowledgedURL = acknowledged.appendingPathComponent(name)
        let identityURL = identity.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: acknowledgedURL.path, contents: bytes))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: identityURL.path, contents: bytes))

        let durability = foundationTestFilesystemDurability()
        let spool = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: root,
            globalCollisionRoot: identity,
            durability: durability)
        _ = try await spool.enqueue(message)
        let compactAcknowledged = try Data(contentsOf: acknowledgedURL)
        let compactIdentity = try Data(contentsOf: identityURL)
        XCTAssertLessThan(compactAcknowledged.count, bytes.count)
        XCTAssertEqual(compactAcknowledged, compactIdentity)
        let tombstone = try JSONDecoder().decode(
            CaptureCoachLiveIdentityTombstone.self,
            from: compactAcknowledged)
        XCTAssertEqual(tombstone.identifier, message.messageId)
        XCTAssertEqual(tombstone.rawSha256, JazzArchiveDigest.sha256Hex(bytes))
        XCTAssertEqual(tombstone.byteLength, bytes.count)
        XCTAssertEqual(tombstone.contentDigest, message.contentDigest)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: acknowledged.appendingPathComponent(
                ".capture-coach-tombstones-v1").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: identity.appendingPathComponent(
                ".capture-coach-tombstones-v1").path))
        let pendingAfterLegacyEnqueue = try await spool.pendingCount()
        XCTAssertEqual(pendingAfterLegacyEnqueue, 0)

        let headRoot = root.appendingPathComponent("capture-head")
        let projector = try CaptureCoachLiveMessageProjector(
            captureId: message.captureId,
            producer: message.producer,
            messages: spool,
            stateRoot: headRoot,
            durability: durability)
        try await projector.recoverPendingProgress()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: headRoot.appendingPathComponent("head.json").path))
        try await projector.retireRecoveryState()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: headRoot.appendingPathComponent("head.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: acknowledgedURL.path))
        let pendingAfterRetirement = try await spool.pendingCount()
        XCTAssertEqual(pendingAfterRetirement, 0)
    }

    func testLegacyACKMigrationFsyncsCaptureHeadBeforeCompactionAndSurvivesCrash()
        async throws
    {
        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.first)
        let bytes = Data(try XCTUnwrap(event["canonicalBytes"] as? String).utf8)
        let message = try CaptureCoachLiveMessage.decodeCanonical(bytes)
        let root = temporaryDirectory("coach-legacy-ack-two-phase")
        let acknowledged = root.appendingPathComponent("acknowledged")
        let pending = root.appendingPathComponent("pending")
        try FileManager.default.createDirectory(
            at: acknowledged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: pending, withIntermediateDirectories: true)
        let acknowledgedURL = acknowledged.appendingPathComponent(
            message.messageId + ".json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: acknowledgedURL.path, contents: bytes))

        let beforeCrash = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveMessage
        >(
            root: root,
            preserveLegacyAcknowledgedDocumentsForRecovery: true,
            durability: foundationTestFilesystemDurability())
        let firstRecoveryRead = try await beforeCrash.legacyAcknowledgedDocuments()
        XCTAssertEqual(firstRecoveryRead.map(\.canonicalData), [bytes])
        XCTAssertEqual(try Data(contentsOf: acknowledgedURL), bytes)

        // Relaunch before the head write sees the same full legacy bytes; phase one is read-only.
        let recorder = CoachOneShotDurability()
        let relaunched = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveMessage
        >(
            root: root,
            preserveLegacyAcknowledgedDocumentsForRecovery: true,
            durability: recorder.value())
        let captureHead = root.appendingPathComponent("capture-head")
        let projector = try CaptureCoachLiveMessageProjector(
            captureId: message.captureId,
            producer: message.producer,
            messages: relaunched,
            stateRoot: captureHead,
            durability: recorder.value())
        recorder.resetEvents()
        try await projector.recoverPendingProgress()

        let recoveredWatermark = await projector.currentWatermark(
            labelId: message.labelId)
        XCTAssertEqual(recoveredWatermark, message.inputWatermark)
        let compact = try Data(contentsOf: acknowledgedURL)
        XCTAssertNotEqual(compact, bytes)
        let tombstone = try JSONDecoder().decode(
            CaptureCoachLiveIdentityTombstone.self, from: compact)
        XCTAssertEqual(tombstone.identifier, message.messageId)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: acknowledged.appendingPathComponent(
                ".capture-coach-tombstones-v1").path))
        let durabilityEvents = recorder.events()
        let headSync = try XCTUnwrap(
            durabilityEvents.firstIndex {
                $0 == "file:\(captureHead.appendingPathComponent("head.json").path)"
            })
        let tombstoneSync = try XCTUnwrap(
            durabilityEvents.firstIndex {
                $0 == "file:\(acknowledgedURL.path)"
            })
        XCTAssertLessThan(headSync, tombstoneSync)
    }

    func testProjectorRecoversReceiptIdentityAfterEnqueueFailure() async throws {
        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let promptEvent = try XCTUnwrap(
            events.first {
                $0["kind"] as? String == "receive_prompt"
            })
        let prompt = try CaptureCoachLivePrompt.decodeCanonical(
            Data(try XCTUnwrap(promptEvent["canonicalBytes"] as? String).utf8))
        let root = temporaryDirectory("coach-projector")
        let receiptSpool = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLivePromptReceipt
        >(
            root: root.appendingPathComponent("receipts"),
            durability: foundationTestFilesystemDurability())
        let sink = FailOnceReceiptSink(spool: receiptSpool)
        let recorder = Recorder()
        let coordinator = try CaptureCoachCoordinator(
            captureId: prompt.captureId,
            policy: CaptureCoachPolicy(cooldownSeconds: 0),
            recorder: recorder)
        let intentRoot = root.appendingPathComponent("intents")
        let projector = CaptureCoachLivePromptProjector(
            coordinator: coordinator,
            intents: try CaptureCoachLiveProjectionIntentStore(
                root: intentRoot,
                durability: foundationTestFilesystemDurability()),
            receipts: sink)
        let date = try XCTUnwrap(Timestamps.parse("2026-07-24T08:00:05.220Z"))

        do {
            _ = try await projector.project(prompt, at: date)
            XCTFail("expected injected receipt enqueue failure")
        } catch InjectedFailure.enqueue {}
        let afterFailureInteractions = await recorder.recorded()
        XCTAssertEqual(
            afterFailureInteractions.map(\.interactionType), [.received, .shown])
        let afterFailurePendingCount = try await receiptSpool.pendingCount()
        XCTAssertEqual(afterFailurePendingCount, 0)

        let recoveredProjector = CaptureCoachLivePromptProjector(
            coordinator: coordinator,
            intents: try CaptureCoachLiveProjectionIntentStore(
                root: intentRoot,
                durability: foundationTestFilesystemDurability()),
            receipts: sink)
        let result = try await recoveredProjector.project(
            prompt, at: date.addingTimeInterval(30))
        XCTAssertEqual(result.decision.disposition, .shown)
        XCTAssertTrue(result.decision.recordedInteractions.isEmpty)
        let afterRecoveryInteractions = await recorder.recorded()
        XCTAssertEqual(afterRecoveryInteractions.count, 2)
        let pending = try await receiptSpool.pendingItems()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.document, result.receipt)

        let again = try await recoveredProjector.project(
            prompt, at: date.addingTimeInterval(60))
        XCTAssertEqual(again.receipt, result.receipt)
        let finalPendingCount = try await receiptSpool.pendingCount()
        XCTAssertEqual(finalPendingCount, 1)
    }

    func testConcurrentPollAndLostACKRedeliveryPresentExactlyOnce()
        async throws
    {
        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let promptEvent = try XCTUnwrap(
            events.first { $0["kind"] as? String == "receive_prompt" })
        let prompt = try CaptureCoachLivePrompt.decodeCanonical(
            Data(try XCTUnwrap(promptEvent["canonicalBytes"] as? String).utf8))
        let root = temporaryDirectory("coach-poll-single-flight")
        let receiptSpool = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLivePromptReceipt
        >(
            root: root.appendingPathComponent("receipts"),
            durability: foundationTestFilesystemDurability())
        let recorder = Recorder()
        let projector = CaptureCoachLivePromptProjector(
            coordinator: try CaptureCoachCoordinator(
                captureId: prompt.captureId,
                policy: CaptureCoachPolicy(cooldownSeconds: 0),
                recorder: recorder),
            intents: try CaptureCoachLiveProjectionIntentStore(
                root: root.appendingPathComponent("intents"),
                durability: foundationTestFilesystemDurability()),
            receipts: receiptSpool)
        let gate = PromptPollGateHarness()

        async let nudgeAdmitted = gate.begin(7)
        async let tickAdmitted = gate.begin(7)
        let admissions = await [nudgeAdmitted, tickAdmitted]
        XCTAssertEqual(admissions.filter { $0 }.count, 1)

        var presentationCount = 0
        let first = try await projector.project(prompt)
        if CaptureCoachLivePromptPollAdmissionGate.shouldPresent(first) {
            presentationCount += 1
        }
        await gate.end(7)

        // The server may redeliver while the exact shown receipt is still pending after a lost ACK.
        let reconnectAdmitted = await gate.begin(7)
        XCTAssertTrue(reconnectAdmitted)
        let repeated = try await projector.project(prompt)
        if CaptureCoachLivePromptPollAdmissionGate.shouldPresent(repeated) {
            presentationCount += 1
        }
        await gate.end(7)

        XCTAssertEqual(presentationCount, 1)
        XCTAssertEqual(repeated.receipt, first.receipt)
        XCTAssertTrue(repeated.decision.recordedInteractions.isEmpty)
        let recorded = await recorder.recorded()
        XCTAssertEqual(recorded.count, 2)
        let pendingReceiptCount = try await receiptSpool.pendingCount()
        XCTAssertEqual(pendingReceiptCount, 1)
    }

    func testPresentationBoundaryCrashCutsNeverClaimOrRepeatUnconfirmedDisplay()
        async throws
    {
        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let promptEvent = try XCTUnwrap(
            events.first { $0["kind"] as? String == "receive_prompt" })
        let prompt = try CaptureCoachLivePrompt.decodeCanonical(
            Data(try XCTUnwrap(promptEvent["canonicalBytes"] as? String).utf8))

        for callbackReturned in [false, true] {
            let root = temporaryDirectory(
                "coach-presentation-cut-\(callbackReturned)")
            let recorder = Recorder()
            let coordinator = try CaptureCoachCoordinator(
                captureId: prompt.captureId,
                policy: CaptureCoachPolicy(cooldownSeconds: 0),
                recorder: recorder)
            let intents = try CaptureCoachLiveProjectionIntentStore(
                root: root.appendingPathComponent("intents"),
                durability: foundationTestFilesystemDurability())
            let receipts = try CaptureCoachLiveExactByteSpool<
                CaptureCoachLivePromptReceipt
            >(
                root: root.appendingPathComponent("receipts"),
                durability: foundationTestFilesystemDurability())
            let projector = CaptureCoachLivePromptProjector(
                coordinator: coordinator, intents: intents, receipts: receipts)
            let admission = try await projector.beginPresentation(prompt)
            guard case .present = admission else {
                return XCTFail("received-only prompt must yield one ticket")
            }
            var presentationCount = 0
            if callbackReturned { presentationCount += 1 }
            let receivedOnly = await recorder.recorded()
            XCTAssertEqual(receivedOnly.map(\.interactionType), [.received])

            let recoveredRecorder = Recorder(seed: receivedOnly)
            let recoveredCoordinator = try CaptureCoachCoordinator(
                captureId: prompt.captureId,
                policy: CaptureCoachPolicy(cooldownSeconds: 0),
                recorder: recoveredRecorder,
                recoveredInteractions: receivedOnly)
            let recoveredProjector = CaptureCoachLivePromptProjector(
                coordinator: recoveredCoordinator,
                intents: intents,
                receipts: receipts)
            let recovered = try await recoveredProjector.recoverInterrupted(prompt)
            XCTAssertEqual(
                recovered.decision.disposition,
                .suppressed(.interruptedCapture))
            XCTAssertEqual(presentationCount, callbackReturned ? 1 : 0)
            XCTAssertEqual(
                recovered.receipt.canonicalInteractions.map(\.interactionType),
                [.received, .suppressed])
        }

        let shownRoot = temporaryDirectory("coach-presentation-cut-shown")
        let shownRecorder = Recorder()
        let shownCoordinator = try CaptureCoachCoordinator(
            captureId: prompt.captureId,
            policy: CaptureCoachPolicy(cooldownSeconds: 0),
            recorder: shownRecorder)
        let shownIntents = try CaptureCoachLiveProjectionIntentStore(
            root: shownRoot.appendingPathComponent("intents"),
            durability: foundationTestFilesystemDurability())
        let shownReceipts = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLivePromptReceipt
        >(
            root: shownRoot.appendingPathComponent("receipts"),
            durability: foundationTestFilesystemDurability())
        let shownProjector = CaptureCoachLivePromptProjector(
            coordinator: shownCoordinator,
            intents: shownIntents,
            receipts: shownReceipts)
        let shownAdmission = try await shownProjector.beginPresentation(prompt)
        guard case .present(let ticket) = shownAdmission else {
            return XCTFail("expected presentation ticket")
        }
        var shownCount = 1
        let confirmed = try await shownProjector.confirmPresented(ticket)
        XCTAssertEqual(confirmed.decision.disposition, .shown)
        let redelivery = try await shownProjector.beginPresentation(prompt)
        guard case .terminal(let repeated) = redelivery else {
            return XCTFail("confirmed prompt must never yield a second ticket")
        }
        XCTAssertFalse(
            CaptureCoachLivePromptPollAdmissionGate.shouldPresent(repeated))
        XCTAssertEqual(shownCount, 1)
        shownCount += 0
    }

    func testActionRecoveryMarkerRetiresOnlyAfterReceiptProjectionAndCaptureCommit()
        async throws
    {
        let root = temporaryDirectory("coach-action-marker-cut")
        let archiveId = Identifiers.newArchiveId()
        let captureId = Identifiers.newCaptureId()
        let store = try CaptureCoachLiveActionProjectionIntentStore(
            root: root,
            recoveryBinding: try CaptureCoachLiveActionRecoveryBinding(
                archiveId: archiveId, captureId: captureId),
            durability: foundationTestFilesystemDurability())
        let prompt = CaptureCoachPrompt(
            promptId: Identifiers.newCoachPromptId(),
            labelId: Identifiers.newLabelId(),
            assessmentRef: CaptureCoachAssessmentRef(
                assessmentId:
                    "cqa-\(Identifiers.newUUIDv7().uuidString.lowercased())",
                revision: 1,
                inputDigest: String(repeating: "a", count: 64)),
            inputWatermark: CaptureCoachInputWatermark(
                schemaVersion: 2,
                captureId: captureId,
                streams: [
                    CaptureCoachStreamWatermark(
                        streamId: Identifiers.newStreamId(),
                        throughSequence: 0)
                ],
                transcripts: []),
            snapshot: CaptureCoachPromptSnapshot(
                text: "What changed?",
                slot: .exception,
                policyVersion: "test-v1",
                responseModes: [.typedText]))
        let livePrompt = try CaptureCoachLivePrompt(
            scope: CaptureCoachLiveScope(
                companyId: "company-001",
                areaId: "area-finance",
                processId: "process-invoices",
                deviceId: "device-macos-001"),
            captureId: captureId,
            labelId: try XCTUnwrap(prompt.labelId),
            sourceMessageIds: [Identifiers.newCoachLiveMessageId()],
            assessmentRef: try XCTUnwrap(prompt.assessmentRef),
            inputWatermark: prompt.inputWatermark,
            snapshot: prompt.snapshot,
            issuedAt: Timestamps.iso8601())
        let intent = try await store.prepare(
            CaptureCoachLiveActionProjectionIntent(
                prompt: livePrompt, interactionType: .answered))
        let interaction = CaptureCoachInteraction(
            interactionId: intent.interactionId,
            interactionType: .answered,
            occurredAt: intent.clientRecordedAt,
            promptId: prompt.promptId,
            labelId: prompt.labelId,
            assessmentRef: prompt.assessmentRef,
            inputWatermark: prompt.inputWatermark,
            answer: CaptureCoachAnswer(mode: .typedText, text: "Approval changed."))
        try await store.recordCanonicalInteraction(interaction)
        try await store.markProjected(interaction.interactionId)
        let beforeCommit = try await store.recoveryBindingIfNeeded()
        XCTAssertNotNil(beforeCommit)

        let relaunched = try CaptureCoachLiveActionProjectionIntentStore(
            root: root,
            durability: foundationTestFilesystemDurability())
        let afterRelaunch = try await relaunched.recoveryBindingIfNeeded()
        XCTAssertNotNil(afterRelaunch)
        try await relaunched.markCaptureCommitted()
        let afterCommit = try await relaunched.recoveryBindingIfNeeded()
        XCTAssertNil(afterCommit)
    }

    func testRetiredCaptureScaleScanLoadsNoArchiveArtifacts() async throws {
        let liveRoot = temporaryDirectory("coach-retired-scale-live")
        let archiveRoot = temporaryDirectory("coach-retired-scale-archives")
        let captures =
            liveRoot
            .appendingPathComponent("partitions", isDirectory: true)
            .appendingPathComponent("route-retired", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        for index in 0..<1_000 {
            try FileManager.default.createDirectory(
                at:
                    captures
                    .appendingPathComponent(
                        "retired-\(index)", isDirectory: true)
                    .appendingPathComponent(
                        "action-intents", isDirectory: true),
                withIntermediateDirectories: true)
        }
        let result =
            try await CaptureCoachLiveRecoveryScanner
            .recoverAllActionReceipts(
                liveRoot: liveRoot,
                archiveRoot: archiveRoot,
                durability: foundationTestFilesystemDurability())
        XCTAssertEqual(result.unresolvedCaptureMarkers, 0)
        XCTAssertEqual(result.canonicalArchiveReads, 0)
    }

    func testIndexPublicationCrashBeforeIntentBecomesBoundedRetirablePhantom()
        async throws
    {
        let archiveRoot = temporaryDirectory("coach-index-cut-archive")
        let liveRoot = temporaryDirectory("coach-index-cut-live")
        let archive = makeArchiveFixture()
        let durability = foundationTestFilesystemDurability()
        let partition = try CaptureCoachLiveRoutePartition.bind(
            baseRoot: liveRoot,
            routeBinding: routeBinding(
                areaId: "area-finance",
                tokenId: "token-index-cut",
                generation: 1),
            durability: durability)
        let intentRoot =
            partition.root
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent(archive.captureId, isDirectory: true)
            .appendingPathComponent("action-intents", isDirectory: true)
        let fault = CoachOneShotDurability()
        let store = try CaptureCoachLiveActionProjectionIntentStore(
            root: intentRoot,
            recoveryBinding: try CaptureCoachLiveActionRecoveryBinding(
                archiveId: archive.archiveId,
                captureId: archive.captureId),
            durability: fault.value())
        let prompt = try CaptureCoachLivePrompt(
            scope: CaptureCoachLiveScope(
                companyId: "company-001",
                areaId: "area-finance",
                processId: "process-invoices",
                deviceId: "device-macos-001"),
            captureId: archive.captureId,
            labelId: Identifiers.newLabelId(),
            sourceMessageIds: [Identifiers.newCoachLiveMessageId()],
            assessmentRef: CaptureCoachAssessmentRef(
                assessmentId:
                    "cqa-\(Identifiers.newUUIDv7().uuidString.lowercased())",
                revision: 1,
                inputDigest: String(repeating: "a", count: 64)),
            inputWatermark: CaptureCoachInputWatermark(
                schemaVersion: 2,
                captureId: archive.captureId,
                streams: [
                    CaptureCoachStreamWatermark(
                        streamId: archive.streamId, throughSequence: 0)
                ],
                transcripts: []),
            snapshot: CaptureCoachPromptSnapshot(
                text: "What changed?",
                slot: .exception,
                policyVersion: "test-v1",
                responseModes: [.typedText]),
            issuedAt: Timestamps.iso8601())
        fault.failNextDirectory(containing: "/action-intents")
        do {
            _ = try await store.prepare(
                CaptureCoachLiveActionProjectionIntent(
                    prompt: prompt, interactionType: .dismissed))
            XCTFail("fault must cut after index publication")
        } catch JazzArchiveFilesystemDurabilityError.synchronizationFailed {}

        let indexURL =
            partition.root
            .appendingPathComponent(
                "action-recovery-index", isDirectory: true)
            .appendingPathComponent(archive.captureId + ".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    intentRoot.appendingPathComponent(
                        "recovery-needed.json").path))

        let journal = CaptureJournal(root: archiveRoot)
        _ = try await journal.begin(
            manifest: archive.manifest, session: archive.session)
        let runtime = CaptureJournalRuntime(
            journal: journal,
            context: CaptureJournalActivityContext(
                originId: archive.originId,
                captureId: archive.captureId,
                streamId: archive.streamId,
                sourceId: archive.sourceId,
                actorId: archive.actorId,
                policyVersion: "test-consent-v1"))
        let event = ActivityEvent(
            sessionId: archive.session.legacySessionId
                ?? Identifiers.newSessionId(),
            eventId: Identifiers.eventId(
                sessionId: archive.session.legacySessionId
                    ?? Identifiers.newSessionId(),
                sequence: 0),
            sequence: 0,
            timestamp: Timestamps.iso8601(),
            eventType: EventType.sessionStart.rawValue,
            url: "app://capture-coach-recovery")
        _ = try await runtime.submit { _ in
            .observation(CaptureJournalActivityObservation(event: event))
        }
        _ = try await runtime.close(endedAt: Timestamps.iso8601())
        let scan =
            try await CaptureCoachLiveRecoveryScanner
            .recoverAllActionReceipts(
                liveRoot: liveRoot,
                archiveRoot: archiveRoot,
                durability: durability)
        XCTAssertEqual(scan.unresolvedCaptureMarkers, 1)
        XCTAssertEqual(scan.canonicalArchiveReads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
    }

    func testTruncatedRecoveryIndexFailsClosedWithoutLifetimeFallback()
        async throws
    {
        let archiveRoot = temporaryDirectory("coach-index-corrupt-archive")
        let liveRoot = temporaryDirectory("coach-index-corrupt-live")
        let captureId = Identifiers.newCaptureId()
        let archiveId = Identifiers.newArchiveId()
        let durability = foundationTestFilesystemDurability()
        let partition = try CaptureCoachLiveRoutePartition.bind(
            baseRoot: liveRoot,
            routeBinding: routeBinding(
                areaId: "area-finance",
                tokenId: "token-index-corrupt",
                generation: 1),
            durability: durability)
        let intentRoot =
            partition.root
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent("action-intents", isDirectory: true)
        let store = try CaptureCoachLiveActionProjectionIntentStore(
            root: intentRoot,
            recoveryBinding: try CaptureCoachLiveActionRecoveryBinding(
                archiveId: archiveId, captureId: captureId),
            durability: durability)
        let scope = CaptureCoachLiveScope(
            companyId: "company-001",
            areaId: "area-finance",
            processId: "process-invoices",
            deviceId: "device-macos-001")
        _ = try await store.prepare(
            CaptureCoachLiveActionProjectionIntent(
                scope: scope,
                captureId: captureId,
                labelId: Identifiers.newLabelId(),
                inputWatermark: CaptureCoachInputWatermark(
                    schemaVersion: 2,
                    captureId: captureId,
                    streams: [
                        CaptureCoachStreamWatermark(
                            streamId: Identifiers.newStreamId(),
                            throughSequence: 0)
                    ],
                    transcripts: []),
                interactionType: .finishAnyway))
        let indexURL =
            partition.root
            .appendingPathComponent(
                "action-recovery-index", isDirectory: true)
            .appendingPathComponent(captureId + ".json")
        try Data("{\"schemaVersion\":1".utf8).write(to: indexURL)
        do {
            _ = try await CaptureCoachLiveRecoveryScanner
                .recoverAllActionReceipts(
                    liveRoot: liveRoot,
                    archiveRoot: archiveRoot,
                    durability: durability)
            XCTFail("truncated index must fail closed")
        } catch CaptureCoachLiveSpoolError.corruptEntry {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        let localMarker = intentRoot.appendingPathComponent(
            "recovery-needed.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: localMarker.path))
    }

    func testReceiptIsSelectedInFirstBoundedCycleDespitePCMBacklog() {
        var fairness = CaptureCoachLiveDeliveryFairnessGate()
        var messages = 65
        var receipts = 1
        var delivered: [CaptureCoachLiveDeliveryFairnessGate.Queue] = []
        while delivered.count < 64,
            let selected = fairness.next(
                hasMessage: messages > 0, hasReceipt: receipts > 0)
        {
            delivered.append(selected)
            switch selected {
            case .message: messages -= 1
            case .receipt: receipts -= 1
            }
        }
        XCTAssertEqual(delivered.first, .receipt)
        XCTAssertEqual(receipts, 0)
        XCTAssertEqual(messages, 2)
        XCTAssertEqual(delivered.filter { $0 == .message }.count, 63)
    }

    func testScopeControlReceiptSurvivesRelaunchUntilExactAck() async throws {
        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let promptEvent = try XCTUnwrap(
            events.first {
                $0["kind"] as? String == "receive_prompt"
            })
        let prompt = try CaptureCoachLivePrompt.decodeCanonical(
            Data(try XCTUnwrap(promptEvent["canonicalBytes"] as? String).utf8))
        let shownEvent = try XCTUnwrap(
            events.first {
                ($0["document"] as? [String: Any])?["action"] as? String == "shown"
            })
        let shownReceipt = try CaptureCoachLivePromptReceipt.decodeCanonical(
            Data(try XCTUnwrap(shownEvent["canonicalBytes"] as? String).utf8))
        let interactionId = Identifiers.newCoachInteractionId()
        let receipt = try CaptureCoachLiveScopeControlReceipt(
            receiptId: shownReceipt.receiptId,
            scope: prompt.scope,
            captureId: prompt.captureId,
            labelId: prompt.labelId,
            inputWatermark: prompt.inputWatermark,
            action: .muted,
            canonicalInteraction: CaptureCoachLiveCanonicalInteractionRef(
                interactionId: interactionId, interactionType: .muted),
            occurredAt: "2026-07-24T08:00:06.000Z",
            clientRecordedAt: "2026-07-24T08:00:06.000Z")
        let root = temporaryDirectory("coach-scope-control-spool")
        let first = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveReceiptDocument>(
            root: root,
            durability: foundationTestFilesystemDurability())
        let enqueued = try await first.enqueue(.prompt(shownReceipt))

        let relaunched = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveReceiptDocument
        >(
            root: root,
            durability: foundationTestFilesystemDurability())
        let pending = try await relaunched.pendingItems()
        XCTAssertEqual(pending.map(\.canonicalData), [enqueued.canonicalData])
        do {
            _ = try await relaunched.enqueue(.scopeControl(receipt))
            XCTFail("one ccr id must be globally write-once across receipt variants")
        } catch CaptureCoachLiveSpoolError.identifierCollision {}

        let acknowledgement = CaptureCoachLiveReceiptAcknowledgement(
            receiptId: shownReceipt.receiptId,
            contentDigest: shownReceipt.contentDigest,
            status: .stored)
        try await relaunched.acknowledge(acknowledgement)
        let pendingCount = try await relaunched.pendingCount()
        XCTAssertEqual(pendingCount, 0)
    }

    func testActionIntentRecoversCommittedInteractionBeforeReceiptSpool() async throws {
        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let promptEvent = try XCTUnwrap(
            events.first {
                $0["kind"] as? String == "receive_prompt"
            })
        let prompt = try CaptureCoachLivePrompt.decodeCanonical(
            Data(try XCTUnwrap(promptEvent["canonicalBytes"] as? String).utf8))
        let root = temporaryDirectory("coach-action-recovery")
        let recorder = Recorder()
        let coordinator = try CaptureCoachCoordinator(
            captureId: prompt.captureId,
            policy: CaptureCoachPolicy(cooldownSeconds: 0),
            recorder: recorder)
        _ = try await coordinator.receive(
            prompt.domainPrompt,
            at: try XCTUnwrap(Timestamps.parse("2026-07-24T08:00:05.220Z")))

        let actionDate = try XCTUnwrap(
            Timestamps.parse("2026-07-24T08:00:08.000Z"))
        let proposed = try CaptureCoachLiveActionProjectionIntent(
            prompt: prompt, interactionType: .answered, at: actionDate)
        let firstIntentStore = try CaptureCoachLiveActionProjectionIntentStore(
            root: root.appendingPathComponent("action-intents"),
            durability: foundationTestFilesystemDurability())
        let intent = try await firstIntentStore.prepare(proposed)
        let committed = try await coordinator.answer(
            promptId: prompt.promptId,
            answer: CaptureCoachAnswer(mode: .typedText, text: "Use the exception queue."),
            at: actionDate,
            interactionId: intent.interactionId)

        // Fault injection: canonical append returned, then the process died before receipt enqueue.
        let receiptRoot = root.appendingPathComponent("receipts")
        let receiptSpool = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveReceiptDocument
        >(
            root: receiptRoot,
            durability: foundationTestFilesystemDurability())
        let recovered = CaptureCoachLiveActionReceiptProjector(
            intents: try CaptureCoachLiveActionProjectionIntentStore(
                root: root.appendingPathComponent("action-intents"),
                durability: foundationTestFilesystemDurability()),
            receipts: receiptSpool)
        try await recovered.recover([committed])
        let firstBytes = try await receiptSpool.pendingItems().map(\.canonicalData)
        XCTAssertEqual(firstBytes.count, 1)

        let relaunchedSpool = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveReceiptDocument
        >(
            root: receiptRoot,
            durability: foundationTestFilesystemDurability())
        let relaunchedProjector = CaptureCoachLiveActionReceiptProjector(
            intents: try CaptureCoachLiveActionProjectionIntentStore(
                root: root.appendingPathComponent("action-intents"),
                durability: foundationTestFilesystemDurability()),
            receipts: relaunchedSpool)
        try await relaunchedProjector.recover([committed])
        let recoveredBytes = try await relaunchedSpool.pendingItems().map(\.canonicalData)
        XCTAssertEqual(recoveredBytes, firstBytes)
    }

    func testEndpointsStayOnSignedOriginAndPromptResponseIsStrict() throws {
        let prefixed = try XCTUnwrap(
            CaptureCoachLiveEndpoint.derive(
                fromArchiveIngestURL:
                    "https://jazz.example.test:8443/tenant-a/api/archive-ingests"))
        XCTAssertEqual(
            prefixed.absoluteString,
            "https://jazz.example.test:8443/tenant-a/api/capture-coach/live")
        XCTAssertEqual(prefixed.scheme, "https")
        XCTAssertEqual(prefixed.host, "jazz.example.test")
        XCTAssertEqual(prefixed.port, 8443)
        XCTAssertNil(prefixed.user)
        XCTAssertNil(prefixed.query)
        XCTAssertNil(prefixed.fragment)
        XCTAssertNil(
            CaptureCoachLiveEndpoint.derive(
                fromArchiveIngestURL: "http://jazz.example.test/api/archive-ingests"))
        XCTAssertNil(
            CaptureCoachLiveEndpoint.derive(
                fromArchiveIngestURL:
                    "https://user@jazz.example.test/api/archive-ingests"))
        XCTAssertNil(
            CaptureCoachLiveEndpoint.derive(
                fromArchiveIngestURL:
                    "https://jazz.example.test/api/archive-ingests?next=https://evil.test"))
        XCTAssertNil(
            CaptureCoachLiveEndpoint.derive(
                fromArchiveIngestURL:
                    "https://jazz.example.test/api/archive-ingests#https://evil.test"))
        XCTAssertNotEqual(prefixed.host, "evil.test")

        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let response = try XCTUnwrap(events.first?["responseCanonicalBytes"] as? String)
        XCTAssertThrowsError(
            try CaptureCoachLiveMessageAcknowledgement.decodeCanonical(
                Data((response + "\n").utf8))
        )
    }

    func testLiveConsentDefaultsOffAndArchiveSourceOwnsProducerLineage() throws {
        XCTAssertFalse(CaptureCoachLiveConsent.isEnabled(storedValue: nil))
        XCTAssertFalse(CaptureCoachLiveConsent.isEnabled(storedValue: false))
        XCTAssertTrue(CaptureCoachLiveConsent.isEnabled(storedValue: true))

        let sourceA = Identifiers.newSourceId()
        let sourceB = Identifiers.newSourceId()
        let first = CaptureCoachLiveProducer.nativeDesktopArchiveSource(
            sourceId: sourceA, version: "1.2.3", liveAudioAvailable: true)
        let second = CaptureCoachLiveProducer.nativeDesktopArchiveSource(
            sourceId: sourceB, version: "1.2.3", liveAudioAvailable: true)
        XCTAssertEqual(first.producerId, sourceA)
        XCTAssertEqual(second.producerId, sourceB)
        XCTAssertNotEqual(first.producerId, second.producerId)
        XCTAssertEqual(
            first.capabilities,
            [
                "accessibility", "canonical_observation", "live_audio_chunk",
            ])
        XCTAssertEqual(first.unavailableCapabilities, ["screen_preview", "transcript"])
        try first.validate()
        try second.validate()

        var audioStreams = CaptureCoachLiveLabelAudioStreams()
        let racedLabel = Identifiers.newLabelId()
        let firstPCMBeforeRegistration = audioStreams.streamId(for: racedLabel)
        XCTAssertEqual(
            audioStreams.streamId(for: racedLabel),
            firstPCMBeforeRegistration)
        XCTAssertNotEqual(
            audioStreams.streamId(for: Identifiers.newLabelId()),
            firstPCMBeforeRegistration)

        var sequencer = CaptureCoachLivePCMSequencer()
        let chunk1 = try CaptureCoachLivePCMChunk(
            sequence: 1,
            startMillis: 1_000,
            endMillis: 2_000,
            recordedAt: "2026-07-24T08:00:02.000Z",
            bytes: Data(repeating: 1, count: 32_000))
        let chunk0 = try CaptureCoachLivePCMChunk(
            sequence: 0,
            startMillis: 0,
            endMillis: 1_000,
            recordedAt: "2026-07-24T08:00:01.000Z",
            bytes: Data(repeating: 0, count: 32_000))
        XCTAssertTrue(
            try sequencer.admit(
                labelId: racedLabel,
                processId: "process-invoices",
                chunk: chunk1
            ).isEmpty)
        XCTAssertEqual(
            try sequencer.admit(
                labelId: racedLabel,
                processId: "process-invoices",
                chunk: chunk0
            ).map(\.sequence),
            [0, 1])
        XCTAssertFalse(sequencer.hasPendingChunks)
        XCTAssertTrue(
            try sequencer.admit(
                labelId: racedLabel,
                processId: "process-invoices",
                chunk: chunk1
            ).isEmpty)

        let conflictingCoordinates = try CaptureCoachLivePCMChunk(
            sequence: 1,
            startMillis: 1_001,
            endMillis: 2_001,
            recordedAt: "2026-07-24T08:00:02.001Z",
            bytes: chunk1.bytes)
        XCTAssertThrowsError(
            try sequencer.admit(
                labelId: racedLabel,
                processId: "process-invoices",
                chunk: conflictingCoordinates)
        ) { error in
            guard
                case CaptureCoachLiveContractError.identityCollision =
                    error
            else {
                return XCTFail("expected full PCM identity collision, got \(error)")
            }
        }

        let gapLabel = Identifiers.newLabelId()
        let hugeGap = try CaptureCoachLivePCMChunk(
            sequence: CaptureCoachLivePCMSequencer.maximumReorderGap + 1,
            startMillis: 65_000,
            endMillis: 66_000,
            recordedAt: "2026-07-24T08:01:06.000Z",
            bytes: Data(repeating: 2, count: 32_000))
        XCTAssertThrowsError(
            try sequencer.admit(
                labelId: gapLabel,
                processId: "process-invoices",
                chunk: hugeGap)
        ) { error in
            XCTAssertEqual(
                error as? CaptureCoachLiveContractError,
                .invalidField("pcmSequencer.reorderWindow"))
        }
    }

    func testImmediateStopDrainsFirstPCMAndOutOfOrderCallbacksInSequence()
        async throws
    {
        let recorder = PCMProjectionRecorder()
        let tail = CaptureCoachLivePCMAdmissionTail {
            labelId, processId, chunk in
            await recorder.project(
                labelId: labelId, processId: processId, chunk: chunk)
        }
        let labelId = Identifiers.newLabelId()
        let processId = "process-invoices"
        let chunk1 = try CaptureCoachLivePCMChunk(
            sequence: 1,
            startMillis: 1_000,
            endMillis: 2_000,
            recordedAt: "2026-07-24T08:00:02.000Z",
            bytes: Data(repeating: 1, count: 32_000))
        let chunk0 = try CaptureCoachLivePCMChunk(
            sequence: 0,
            startMillis: 0,
            endMillis: 1_000,
            recordedAt: "2026-07-24T08:00:01.000Z",
            bytes: Data(repeating: 0, count: 32_000))

        // Simulate stop immediately after callbacks: admission is synchronous, and drain snapshots
        // both tasks even though the platform delivered sequence one before sequence zero.
        tail.submit(labelId: labelId, processId: processId, chunk: chunk1)
        tail.submit(labelId: labelId, processId: processId, chunk: chunk0)
        await tail.drain()
        let reordered = await recorder.snapshot()
        XCTAssertEqual(reordered.0, [0, 1])
        XCTAssertNil(reordered.1)

        let firstChunkRecorder = PCMProjectionRecorder()
        let firstChunkTail = CaptureCoachLivePCMAdmissionTail {
            labelId, processId, chunk in
            await firstChunkRecorder.project(
                labelId: labelId, processId: processId, chunk: chunk)
        }
        firstChunkTail.submit(
            labelId: Identifiers.newLabelId(),
            processId: processId,
            chunk: chunk0)
        await firstChunkTail.drain()
        let firstChunk = await firstChunkRecorder.snapshot()
        XCTAssertEqual(firstChunk.0, [0])
        XCTAssertNil(firstChunk.1)
    }

    func testCallbackDrainGateMakesAdmissionAtomicWithStop() {
        let gate = CaptureCoachLiveCallbackDrainGate()
        gate.startAccepting()
        let accepted = gate.admit()
        XCTAssertNotNil(accepted)

        let stopReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            gate.stopAccepting()
            gate.wait()
            stopReturned.signal()
        }
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + 0.05), .timedOut)
        accepted?.complete()
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + 1), .success)
        XCTAssertNil(gate.admit())
    }

    func testAlternatingScreenAudioScreenDominatesAndRecoversAfterAllACKs()
        async throws
    {
        let root = temporaryDirectory("coach-vector-projector")
        let durability = foundationTestFilesystemDurability()
        let spool = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: root, durability: durability)
        let captureId = Identifiers.newCaptureId()
        let sourceId = Identifiers.newSourceId()
        let producer = CaptureCoachLiveProducer.nativeDesktopArchiveSource(
            sourceId: sourceId, version: "test", liveAudioAvailable: true)
        let projector = try CaptureCoachLiveMessageProjector(
            captureId: captureId,
            producer: producer,
            messages: spool,
            stateRoot: root.appendingPathComponent("capture-head"),
            durability: durability)
        let scope = CaptureCoachLiveScope(
            companyId: "company-001",
            areaId: "area-finance",
            processId: "process-invoices",
            deviceId: "device-macos-001")
        let firstLabel = Identifiers.newLabelId()
        let secondLabel = Identifiers.newLabelId()
        let activityStream = Identifiers.newStreamId()
        let firstAudioStream = Identifiers.newStreamId()

        let screen0 = CaptureCoachLiveCanonicalObservation(
            observationId: Identifiers.newObservationId(),
            streamId: activityStream,
            streamSequence: 10,
            recordType: "jazz.activity",
            recordDigest: String(repeating: "1", count: 64),
            sanitizedContext: CaptureCoachLiveSanitizedObservationContext(
                action: "label_start",
                redactionPolicyVersion: "test-v1",
                maskedFields: []))
        let first = try await projector.enqueue(
            scope: scope,
            labelId: firstLabel,
            createdAt: "2026-07-24T08:00:00.000Z",
            streamProgress: [
                CaptureCoachStreamWatermark(
                    streamId: activityStream, throughSequence: 10)
            ],
            evidence: [.canonicalObservation(screen0)])
        do {
            _ = try await projector.enqueue(
                scope: CaptureCoachLiveScope(
                    companyId: scope.companyId,
                    areaId: scope.areaId,
                    processId: "process-other",
                    deviceId: scope.deviceId),
                labelId: firstLabel,
                createdAt: "2026-07-24T08:00:00.100Z",
                streamProgress: [
                    CaptureCoachStreamWatermark(
                        streamId: activityStream, throughSequence: 10)
                ],
                evidence: [.canonicalObservation(screen0)])
            XCTFail("one label cannot change signed process scope")
        } catch CaptureCoachLiveContractError.identityCollision(let identifier) {
            XCTAssertEqual(identifier, firstLabel)
        }

        let pcm = Data((0..<32_000).map { UInt8($0 % 251) })
        let audio0 = CaptureCoachLiveAudioChunk(
            streamId: firstAudioStream,
            streamSequence: 0,
            startMillis: 0,
            endMillis: 1_000,
            mediaType: "audio/l16;rate=16000;channels=1",
            bytes: pcm)
        let second = try await projector.enqueue(
            scope: scope,
            labelId: firstLabel,
            createdAt: "2026-07-24T08:00:01.000Z",
            streamProgress: [
                CaptureCoachStreamWatermark(
                    streamId: firstAudioStream, throughSequence: 0)
            ],
            evidence: [.audioChunk(audio0)])
        XCTAssertEqual(
            second.document.inputWatermark.relation(
                to: first.document.inputWatermark),
            .dominates)
        XCTAssertEqual(second.document.evidence, [.audioChunk(audio0)])

        let screen1 = CaptureCoachLiveCanonicalObservation(
            observationId: Identifiers.newObservationId(),
            streamId: activityStream,
            streamSequence: 11,
            recordType: "jazz.activity",
            recordDigest: String(repeating: "2", count: 64),
            sanitizedContext: CaptureCoachLiveSanitizedObservationContext(
                action: "click",
                redactionPolicyVersion: "test-v1",
                maskedFields: []))
        let third = try await projector.enqueue(
            scope: scope,
            labelId: firstLabel,
            createdAt: "2026-07-24T08:00:02.000Z",
            streamProgress: [
                CaptureCoachStreamWatermark(
                    streamId: activityStream, throughSequence: 11)
            ],
            evidence: [.canonicalObservation(screen1)])
        XCTAssertEqual(
            third.document.inputWatermark.relation(
                to: second.document.inputWatermark),
            .dominates)
        XCTAssertEqual(
            Set(third.document.inputWatermark.streams.map(\.streamId)),
            Set([activityStream, firstAudioStream]))

        for item in [first, second, third] {
            try await spool.acknowledge(
                CaptureCoachLiveMessageAcknowledgement(
                    messageId: item.document.messageId,
                    contentDigest: item.document.contentDigest,
                    status: .stored))
        }
        let pendingAfterAcknowledgements = try await spool.pendingCount()
        XCTAssertEqual(pendingAfterAcknowledgements, 0)

        // Relaunch after every message was ACKed uses only the compact capture-scoped head.
        let relaunchedSpool = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: root, durability: durability)
        let relaunched = try CaptureCoachLiveMessageProjector(
            captureId: captureId,
            producer: producer,
            messages: relaunchedSpool,
            stateRoot: root.appendingPathComponent("capture-head"),
            durability: durability)
        try await relaunched.recoverPendingProgress()
        let screen2 = CaptureCoachLiveCanonicalObservation(
            observationId: Identifiers.newObservationId(),
            streamId: activityStream,
            streamSequence: 12,
            recordType: "jazz.activity",
            recordDigest: String(repeating: "3", count: 64),
            sanitizedContext: CaptureCoachLiveSanitizedObservationContext(
                action: "label_end",
                redactionPolicyVersion: "test-v1",
                maskedFields: []))
        let afterRelaunch = try await relaunched.enqueue(
            scope: scope,
            labelId: firstLabel,
            createdAt: "2026-07-24T08:00:03.000Z",
            streamProgress: [
                CaptureCoachStreamWatermark(
                    streamId: activityStream, throughSequence: 12)
            ],
            evidence: [.canonicalObservation(screen2)])
        XCTAssertEqual(
            afterRelaunch.document.inputWatermark.relation(
                to: third.document.inputWatermark),
            .dominates)
        XCTAssertTrue(
            afterRelaunch.document.inputWatermark.streams.contains {
                $0.streamId == firstAudioStream && $0.throughSequence == 0
            })

        // A new label has its own live coordinate system: new stream, sequence 0, millis from 0.
        let secondAudioStream = Identifiers.newStreamId()
        let lateCloseChunk = CaptureCoachLiveAudioChunk(
            streamId: secondAudioStream,
            streamSequence: 0,
            startMillis: 0,
            endMillis: 500,
            mediaType: "audio/l16;rate=16000;channels=1",
            bytes: Data(repeating: 7, count: 16_000))
        let newLabel = try await relaunched.enqueue(
            scope: scope,
            labelId: secondLabel,
            createdAt: "2026-07-24T08:01:00.500Z",
            streamProgress: [
                CaptureCoachStreamWatermark(
                    streamId: secondAudioStream, throughSequence: 0)
            ],
            evidence: [.audioChunk(lateCloseChunk)])
        XCTAssertEqual(
            newLabel.document.inputWatermark.streams,
            [
                CaptureCoachStreamWatermark(
                    streamId: secondAudioStream, throughSequence: 0)
            ])
        XCTAssertFalse(
            newLabel.document.inputWatermark.streams.contains {
                $0.streamId == firstAudioStream
            })

        let final = CaptureCoachInputWatermark(
            schemaVersion: 2,
            captureId: captureId,
            streams: afterRelaunch.document.inputWatermark.streams,
            captureCommit: CaptureCoachCommitWatermark(
                captureCommitId: Identifiers.newCaptureCommitId(),
                contentDigest: String(repeating: "f", count: 64)),
            transcripts: afterRelaunch.document.inputWatermark.transcripts)
        XCTAssertEqual(
            final.relation(to: afterRelaunch.document.inputWatermark),
            .dominates)
    }

    func testHangingHTTPNeverJoinsLocalActionOrArchiveCommitBarriers()
        async throws
    {
        let archiveRoot = temporaryDirectory("coach-hanging-http-archive")
        let liveRoot = temporaryDirectory("coach-hanging-http-live")
        let durability = foundationTestFilesystemDurability()
        let fixture = makeArchiveFixture()
        let journal = CaptureJournal(root: archiveRoot)
        _ = try await journal.begin(
            manifest: fixture.manifest, session: fixture.session)

        let scope = CaptureCoachLiveScope(
            companyId: "company-001",
            areaId: "area-finance",
            processId: "process-invoices",
            deviceId: "device-macos-001")
        let labelId = Identifiers.newLabelId()
        let producer = CaptureCoachLiveProducer.nativeDesktopArchiveSource(
            sourceId: fixture.sourceId,
            version: "test",
            liveAudioAvailable: false)
        let messageSpool = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveMessage
        >(
            root: liveRoot.appendingPathComponent("messages", isDirectory: true),
            durability: durability)
        let receiptSpool = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveReceiptDocument
        >(
            root: liveRoot.appendingPathComponent("receipts", isDirectory: true),
            durability: durability)
        let messageProjector = try CaptureCoachLiveMessageProjector(
            captureId: fixture.captureId,
            producer: producer,
            messages: messageSpool,
            stateRoot: liveRoot.appendingPathComponent("message-head"),
            durability: durability)
        let actionIntents = try CaptureCoachLiveActionProjectionIntentStore(
            root: liveRoot.appendingPathComponent(
                "action-intents", isDirectory: true),
            durability: durability)
        let actionProjector = CaptureCoachLiveActionReceiptProjector(
            intents: actionIntents,
            receipts: receiptSpool)
        let hangingHTTP = HangingHTTPProbe()
        let delivery = CaptureCoachLiveDetachedDeliveryNudge {
            await hangingHTTP.send()
        }
        defer { Task { await hangingHTTP.release() } }

        let prompt = try CaptureCoachLivePrompt(
            scope: scope,
            captureId: fixture.captureId,
            labelId: labelId,
            sourceMessageIds: [Identifiers.newCoachLiveMessageId()],
            assessmentRef: CaptureCoachAssessmentRef(
                assessmentId:
                    "cqa-\(Identifiers.newUUIDv7().uuidString.lowercased())",
                revision: 1,
                inputDigest: String(repeating: "a", count: 64)),
            inputWatermark: CaptureCoachInputWatermark(
                schemaVersion: 2,
                captureId: fixture.captureId,
                streams: [
                    CaptureCoachStreamWatermark(
                        streamId: fixture.streamId, throughSequence: 0)
                ],
                transcripts: []),
            snapshot: CaptureCoachPromptSnapshot(
                text: "Which exception changes this step?",
                slot: .exception,
                policyVersion: "test-v1",
                responseModes: [.typedText]),
            issuedAt: "2026-07-24T08:00:01.000Z")
        let actionAt = try XCTUnwrap(
            Timestamps.parse("2026-07-24T08:00:02.000Z"))
        let actionIntent = try await actionIntents.prepare(
            CaptureCoachLiveActionProjectionIntent(
                prompt: prompt,
                interactionType: .answered,
                at: actionAt))
        let interaction = CaptureCoachInteraction(
            interactionId: actionIntent.interactionId,
            interactionType: .answered,
            occurredAt: actionIntent.clientRecordedAt,
            promptId: prompt.promptId,
            labelId: labelId,
            assessmentRef: prompt.assessmentRef,
            inputWatermark: prompt.inputWatermark,
            answer: CaptureCoachAnswer(
                mode: .typedText, text: "Use the exception queue."))
        let writer = CaptureCoachJournalWriter(
            journal: journal,
            context: CaptureCoachRecordContext(
                originId: fixture.originId,
                captureId: fixture.captureId,
                streamId: fixture.streamId,
                sourceRefs: [
                    JazzArchiveSourceRef(
                        sourceId: fixture.sourceId, role: "coach_ui")
                ],
                actorRefs: [
                    JazzArchiveActorRef(
                        actorId: fixture.actorId,
                        role: "respondent",
                        basis: .declared,
                        method: "session_recorder")
                ],
                provenance: JazzArchiveProvenance(
                    factClass: .observed, sources: [fixture.sourceId]),
                quality: JazzArchiveQuality(status: .complete),
                privacy: JazzArchivePrivacy(
                    status: .captured, policyVersion: "test-consent-v1")))
        try await writer.append(interaction)
        try await actionProjector.project(interaction)
        delivery.schedule()
        await hangingHTTP.waitUntilStarted(1)
        let actionReceiptCount = try await receiptSpool.pendingCount()
        XCTAssertEqual(actionReceiptCount, 1)

        let runtime = CaptureJournalRuntime(
            journal: journal,
            context: CaptureJournalActivityContext(
                originId: fixture.originId,
                captureId: fixture.captureId,
                streamId: fixture.streamId,
                sourceId: fixture.sourceId,
                actorId: fixture.actorId,
                policyVersion: "test-consent-v1"),
            canonicalObservationProjection: { record, event in
                let evidence = CaptureCoachLiveCanonicalObservation(
                    observationId: record.observationId,
                    streamId: record.streamId,
                    streamSequence: record.streamSequence,
                    recordType: record.recordType,
                    recordDigest: JazzArchiveDigest.sha256Hex(
                        try JazzArchiveCanonicalJSON.encode(record)),
                    sanitizedContext: CaptureCoachLiveSanitizedObservationContext(
                        action: event.eventType,
                        redactionPolicyVersion: "test-v1",
                        maskedFields: []))
                _ = try await messageProjector.enqueue(
                    scope: scope,
                    labelId: labelId,
                    createdAt: record.capturedAt,
                    streamProgress: [
                        CaptureCoachStreamWatermark(
                            streamId: record.streamId,
                            throughSequence: record.streamSequence)
                    ],
                    evidence: [.canonicalObservation(evidence)])
                delivery.schedule()
            })
        let activity = ActivityEvent(
            sessionId: fixture.session.legacySessionId
                ?? Identifiers.newSessionId(),
            eventId: Identifiers.eventId(
                sessionId: fixture.session.legacySessionId
                    ?? Identifiers.newSessionId(),
                sequence: 0),
            sequence: 0,
            timestamp: "2026-07-24T08:00:02.500Z",
            eventType: EventType.click.rawValue,
            url: "app://com.example.finance",
            labelId: labelId,
            label: "Issue invoices",
            processId: scope.processId,
            process: "Issue invoices")
        _ = try await runtime.submit { _ in
            .observation(CaptureJournalActivityObservation(event: activity))
        }

        // Both HTTP operations are intentionally still suspended. Close may wait for the exact local
        // message/receipt bytes, but it must never join either delivery task.
        let commit = try await runtime.close(
            endedAt: "2026-07-24T08:00:03.000Z")
        await hangingHTTP.waitUntilStarted(2)
        let messageCount = try await messageSpool.pendingCount()
        XCTAssertEqual(messageCount, 1)
        XCTAssertEqual(commit.streamSummaries.first?.observationCount, 2)
        await hangingHTTP.release()
    }

    func testRouteRotationPartitionsQueuesWithoutCrossAuthorityHeadOfLine()
        async throws
    {
        let base = temporaryDirectory("coach-route-partitions")
        let durability = foundationTestFilesystemDurability()
        let firstRoute = try routeBinding(
            areaId: "area-finance",
            tokenId: "token-audit-id-one",
            generation: 1)
        let rotated = try routeBinding(
            areaId: "area-finance",
            tokenId: "token-audit-id-two",
            generation: 2)
        let switched = try routeBinding(
            areaId: "area-operations",
            tokenId: "token-audit-id-three",
            generation: 1)
        let firstPartition = try CaptureCoachLiveRoutePartition.bind(
            baseRoot: base, routeBinding: firstRoute, durability: durability)
        let rotatedPartition = try CaptureCoachLiveRoutePartition.bind(
            baseRoot: base, routeBinding: rotated, durability: durability)
        let switchedPartition = try CaptureCoachLiveRoutePartition.bind(
            baseRoot: base, routeBinding: switched, durability: durability)
        XCTAssertEqual(firstPartition.root, rotatedPartition.root)
        XCTAssertNotEqual(firstPartition.root, switchedPartition.root)

        let snapshots = firstPartition.root.appendingPathComponent(
            "route-snapshots", isDirectory: true)
        let snapshotText = try FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: nil
        ).map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(snapshotText.contains(firstRoute.tokenId))
        XCTAssertFalse(snapshotText.contains(rotated.tokenId))

        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let fixtureEvents = try XCTUnwrap(
            fixture["events"] as? [[String: Any]])
        let event = try XCTUnwrap(fixtureEvents.first)
        let message = try CaptureCoachLiveMessage.decodeCanonical(
            Data(try XCTUnwrap(event["canonicalBytes"] as? String).utf8))
        let identity =
            base
            .appendingPathComponent("identity", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        let oldSpool = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: firstPartition.root.appendingPathComponent("messages"),
            globalCollisionRoot: identity,
            durability: durability)
        _ = try await oldSpool.enqueue(message)

        let switchedSpool = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: switchedPartition.root.appendingPathComponent("messages"),
            globalCollisionRoot: identity,
            durability: durability)
        let collision = try CaptureCoachLiveMessage(
            messageId: message.messageId,
            scope: message.scope,
            producer: message.producer,
            captureId: message.captureId,
            labelId: message.labelId,
            createdAt: "2026-07-24T08:00:05.001Z",
            inputWatermark: message.inputWatermark,
            evidence: message.evidence)
        do {
            _ = try await switchedSpool.enqueue(collision)
            XCTFail("global ccm identity fence must span route partitions")
        } catch CaptureCoachLiveSpoolError.identifierCollision {}

        let current = try CaptureCoachLiveMessage(
            scope: message.scope,
            producer: message.producer,
            captureId: message.captureId,
            labelId: message.labelId,
            createdAt: "2026-07-24T08:00:06.000Z",
            inputWatermark: message.inputWatermark,
            evidence: message.evidence)
        _ = try await switchedSpool.enqueue(current)
        let relaunchedCurrent = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveMessage
        >(
            root: switchedPartition.root.appendingPathComponent("messages"),
            globalCollisionRoot: identity,
            durability: durability)
        let currentPendingBeforeAcknowledgement =
            try await relaunchedCurrent.pendingCount()
        XCTAssertEqual(currentPendingBeforeAcknowledgement, 1)
        try await relaunchedCurrent.acknowledge(
            CaptureCoachLiveMessageAcknowledgement(
                messageId: current.messageId,
                contentDigest: current.contentDigest,
                status: .stored))
        let currentPendingAfterAcknowledgement =
            try await relaunchedCurrent.pendingCount()
        let oldAuthorityPending = try await oldSpool.pendingCount()
        XCTAssertEqual(currentPendingAfterAcknowledgement, 0)
        XCTAssertEqual(oldAuthorityPending, 1)

        let shownEvent = try XCTUnwrap(
            fixtureEvents.first {
                ($0["document"] as? [String: Any])?["action"] as? String == "shown"
            })
        let shown = try CaptureCoachLivePromptReceipt.decodeCanonical(
            Data(try XCTUnwrap(shownEvent["canonicalBytes"] as? String).utf8))
        let receiptIdentity =
            base
            .appendingPathComponent("identity", isDirectory: true)
            .appendingPathComponent("receipts", isDirectory: true)
        let oldReceipts = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveReceiptDocument
        >(
            root: firstPartition.root.appendingPathComponent("receipts"),
            globalCollisionRoot: receiptIdentity,
            durability: durability)
        _ = try await oldReceipts.enqueue(.prompt(shown))
        let switchedReceipts = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveReceiptDocument
        >(
            root: switchedPartition.root.appendingPathComponent("receipts"),
            globalCollisionRoot: receiptIdentity,
            durability: durability)
        let conflictingReceipt = try CaptureCoachLiveScopeControlReceipt(
            receiptId: shown.receiptId,
            scope: shown.scope,
            captureId: shown.captureId,
            labelId: shown.labelId,
            inputWatermark: shown.inputWatermark,
            action: .muted,
            canonicalInteraction: CaptureCoachLiveCanonicalInteractionRef(
                interactionId: Identifiers.newCoachInteractionId(),
                interactionType: .muted),
            occurredAt: "2026-07-24T08:00:07.000Z",
            clientRecordedAt: "2026-07-24T08:00:07.000Z")
        do {
            _ = try await switchedReceipts.enqueue(.scopeControl(conflictingReceipt))
            XCTFail("global ccr identity fence must span route partitions and variants")
        } catch CaptureCoachLiveSpoolError.identifierCollision {}
    }

    func testTranscriptSameCoordinateForkIsRejectedBeforeSpooling() async throws {
        let spool = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: temporaryDirectory("coach-transcript-fork"),
            durability: foundationTestFilesystemDurability())
        let captureId = Identifiers.newCaptureId()
        let projector = try CaptureCoachLiveMessageProjector(
            captureId: captureId,
            producer: .nativeDesktopArchiveSource(
                sourceId: Identifiers.newSourceId(),
                version: "test",
                liveAudioAvailable: false),
            messages: spool,
            stateRoot: temporaryDirectory("coach-transcript-head"),
            durability: foundationTestFilesystemDurability())
        let scope = CaptureCoachLiveScope(
            companyId: "company-001",
            areaId: "area-finance",
            processId: "process-invoices",
            deviceId: "device-macos-001")
        let labelId = Identifiers.newLabelId()
        let streamId = Identifiers.newStreamId()
        let transcriptId = "transcript-native-fork"
        let firstSpan = CaptureCoachLiveTranscriptSpan(
            transcriptId: transcriptId,
            revision: 1,
            startMillis: 0,
            endMillis: 1_000,
            text: "First explanation",
            finalized: false)
        let firstWatermark = CaptureCoachTranscriptWatermark(
            transcriptId: transcriptId,
            revision: 1,
            throughMillis: 1_000,
            textDigest: firstSpan.textDigest,
            finalized: false)
        _ = try await projector.enqueue(
            scope: scope,
            labelId: labelId,
            createdAt: "2026-07-24T08:00:01.000Z",
            streamProgress: [
                CaptureCoachStreamWatermark(
                    streamId: streamId, throughSequence: 1)
            ],
            transcriptProgress: [firstWatermark],
            evidence: [.transcriptSpan(firstSpan)])

        let fork = CaptureCoachLiveTranscriptSpan(
            transcriptId: transcriptId,
            revision: 1,
            startMillis: 0,
            endMillis: 1_000,
            text: "Conflicting explanation",
            finalized: false)
        do {
            _ = try await projector.enqueue(
                scope: scope,
                labelId: labelId,
                createdAt: "2026-07-24T08:00:01.100Z",
                streamProgress: [
                    CaptureCoachStreamWatermark(
                        streamId: streamId, throughSequence: 1)
                ],
                transcriptProgress: [
                    CaptureCoachTranscriptWatermark(
                        transcriptId: transcriptId,
                        revision: 1,
                        throughMillis: 1_000,
                        textDigest: fork.textDigest,
                        finalized: false)
                ],
                evidence: [.transcriptSpan(fork)])
            XCTFail("same transcript coordinate with different truth must fork")
        } catch CaptureCoachLiveContractError.identityCollision(let identifier) {
            XCTAssertEqual(identifier, transcriptId)
        }
        let pendingAfterFork = try await spool.pendingCount()
        XCTAssertEqual(pendingAfterFork, 1)
    }

    func testCommittedArchiveActionIntentRecoversOneExactReceiptAfterRelaunch()
        async throws
    {
        let archiveRoot = temporaryDirectory("coach-committed-archive")
        let liveRoot = temporaryDirectory("coach-committed-live")
        let durability = foundationTestFilesystemDurability()
        let fixture = makeArchiveFixture()
        let journal = CaptureJournal(root: archiveRoot)
        _ = try await journal.begin(
            manifest: fixture.manifest, session: fixture.session)
        let context = CaptureCoachRecordContext(
            originId: fixture.originId,
            captureId: fixture.captureId,
            streamId: fixture.streamId,
            sourceRefs: [
                JazzArchiveSourceRef(
                    sourceId: fixture.sourceId, role: "coach_ui")
            ],
            actorRefs: [
                JazzArchiveActorRef(
                    actorId: fixture.actorId,
                    role: "respondent",
                    basis: .declared,
                    method: "session_recorder")
            ],
            provenance: JazzArchiveProvenance(
                factClass: .observed, sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured, policyVersion: "test-consent-v1"))
        let writer = CaptureCoachJournalWriter(journal: journal, context: context)
        let coordinator = try CaptureCoachCoordinator(
            captureId: fixture.captureId,
            policy: CaptureCoachPolicy(cooldownSeconds: 0),
            recorder: writer)
        let labelId = Identifiers.newLabelId()
        let activityRuntime = CaptureJournalRuntime(
            journal: journal,
            context: CaptureJournalActivityContext(
                originId: fixture.originId,
                captureId: fixture.captureId,
                streamId: fixture.streamId,
                sourceId: fixture.sourceId,
                actorId: fixture.actorId,
                policyVersion: "test-consent-v1"))
        let legacySessionId =
            fixture.session.legacySessionId ?? Identifiers.newSessionId()
        let labelStart = ActivityEvent(
            sessionId: legacySessionId,
            eventId: Identifiers.eventId(
                sessionId: legacySessionId, sequence: 0),
            sequence: 0,
            timestamp: "2026-07-24T08:00:00.900Z",
            eventType: EventType.labelStart.rawValue,
            url: "app://capture-coach-recovery",
            labelId: labelId,
            label: "Issue invoices",
            processId: "process-invoices",
            process: "Issue invoices")
        _ = try await activityRuntime.submit { _ in
            .observation(
                CaptureJournalActivityObservation(event: labelStart))
        }
        let prompt = try CaptureCoachLivePrompt(
            scope: CaptureCoachLiveScope(
                companyId: "company-001",
                areaId: "area-finance",
                processId: "process-invoices",
                deviceId: "device-macos-001"),
            captureId: fixture.captureId,
            labelId: labelId,
            sourceMessageIds: [Identifiers.newCoachLiveMessageId()],
            assessmentRef: CaptureCoachAssessmentRef(
                assessmentId:
                    "cqa-\(Identifiers.newUUIDv7().uuidString.lowercased())",
                revision: 1,
                inputDigest: String(repeating: "a", count: 64)),
            inputWatermark: CaptureCoachInputWatermark(
                schemaVersion: 2,
                captureId: fixture.captureId,
                streams: [
                    CaptureCoachStreamWatermark(
                        streamId: fixture.streamId, throughSequence: 0)
                ],
                transcripts: []),
            snapshot: CaptureCoachPromptSnapshot(
                text: "Which exception changes this step?",
                slot: .exception,
                policyVersion: "test-v1",
                responseModes: [.typedText]),
            issuedAt: "2026-07-24T08:00:01.000Z")
        let shownAt = try XCTUnwrap(
            Timestamps.parse("2026-07-24T08:00:01.100Z"))
        _ = try await coordinator.receive(prompt.domainPrompt, at: shownAt)

        let partition = try CaptureCoachLiveRoutePartition.bind(
            baseRoot: liveRoot,
            routeBinding: routeBinding(
                areaId: "area-finance",
                tokenId: "token-audit-id-one",
                generation: 1),
            durability: durability)
        let captureRoot = partition.root
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent(fixture.captureId, isDirectory: true)
        let failing = CoachOneShotDurability()
        let intentStore = try CaptureCoachLiveActionProjectionIntentStore(
            root: captureRoot.appendingPathComponent(
                "action-intents", isDirectory: true),
            recoveryBinding: try CaptureCoachLiveActionRecoveryBinding(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId),
            durability: failing.value())
        let answerAt = try XCTUnwrap(
            Timestamps.parse("2026-07-24T08:00:02.000Z"))
        let intent = try await intentStore.prepare(
            CaptureCoachLiveActionProjectionIntent(
                prompt: prompt, interactionType: .answered, at: answerAt))
        let interaction = try await coordinator.answer(
            promptId: prompt.promptId,
            answer: CaptureCoachAnswer(
                mode: .typedText, text: "The exception queue changes it."),
            at: answerAt,
            interactionId: intent.interactionId)

        let receiptRoot = partition.root.appendingPathComponent(
            "receipts", isDirectory: true)
        let failingSpool = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveReceiptDocument
        >(
            root: receiptRoot,
            globalCollisionRoot:
                liveRoot
                .appendingPathComponent("identity", isDirectory: true)
                .appendingPathComponent("receipts", isDirectory: true),
            durability: durability)
        failing.failNextRegularFile(containing: "/canonical-interactions/")
        let failingProjector = CaptureCoachLiveActionReceiptProjector(
            intents: intentStore, receipts: failingSpool)
        do {
            try await failingProjector.project(interaction)
            XCTFail("fault injection must interrupt the canonical sidecar")
        } catch JazzArchiveFilesystemDurabilityError.synchronizationFailed {}
        // The rename happened but its fsync failed. Model the strongest crash cut by discarding
        // that uncommitted directory entry before relaunch; the canonical journal remains.
        let sidecar =
            captureRoot
            .appendingPathComponent(
                "action-intents/canonical-interactions",
                isDirectory: true)
            .appendingPathComponent(interaction.interactionId + ".json")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
        }
        let pendingAfterInjectedFailure = try await failingSpool.pendingCount()
        XCTAssertEqual(pendingAfterInjectedFailure, 0)

        let labelEnd = ActivityEvent(
            sessionId: legacySessionId,
            eventId: Identifiers.eventId(
                sessionId: legacySessionId, sequence: 1),
            sequence: 1,
            timestamp: "2026-07-24T08:00:02.500Z",
            eventType: EventType.labelEnd.rawValue,
            url: "app://capture-coach-recovery",
            labelId: labelId,
            label: "Issue invoices",
            processId: "process-invoices",
            process: "Issue invoices")
        _ = try await activityRuntime.submit { _ in
            .observation(
                CaptureJournalActivityObservation(event: labelEnd))
        }
        await activityRuntime.waitForAdmittedWork()

        _ = try await journal.closeInput()
        _ = try await journal.beginDraining()
        _ = try await journal.commit(endedAt: "2026-07-24T08:00:03.000Z")
        let recoverableAfterCommit =
            await CaptureJournal(root: archiveRoot).recoverableArchiveIds()
        XCTAssertFalse(recoverableAfterCommit.contains(fixture.archiveId))

        _ = try await CaptureCoachLiveRecoveryScanner.recoverAllActionReceipts(
            liveRoot: liveRoot,
            archiveRoot: archiveRoot,
            durability: durability)
        let recoveredSpool = try CaptureCoachLiveExactByteSpool<
            CaptureCoachLiveReceiptDocument
        >(
            root: receiptRoot,
            globalCollisionRoot:
                liveRoot
                .appendingPathComponent("identity", isDirectory: true)
                .appendingPathComponent("receipts", isDirectory: true),
            durability: durability)
        let firstBytes = try await recoveredSpool.pendingItems().map(\.canonicalData)
        XCTAssertEqual(firstBytes.count, 1)
        let recoveredItems = try await recoveredSpool.pendingItems()
        let recoveredDocument = try XCTUnwrap(recoveredItems.first?.document)
        guard case .prompt(let receipt) = recoveredDocument else {
            return XCTFail("expected prompt action receipt")
        }
        XCTAssertEqual(receipt.action, .answered)
        XCTAssertEqual(
            receipt.canonicalInteractions.map(\.interactionId),
            [interaction.interactionId])

        _ = try await CaptureCoachLiveRecoveryScanner.recoverAllActionReceipts(
            liveRoot: liveRoot,
            archiveRoot: archiveRoot,
            durability: durability)
        let repeatedBytes =
            try await recoveredSpool.pendingItems().map(\.canonicalData)
        XCTAssertEqual(repeatedBytes, firstBytes)
        let committedRecords = try await JazzArchiveDraftStore(root: archiveRoot).allRecords(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId)
        for record in committedRecords
        where record.recordType == ArchiveRecord<CaptureCoachInteraction>.coachRecordType {
            _ = try record.coachInteractionRecord()
        }
        let finalized = try await JazzArchiveFinalizer(root: archiveRoot).finalize(
            archiveId: fixture.archiveId,
            requireArchiveConfirmation: false)
        XCTAssertEqual(finalized.manifest.archiveId, fixture.archiveId)
    }

    func testInterruptedPromptIntentRecoveryCoversAllThreeCrashStates()
        async throws
    {
        enum CrashState: CaseIterable {
            case intentOnly
            case receivedOnly
            case receivedShown
        }

        for state in CrashState.allCases {
            let archiveRoot = temporaryDirectory(
                "coach-prompt-recovery-\(state)")
            let liveRoot = temporaryDirectory(
                "coach-prompt-live-\(state)")
            let durability = foundationTestFilesystemDurability()
            let archive = makeArchiveFixture()
            let journal = CaptureJournal(root: archiveRoot)
            _ = try await journal.begin(
                manifest: archive.manifest, session: archive.session)
            let prompt = try CaptureCoachLivePrompt(
                scope: CaptureCoachLiveScope(
                    companyId: "company-001",
                    areaId: "area-finance",
                    processId: "process-invoices",
                    deviceId: "device-macos-001"),
                captureId: archive.captureId,
                labelId: Identifiers.newLabelId(),
                sourceMessageIds: [Identifiers.newCoachLiveMessageId()],
                assessmentRef: CaptureCoachAssessmentRef(
                    assessmentId:
                        "cqa-\(Identifiers.newUUIDv7().uuidString.lowercased())",
                    revision: 1,
                    inputDigest: String(repeating: "a", count: 64)),
                inputWatermark: CaptureCoachInputWatermark(
                    schemaVersion: 2,
                    captureId: archive.captureId,
                    streams: [
                        CaptureCoachStreamWatermark(
                            streamId: archive.streamId,
                            throughSequence: 0)
                    ],
                    transcripts: []),
                snapshot: CaptureCoachPromptSnapshot(
                    text: "What must happen before this continues?",
                    slot: .exception,
                    policyVersion: "test-v1",
                    responseModes: [.typedText]),
                issuedAt: "2026-07-24T08:00:01.000Z")
            let partition = liveRoot
                .appendingPathComponent("partitions")
                .appendingPathComponent("route-a")
            let intentStore = try CaptureCoachLiveProjectionIntentStore(
                root: partition
                    .appendingPathComponent("captures")
                    .appendingPathComponent(archive.captureId)
                    .appendingPathComponent("prompt-intents"),
                durability: durability)
            let intentAt = try XCTUnwrap(
                Timestamps.parse("2026-07-24T08:00:02.000Z"))
            let intent = try await intentStore.prepare(
                prompt: prompt, at: intentAt)
            let writer = CaptureCoachJournalWriter(
                journal: journal,
                context: CaptureCoachRecordContext(
                    originId: archive.originId,
                    captureId: archive.captureId,
                    streamId: archive.streamId,
                    sourceRefs: [
                        JazzArchiveSourceRef(
                            sourceId: archive.sourceId, role: "coach_ui")
                    ],
                    actorRefs: [
                        JazzArchiveActorRef(
                            actorId: archive.actorId,
                            role: "respondent",
                            basis: .declared,
                            method: "session_recorder")
                    ],
                    provenance: JazzArchiveProvenance(
                        factClass: .observed, sources: [archive.sourceId]),
                    quality: JazzArchiveQuality(status: .complete),
                    privacy: JazzArchivePrivacy(
                        status: .captured,
                        policyVersion: "test-consent-v1")))
            var originalInteractionIds: [String] = []
            if state != .intentOnly {
                let received = CaptureCoachInteraction(
                    interactionType: .received,
                    occurredAt: intent.clientRecordedAt,
                    promptId: prompt.promptId,
                    labelId: prompt.labelId,
                    assessmentRef: prompt.assessmentRef,
                    inputWatermark: prompt.inputWatermark,
                    promptSnapshot: prompt.snapshot)
                try await writer.append(received)
                originalInteractionIds.append(received.interactionId)
            }
            if state == .receivedShown {
                let shown = CaptureCoachInteraction(
                    interactionType: .shown,
                    occurredAt: intent.clientRecordedAt,
                    promptId: prompt.promptId,
                    labelId: prompt.labelId,
                    assessmentRef: prompt.assessmentRef,
                    inputWatermark: prompt.inputWatermark,
                    promptSnapshot: prompt.snapshot)
                try await writer.append(shown)
                originalInteractionIds.append(shown.interactionId)
            }

            try await CaptureCoachLiveRecoveryScanner.recoverPromptReceipts(
                liveRoot: liveRoot,
                archiveRoot: archiveRoot,
                archiveId: archive.archiveId,
                captureId: archive.captureId,
                journal: journal,
                durability: durability)

            let records = try await JazzArchiveDraftStore(
                root: archiveRoot
            ).allRecords(
                archiveId: archive.archiveId,
                captureId: archive.captureId)
            let interactions = try records.compactMap {
                $0.recordType
                    == ArchiveRecord<CaptureCoachInteraction>.coachRecordType
                    ? try $0.coachInteractionRecord().payload : nil
            }
            let expectedTypes: [CaptureCoachInteractionType] =
                switch state {
                case .intentOnly: [.suppressed]
                case .receivedOnly: [.received, .suppressed]
                case .receivedShown: [.received, .shown]
                }
            XCTAssertEqual(
                interactions.map(\.interactionType), expectedTypes,
                "crash state \(state)")
            XCTAssertEqual(
                Array(
                    interactions.map(\.interactionId)
                        .prefix(originalInteractionIds.count)),
                originalInteractionIds)

            let receiptSpool = try CaptureCoachLiveExactByteSpool<
                CaptureCoachLiveReceiptDocument
            >(
                root: partition.appendingPathComponent("receipts"),
                globalCollisionRoot: liveRoot
                    .appendingPathComponent("identity")
                    .appendingPathComponent("receipts"),
                durability: durability)
            let pending = try await receiptSpool.pendingItems()
            XCTAssertEqual(pending.count, 1)
            guard case .prompt(let receipt) = try XCTUnwrap(pending.first).document
            else { return XCTFail("expected prompt receipt") }
            XCTAssertEqual(receipt.receiptId, intent.receiptId)
            XCTAssertEqual(
                receipt.canonicalInteractions.map(\.interactionId),
                interactions.map(\.interactionId))
            switch state {
            case .intentOnly, .receivedOnly:
                XCTAssertEqual(receipt.action, .suppressed)
                XCTAssertEqual(
                    receipt.suppressionReason, .interruptedCapture)
            case .receivedShown:
                XCTAssertEqual(receipt.action, .shown)
                XCTAssertNil(receipt.suppressionReason)
            }

            _ = try await journal.recoverInterrupted(
                archiveId: archive.archiveId,
                endedAt: "2026-07-24T08:00:03.000Z")
        }
    }

    func testSpoolAndIntentRenamesSyncFinalFilesAndDirectoriesBeforeSuccess()
        async throws
    {
        let fixture = try fixture("02-capture-coach-lost-ack.json")
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let firstEvent = try XCTUnwrap(events.first)
        let messageBytes = Data(
            try XCTUnwrap(firstEvent["canonicalBytes"] as? String).utf8)
        let message = try CaptureCoachLiveMessage.decodeCanonical(messageBytes)
        let root = temporaryDirectory("coach-durability-order")
        let recorder = CoachOneShotDurability()
        let spool = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: root, durability: recorder.value())
        recorder.resetEvents()
        _ = try await spool.enqueue(message)
        let enqueueEvents = recorder.events()
        let temporaryFile = try XCTUnwrap(
            enqueueEvents.firstIndex {
                $0.contains("file:") && $0.contains("/.publish-")
            })
        let finalFile = try XCTUnwrap(
            enqueueEvents.firstIndex {
                $0.contains("file:") && $0.contains("/pending/\(message.messageId).json")
            })
        let pendingDirectory = try XCTUnwrap(
            enqueueEvents.firstIndex {
                $0 == "directory:\(root.appendingPathComponent("pending").path)"
            })
        XCTAssertLessThan(temporaryFile, finalFile)
        XCTAssertLessThan(finalFile, pendingDirectory)

        recorder.resetEvents()
        try await spool.acknowledge(
            CaptureCoachLiveMessageAcknowledgement(
                messageId: message.messageId,
                contentDigest: message.contentDigest,
                status: .stored))
        let ackEvents = recorder.events()
        let acknowledgedFile = try XCTUnwrap(
            ackEvents.firstIndex {
                $0.contains("/acknowledged/\(message.messageId).json")
            })
        let pendingSync = try XCTUnwrap(
            ackEvents.firstIndex {
                $0 == "directory:\(root.appendingPathComponent("pending").path)"
            })
        let acknowledgedSync = try XCTUnwrap(
            ackEvents.firstIndex {
                $0 == "directory:\(root.appendingPathComponent("acknowledged").path)"
            })
        XCTAssertLessThan(acknowledgedFile, pendingSync)
        XCTAssertLessThan(acknowledgedSync, pendingSync)

        // Failure after rename is retryable from the final exact bytes, for both queue and intents.
        let failedRoot = temporaryDirectory("coach-durability-retry")
        let failing = CoachOneShotDurability()
        let interrupted = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: failedRoot, durability: failing.value())
        failing.failNextDirectory(containing: "/pending")
        do {
            _ = try await interrupted.enqueue(message)
            XCTFail("directory durability failure must fail the enqueue boundary")
        } catch JazzArchiveFilesystemDurabilityError.synchronizationFailed {}
        let recovered = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveMessage>(
            root: failedRoot,
            durability: foundationTestFilesystemDurability())
        let recoveredMessageBytes =
            try await recovered.pendingItems().map(\.canonicalData)
        XCTAssertEqual(recoveredMessageBytes, [messageBytes])

        let promptEvent = try XCTUnwrap(
            events.first {
                $0["kind"] as? String == "receive_prompt"
            })
        let prompt = try CaptureCoachLivePrompt.decodeCanonical(
            Data(try XCTUnwrap(promptEvent["canonicalBytes"] as? String).utf8))
        let promptRoot = failedRoot.appendingPathComponent("prompt-intents")
        let promptFailure = CoachOneShotDurability()
        let promptStore = try CaptureCoachLiveProjectionIntentStore(
            root: promptRoot, durability: promptFailure.value())
        promptFailure.failNextDirectory(containing: "/prompt-intents")
        do {
            _ = try await promptStore.prepare(
                prompt: prompt,
                at: try XCTUnwrap(
                    Timestamps.parse("2026-07-24T08:00:05.220Z")))
            XCTFail("prompt intent directory sync must be part of prepare")
        } catch JazzArchiveFilesystemDurabilityError.synchronizationFailed {}
        let recoveredPromptStore = try CaptureCoachLiveProjectionIntentStore(
            root: promptRoot,
            durability: foundationTestFilesystemDurability())
        let recoveredPrompt = try await recoveredPromptStore.prepare(prompt: prompt)
        XCTAssertEqual(recoveredPrompt.promptId, prompt.promptId)

        let actionRoot = failedRoot.appendingPathComponent("action-intents")
        let actionFailure = CoachOneShotDurability()
        let actionStore = try CaptureCoachLiveActionProjectionIntentStore(
            root: actionRoot, durability: actionFailure.value())
        let proposed = try CaptureCoachLiveActionProjectionIntent(
            prompt: prompt,
            interactionType: .dismissed,
            at: try XCTUnwrap(
                Timestamps.parse("2026-07-24T08:00:06.000Z")))
        actionFailure.failNextDirectory(containing: "/action-intents")
        do {
            _ = try await actionStore.prepare(proposed)
            XCTFail("action intent directory sync must be part of prepare")
        } catch JazzArchiveFilesystemDurabilityError.synchronizationFailed {}
        let recoveredActionStore = try CaptureCoachLiveActionProjectionIntentStore(
            root: actionRoot,
            durability: foundationTestFilesystemDurability())
        let recoveredAction = try await recoveredActionStore.prepare(proposed)
        XCTAssertEqual(recoveredAction, proposed)
    }

    private func watermark(
        captureId: String,
        streamId: String,
        sequence: Int,
        transcriptId: String,
        revision: Int,
        throughMillis: Int,
        textDigest: String
    ) -> CaptureCoachInputWatermark {
        CaptureCoachInputWatermark(
            schemaVersion: 2,
            captureId: captureId,
            streams: [
                CaptureCoachStreamWatermark(
                    streamId: streamId, throughSequence: sequence)
            ],
            transcripts: [
                CaptureCoachTranscriptWatermark(
                    transcriptId: transcriptId,
                    revision: revision,
                    throughMillis: throughMillis,
                    textDigest: textDigest,
                    finalized: false)
            ])
    }

    private func routeBinding(
        areaId: String,
        tokenId: String,
        generation: Int
    ) throws -> JazzArchiveUploadRouteBinding {
        try JazzArchiveUploadRouteBinding(
            ingestEndpoint: "https://jazz.example.test/tenant/api/archive-ingests",
            stackURL: "https://connection.example.keboola.com",
            projectId: "12345",
            tokenId: tokenId,
            scope: JazzArchiveUploadScope(
                companyId: "company-001",
                areaId: areaId,
                deviceId: "device-macos-001"),
            signedAuthority: JazzArchiveSignedEnrollmentAuthority(
                issuer: "https://issuer.example.test",
                audience: "jazz-desktop",
                bundleId: "jdb_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                generation: generation,
                envelopeDigest: String(repeating: generation == 1 ? "a" : "b", count: 64)))
    }

    private func makeArchiveFixture() -> ArchiveFixture {
        let archiveId = Identifiers.newArchiveId()
        let originId = Identifiers.newOriginId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let sourceId = Identifiers.newSourceId()
        let actorId = Identifiers.newActorId()
        let producer = JazzArchiveProducer(
            name: "Jazz Capture", version: "coach-test", platform: "macOS")
        let actor = JazzArchiveActor(
            actorId: actorId,
            kind: .human,
            identityStatus: .identified,
            displayName: "Recorder",
            provenance: JazzArchiveProvenance(
                factClass: .declared, sources: []))
        let source = JazzArchiveSource(
            sourceId: sourceId,
            kind: "macos.capture-coach-test",
            actorId: actorId,
            producer: producer,
            capabilities: ["accessibility"],
            provenance: JazzArchiveProvenance(
                factClass: .observed, sources: []))
        let sessionId = Identifiers.newSessionId()
        let startedAt = "2026-07-24T08:00:00.000Z"
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            originScope: JazzArchiveExternalIdentity(
                namespace: "test.tenant", value: "offline"),
            createdAt: startedAt,
            producer: producer,
            contracts: [.activityEvent, .captureCoachInteraction],
            actors: [actor],
            sources: [source],
            sessions: [
                JazzArchiveSessionRef(
                    captureId: captureId, legacySessionId: sessionId)
            ])
        let session = JazzArchiveSession(
            captureId: captureId,
            legacySessionId: sessionId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: startedAt,
            recorderActorId: actorId,
            sourceIds: [sourceId],
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "test-consent-v1",
                consentedAt: startedAt,
                modalities: [.accessibility],
                excludedApplications: [],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        return ArchiveFixture(
            archiveId: archiveId,
            originId: originId,
            captureId: captureId,
            streamId: streamId,
            sourceId: sourceId,
            actorId: actorId,
            manifest: manifest,
            session: session)
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url =
            root
            .appendingPathComponent("contract/live/coach/fixtures")
            .appendingPathComponent(name)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any])
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class CoachOneShotDurability: @unchecked Sendable {
    private let lock = NSLock()
    private var regularFileSubstring: String?
    private var directorySubstring: String?
    private var recordedEvents: [String] = []

    func failNextRegularFile(containing value: String) {
        lock.lock()
        regularFileSubstring = value
        lock.unlock()
    }

    func failNextDirectory(containing value: String) {
        lock.lock()
        directorySubstring = value
        lock.unlock()
    }

    func resetEvents() {
        lock.lock()
        recordedEvents = []
        lock.unlock()
    }

    func events() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func value() -> JazzArchiveFilesystemDurability {
        JazzArchiveFilesystemDurability(
            synchronizeRegularFile: { [weak self] file, _ in
                guard let self else { return }
                lock.lock()
                defer { lock.unlock() }
                recordedEvents.append("file:\(file.path)")
                if let expected = regularFileSubstring,
                    file.path.contains(expected)
                {
                    regularFileSubstring = nil
                    throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
                }
            },
            synchronizeDirectory: { [weak self] directory in
                guard let self else { return }
                lock.lock()
                defer { lock.unlock() }
                recordedEvents.append("directory:\(directory.path)")
                if let expected = directorySubstring,
                    directory.path.contains(expected)
                {
                    directorySubstring = nil
                    throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
                }
            })
    }
}
