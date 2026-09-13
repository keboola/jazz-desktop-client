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
    }
}
