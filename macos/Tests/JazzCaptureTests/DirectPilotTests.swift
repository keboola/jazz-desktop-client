import Foundation
import XCTest
@testable import JazzCapture
@testable import JazzCaptureCore

@MainActor
final class DirectPilotTests: XCTestCase {
    private final class Accepted: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!,
                statusCode: request.httpMethod == "PUT" ? 204 : 200,
                httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            if request.httpMethod != "PUT" { client?.urlProtocol(self, didLoad: Data("{}".utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private final class TokenResponse: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let size = request.url?.host == "oversize.invalid" ? 70_000 : 1
            let body = try! JSONSerialization.data(withJSONObject: ["id": "42",
                "owner": ["id": 3044, "name": "test"], "description": String(repeating: "x", count: size)])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private func wait(_ ready: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !ready() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("physical owner did not return"); throw URLError(.timedOut)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jazz-direct-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testUnscopedActualPilotEntryRefusesStartAndRemainsStopped() async throws {
        XCTAssertFalse(DirectPilotProfile.enabled)
        XCTAssertEqual(Keychain.service, "dev.jazz.capture")
        let pilot = CaptureController.DirectPilot()
        pilot.start()
        try await wait { !pilot.starting }
        XCTAssertFalse(pilot.capturing)
        XCTAssertTrue(pilot.status.contains("blocked"))
        pilot.stop(.pause)
        pilot.stop(.lock)
        pilot.stop(.revoked)
        XCTAssertFalse(pilot.capturing)
        XCTAssertTrue(pilot.quiescent)
        XCTAssertTrue(pilot.status.contains("explicit Resume"))
    }
    func testActualDriverFileAdapterAndPauseFenceRetainPhysicalOwner() async throws {
        let root = try directory()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Accepted.self]
        var request = URLRequest(url: URL(string: "https://jazz-qual.invalid/v1/logs")!)
        request.httpMethod = "POST"
        let limits = CaptureController.DirectPilot.limits
        XCTAssertEqual(limits.units, 32)
        XCTAssertEqual(limits.bytes, 8 * 1024 * 1024)
        XCTAssertEqual(limits.encodingParts, 2)
        let driver = try BestEffortTransportDriver(limits: limits, eventRequest: request,
            authorityDeadline: 60, configuration: config, now: { 0 }, automaticallySchedule: false)
        let intent = CaptureStartIntent(root: root, continuous: true,
            durability: JazzArchiveFilesystemDurability(synchronizeRegularFile: { _, _ in }, synchronizeDirectory: { _ in }))
        intent.completeRecovery(succeeded: true)
        XCTAssertTrue(intent.attachBestEffortDelivery(driver))
        let token = try XCTUnwrap(intent.requestStart(explicit: true))
        let started = await intent.runStart(token, recovery: { true }, prepare: { true },
            enable: { driver.startExplicitly(generation: token) }, abort: {})
        XCTAssertTrue(started)
        let bytes = Data("synthetic pilot bytes".utf8)
        let file = root.appendingPathComponent("sealed.bin")
        try bytes.write(to: file)
        let params = try JSONDecoder().decode(KeboolaAPI.FilesPrepare.GCSUploadParams.self,
            from: Data(#"{"access_token":"synthetic-not-a-real-token","bucket":"jazz-qual-test","key":"pilot.bin"}"#.utf8))
        let media = try BestEffortFileEncoder.preparedGCS(file: file, expectedBytes: bytes.count,
            sha256: JazzArchiveDigest.sha256Hex(bytes), params: params,
            contentType: "application/octet-stream", expiresAt: 30)
        XCTAssertTrue(driver.offer(unitID: UUID(), generation: token, logs: .init(resourceLogs: []), media: media))
        try await wait { driver.snapshot.units == 0 }
        let report = try XCTUnwrap(driver.drainReports().first)
        XCTAssertEqual(report.event, .hopAccepted)
        XCTAssertEqual(report.media, .hopAccepted)
        XCTAssertEqual(try Data(contentsOf: file), bytes)

        let entered = expectation(description: "reserved encoder entered")
        let release = DispatchSemaphore(value: 0)
        let held = BestEffortTransportDriver.Media(request: media.request, maximumBytes: bytes.count,
            expiresAt: 30) { _, _ in
            entered.fulfill(); release.wait(); return bytes
        }
        XCTAssertTrue(driver.offer(unitID: UUID(), generation: token, logs: .init(resourceLogs: []), media: held))
        await fulfillment(of: [entered], timeout: 5)
        intent.pause()
        XCTAssertFalse(intent.bestEffortIsQuiescent)
        XCTAssertNil(intent.requestStart(explicit: true))
        XCTAssertFalse(driver.offer(unitID: UUID(), generation: token, logs: .init(resourceLogs: [])))
        release.signal()
        try await wait { intent.bestEffortIsQuiescent }
        let resumed = try XCTUnwrap(intent.requestStart(explicit: true))
        XCTAssertNotEqual(resumed, token)
        intent.pause()
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testStopBeforeScheduledStartPreservesStopWithoutAttemptingAuthorization() async throws {
        let pilot = CaptureController.DirectPilot()
        pilot.start(); pilot.stop(.pause)
        let paused = pilot.status
        try await wait { !pilot.starting }
        XCTAssertEqual(pilot.status, paused)
        XCTAssertFalse(pilot.capturing)
        XCTAssertTrue(pilot.quiescent)
    }

    func testCredentialReadReturnsOffMainAndStopDiscardsItsLateValue() async throws {
        let pilot = CaptureController.DirectPilot()
        let entered = expectation(description: "simulated credential read entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let read = Task {
            try await pilot.loadCredential {
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill(); release.wait()
                return "synthetic-only"
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        pilot.stop(.lock) // Must run while the foreign read is still blocked.
        release.signal()
        do { _ = try await read.value; XCTFail("late credential escaped Stop") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(pilot.capturing)
    }

    func testVerificationReplyIsBoundedBeforeDecoding() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TokenResponse.self]
        let http = JazzCredentialSafeHTTPSession(configuration: config)
        defer { http.invalidateAndCancel() }
        let small = await KeboolaClient.verifyToken(token: "synthetic", stacks: ["https://small.invalid"],
            maximumResponseBytes: 65536, using: http)
        XCTAssertEqual(small?.verify.id, "42")
        let large = await KeboolaClient.verifyToken(token: "synthetic", stacks: ["https://oversize.invalid"],
            maximumResponseBytes: 65536, using: http)
        XCTAssertNil(large)
        XCTAssertLessThanOrEqual(http.boundedResponseUsage.peakBytes, 65536)
    }

    func testPilotWindowSelectionRejectsBackgroundFallbackAndAmbiguity() {
        let focus = CGRect(x: 100, y: 80, width: 400, height: 300)
        let background = CGRect(x: 0, y: 0, width: 1200, height: 1000)
        XCTAssertEqual(ScreenCapture.pilotWindowIndex(frames: [background, focus], focused: focus), 1)
        XCTAssertNil(ScreenCapture.pilotWindowIndex(frames: [background], focused: focus))
        XCTAssertNil(ScreenCapture.pilotWindowIndex(frames: [focus, focus], focused: focus))
        XCTAssertNil(ScreenCapture.pilotWindowIndex(frames: [focus], focused: nil))
    }

    func testMediaAcquisitionSkipsFencedBusyAndFullQueue() throws {
        let transport = BestEffortTransport(limits: CaptureController.DirectPilot.limits)
        let token = UUID()
        XCTAssertFalse(CaptureController.DirectPilot.mediaHasCapacity(transport.snapshot))
        XCTAssertTrue(transport.startExplicitly(generation: token, now: 0))
        XCTAssertTrue(CaptureController.DirectPilot.mediaHasCapacity(transport.snapshot))
        for _ in 0..<CaptureController.DirectPilot.limits.units {
            let ticket = try XCTUnwrap(transport.reserve(unitID: UUID(), eventBytes: 1, generation: token, now: 0))
            XCTAssertFalse(CaptureController.DirectPilot.mediaHasCapacity(transport.snapshot))
            transport.finishEncoding(ticket, component: .event, data: Data([1]), now: 0)
        }
        XCTAssertFalse(CaptureController.DirectPilot.mediaHasCapacity(transport.snapshot))
        transport.suspend(.stop)
        XCTAssertEqual(transport.snapshot.units, 0)
        XCTAssertFalse(CaptureController.DirectPilot.mediaHasCapacity(transport.snapshot))
    }

    func testRetiredReportOverflowDoesNotCancelPendingExplicitStart() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Accepted.self]
        var request = URLRequest(url: URL(string: "https://jazz-qual.invalid/v1/logs")!); request.httpMethod = "POST"
        let limits = try BestEffortTransport.Limits(units: 1, bytes: 1024, partBytes: 512,
            encodingParts: 2, inFlight: 1, inFlightBytes: 512)
        let driver = try BestEffortTransportDriver(limits: limits, eventRequest: request,
            authorityDeadline: 60, configuration: config, now: { 0 }, automaticallySchedule: false)
        let token = UUID(); XCTAssertTrue(driver.startExplicitly(generation: token))
        for _ in 0..<2 {
            XCTAssertTrue(driver.offer(unitID: UUID(), generation: token, logs: .init(resourceLogs: [])))
            try await wait { driver.snapshot.units == 0 }
        }
        XCTAssertTrue(driver.adapterUsage.overflow)
        let pilot = CaptureController.DirectPilot()
        pilot.start()
        let status = pilot.status
        pilot.collectDeliveryReports(from: driver)
        XCTAssertEqual(pilot.status, status) // Old overflow must not fence a fresh handshake each tick.
        try await wait { !pilot.starting } // Missing test-bundle profile still denies native startup.
        driver.suspend(.stop)
    }

    func testProductionBatchCorrelatesFileBytesIdsAndAcquisitionInterval() throws {
        struct Fixture: Decodable { let epoch: JazzBestEffortEpoch }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("JazzCaptureCoreTests/Fixtures/best-effort-v1.json")
        let epoch = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixture)).epoch
        let source = Identifiers.newSourceId(), stream = Identifiers.newStreamId()
        let bytes = Data("synthetic JPEG stand-in".utf8), digest = JazzArchiveDigest.sha256Hex(bytes)
        let started = try XCTUnwrap(Timestamps.parse(epoch.startedAt)).addingTimeInterval(10)
        let shot = ScreenCapture.Shot(data: bytes, hash: 1, requestStartedAt: started,
            frameCompletedAt: started.addingTimeInterval(0.25), monotonicDurationMillis: 250,
            scope: .window(ownerBundleID: "com.apple.TextEdit", windowID: 42))
        let interval = ScreenCapture.assess(shot, expectedOwnerBundleID: "com.apple.TextEdit").captureInterval
        let event = ActivityEvent(sessionId: epoch.captureId, eventId: Identifiers.eventId(sessionId: epoch.captureId, sequence: 7),
            sequence: 7, timestamp: epoch.startedAt, eventType: "click", url: "app://com.apple.TextEdit",
            inputMasked: true, screenshotId: "12345")
        let content = JazzArchiveArtifactContent(path: "blobs/sha256/\(digest.prefix(2))/\(digest)",
            mediaType: "image/jpeg", byteLength: Int64(bytes.count), sha256: digest)
        let logs = try CaptureController.DirectPilot.logs(for: event, epoch: epoch, stream: stream, source: source,
            content: content, interval: interval)
        let rows = logs.resourceLogs.flatMap { $0.scopeLogs.flatMap(\.logRecords) }
        let envelopes = try rows.map { row -> JazzBestEffortEnvelope in
            let canonical = try XCTUnwrap(row.attributes.first { $0.key == "jazz.best_effort.canonical" })
            guard case .string(let text) = canonical.value else { throw JazzBestEffortContract.Failure.invalid }
            return try JazzBestEffortContract.decode(JazzBestEffortEnvelope.self, from: Data(text.utf8))
        }
        XCTAssertEqual(envelopes.count, 2)
        for envelope in envelopes { try envelope.validate(epoch: epoch) }
        let record = try envelopes[0].item.observationRecord()
        let artifact = try envelopes[1].item.artifactDocument()
        XCTAssertEqual(record.streamId, stream); XCTAssertEqual(record.streamSequence, 7)
        XCTAssertEqual(record.sourceRefs.first?.sourceId, source)
        XCTAssertEqual(artifact.sourceRefs.first?.sourceId, source)
        XCTAssertEqual(record.artifactRefs.first?.artifactId, artifact.artifactId)
        XCTAssertEqual(artifact.observationRefs, [record.observationId])
        XCTAssertEqual(artifact.content, content)
        XCTAssertEqual(artifact.captureInterval, interval)
        XCTAssertNotEqual(artifact.captureInterval?.startedAt, epoch.startedAt)
        let payload = try JSONDecoder().decode(ActivityEvent.self, from: JazzArchiveCanonicalJSON.encode(record.payload))
        XCTAssertEqual(payload.screenshotId, "12345"); XCTAssertNil(payload.screenshotDataUrl)
        XCTAssertEqual(envelopes[1].mediaState, "pending")
    }

    func testSinglePCMReplacementAndWaveEncodingStayBounded() throws {
        let mailbox = DirectPilotPCM()
        let bytes = Data(repeating: 0, count: 64000)
        let first = try CaptureCoachLivePCMChunk(sequence: 0, startMillis: 0, endMillis: 2000,
            recordedAt: Timestamps.iso8601(), bytes: bytes)
        let next = try CaptureCoachLivePCMChunk(sequence: 1, startMillis: 2000, endMillis: 4000,
            recordedAt: Timestamps.iso8601(), bytes: Data([1, 0]))
        mailbox.offer(first); mailbox.offer(next)
        XCTAssertEqual(mailbox.drops, 1)
        XCTAssertEqual(mailbox.take()?.bytes, next.bytes)
        XCTAssertNil(mailbox.take())
        let wav = DirectPilotPCM.wave(bytes)
        XCTAssertEqual(wav.count, 64044)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(wav.suffix(bytes.count), bytes)
        let interval = try XCTUnwrap(DirectPilotPCM.interval(for: first))
        let start = try XCTUnwrap(Timestamps.parse(interval.startedAt))
        let end = try XCTUnwrap(Timestamps.parse(interval.endedAt))
        XCTAssertEqual(end.timeIntervalSince(start), 2, accuracy: 0.001)
        XCTAssertEqual(interval.endedAt, first.recordedAt)
    }
}
