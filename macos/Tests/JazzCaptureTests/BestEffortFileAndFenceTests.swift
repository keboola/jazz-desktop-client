import CryptoKit
import Darwin
import Foundation
import ImageIO
import XCTest

@testable import JazzCapture
@testable import JazzCaptureCore

@MainActor
final class BestEffortFileAndFenceTests: XCTestCase {
    private final class Offline: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        static let lock = NSLock()
        static var bodies: [String: Data] = [:]
        override func startLoading() {
            var data = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1024)
                while data.count <= 2 * 1024 * 1024 {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
            }
            let path = request.url!.path
            Self.lock.withLock { Self.bodies[path] = data }
            let status = path.contains("reject") ? 400 : request.httpMethod == "PUT" ? 204 : 200
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            if status == 200 { client?.urlProtocol(self, didLoad: Data("{}".utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-adapter-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func params(key: String = "synthetic/object #1.bin") throws
        -> KeboolaAPI.FilesPrepare.GCSUploadParams
    {
        let object = [
            "access_token": "synthetic-not-a-real-token", "bucket": "synthetic-bucket", "key": key,
        ]
        return try JSONDecoder().decode(
            KeboolaAPI.FilesPrepare.GCSUploadParams.self,
            from: JSONSerialization.data(withJSONObject: object))
    }
    private final class Clock: @unchecked Sendable {
        let lock = NSLock()
        private var time: TimeInterval = 0
        func read() -> TimeInterval { lock.withLock { time } }
        func expire() { lock.withLock { time = 100 } }
        func invalidate() { lock.withLock { time = .nan } }
    }
    private func driver(
        path: String = "/v1/logs", now: @escaping @Sendable () -> TimeInterval = { 0 }
    ) throws -> BestEffortTransportDriver {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Offline.self]
        var request = URLRequest(url: URL(string: "https://synthetic.invalid\(path)")!)
        request.httpMethod = "POST"
        let limits = try BestEffortTransport.Limits()
        return try BestEffortTransportDriver(
            limits: limits, eventRequest: request, authorityDeadline: 100,
            configuration: configuration, now: now, automaticallySchedule: false)
    }
    private func intent(_ root: URL) -> CaptureStartIntent {
        let intent = CaptureStartIntent(
            root: root, continuous: true,
            durability: JazzArchiveFilesystemDurability(
                synchronizeRegularFile: { _, _ in }, synchronizeDirectory: { _ in }))
        intent.completeRecovery(succeeded: true)
        return intent
    }
    private func arm(_ intent: CaptureStartIntent) async throws -> UUID {
        let token = try XCTUnwrap(intent.requestStart(explicit: true))
        let result = await intent.runStart(
            token, recovery: { true }, prepare: { true }, enable: { true }, abort: {})
        XCTAssertTrue(result)
        return token
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < end else {
                XCTFail("bounded wait expired")
                throw URLError(.timedOut)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    func testPreparedGCSBridgeBindsExactReadOnlyFileBytesAndEscapesObjectKey() throws {
        let file = try root().appendingPathComponent("sealed.bin")
        let bytes = Data([0, 1, 2, 3])
        try bytes.write(to: file)
        let media = try BestEffortFileEncoder.preparedGCS(
            file: file, expectedBytes: bytes.count, sha256: digest(bytes),
            params: params(), contentType: "application/octet-stream", expiresAt: 30)
        XCTAssertEqual(media.request.httpMethod, "PUT")
        XCTAssertEqual(media.request.url?.host, "storage.googleapis.com")
        XCTAssertEqual(media.request.url?.path, "/synthetic-bucket/synthetic/object #1.bin")
        XCTAssertNil(media.request.url?.query)
        XCTAssertNil(media.request.url?.fragment)
        XCTAssertEqual(try media.encode(4, { false }), bytes)
        XCTAssertThrowsError(try media.encode(3, { false }))
        XCTAssertThrowsError(try media.encode(4, { true }))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertThrowsError(
            try BestEffortFileEncoder.preparedGCS(
                file: file, expectedBytes: 4, sha256: digest(bytes),
                params: params(key: "../other-object"), contentType: "application/octet-stream",
                expiresAt: 30))
    }
    func testConcreteFileEncoderAndHTTPDriverComposeWithIndependentFailures() async throws {
        let file = try root().appendingPathComponent("sealed.bin")
        let bytes = Data([7, 8, 9])
        try bytes.write(to: file)
        for eventFails in [false, true] {
            let key = eventFails ? "media-ok" : "reject-media"
            let media = try BestEffortFileEncoder.preparedGCS(
                file: file, expectedBytes: bytes.count,
                sha256: digest(bytes), params: params(key: key),
                contentType: "application/octet-stream", expiresAt: 30)
            let d = try driver(path: eventFails ? "/reject-events" : "/v1/logs")
            let token = UUID()
            defer { d.suspend(.stop) }
            XCTAssertTrue(d.startExplicitly(generation: token))
            XCTAssertTrue(
                d.offer(
                    unitID: UUID(), generation: token, logs: .init(resourceLogs: []), media: media))
            try await wait { d.snapshot.units == 0 }
            let report = try XCTUnwrap(d.drainReports().first)
            XCTAssertEqual(report.event, eventFails ? .unavailable : .hopAccepted)
            XCTAssertEqual(report.media, eventFails ? .hopAccepted : .unavailable)
            XCTAssertEqual(Offline.lock.withLock { Offline.bodies[media.request.url!.path] }, bytes)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testNativeJPEGConsumerCapsOutputAndRejectsPixelBudgetAndCancellation() async throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8,
                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let encoded = try XCTUnwrap(
            BestEffortImageEncoder.jpeg(
                image, maximumBytes: 4096,
                maximumPixelBytes: 16, quality: 0.85, cancelled: { false }))
        XCTAssertLessThanOrEqual(encoded.count, 4096)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 2)
        let request = try BestEffortFileEncoder.putRequest(
            params: params(key: "memory-jpeg"), contentType: "image/jpeg")
        let media = BestEffortTransportDriver.Media(
            request: request, maximumBytes: 4096, expiresAt: 30
        ) { limit, cancelled in
            guard
                let data = BestEffortImageEncoder.jpeg(
                    image, maximumBytes: limit, maximumPixelBytes: 16, quality: 0.85,
                    cancelled: cancelled)
            else {
                throw BestEffortTransportDriver.Failure.oversizedEncoding
            }
            return data
        }
        let d = try driver()
        let token = UUID()
        defer { d.suspend(.stop) }
        XCTAssertTrue(d.startExplicitly(generation: token))
        XCTAssertTrue(
            d.offer(unitID: UUID(), generation: token, logs: .init(resourceLogs: []), media: media))
        try await wait { d.snapshot.units == 0 }
        XCTAssertEqual(d.drainReports().first?.media, .hopAccepted)
        let uploaded = try XCTUnwrap(Offline.lock.withLock { Offline.bodies[request.url!.path] })
        XCTAssertEqual(uploaded, encoded)
        XCTAssertEqual(d.snapshot.temporaryFileBytes, 0)
        XCTAssertNil(
            BestEffortImageEncoder.jpeg(
                image, maximumBytes: 16, maximumPixelBytes: 16, quality: 0.85, cancelled: { false })
        )
        XCTAssertNil(
            BestEffortImageEncoder.jpeg(
                image, maximumBytes: 4096, maximumPixelBytes: 15, quality: 0.85,
                cancelled: { false }))
        XCTAssertNil(
            BestEffortImageEncoder.jpeg(
                image, maximumBytes: 4096, maximumPixelBytes: 16, quality: 0.85, cancelled: { true }
            ))
        XCTAssertNil(
            BestEffortImageEncoder.jpeg(
                image, maximumBytes: 4096, maximumPixelBytes: 16, quality: .nan,
                cancelled: { false }))
    }

    func testFileSizeDigestSymlinkFIFOAndMidReadCancellationFailClosedWithoutDeleting() throws {
        let root = try root()
        let file = root.appendingPathComponent("sealed.bin")
        let bytes = Data(repeating: 42, count: 256 * 1024)
        try bytes.write(to: file)
        func read(_ url: URL, size: Int = 256 * 1024, hash: String? = nil) throws -> Data {
            try BestEffortFileEncoder.read(
                file: url, expectedBytes: size, sha256: hash ?? digest(bytes), limit: bytes.count,
                cancelled: { false })
        }
        XCTAssertThrowsError(try read(file, size: bytes.count - 1))
        XCTAssertThrowsError(try read(file, hash: String(repeating: "0", count: 64)))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try read(link))
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try read(fifo))
        var checks = 0
        XCTAssertThrowsError(
            try BestEffortFileEncoder.read(
                file: file, expectedBytes: bytes.count,
                sha256: digest(bytes), limit: bytes.count,
                cancelled: {
                    checks += 1
                    return checks >= 3
                }))
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fifo.path))
    }
    func testFileEncoderTurnoverHasBoundedRSSAndNoTemporaryOutput() throws {
        let root = try root()
        let file = root.appendingPathComponent("sealed.bin")
        let bytes = Data(repeating: 17, count: 1024 * 1024)
        let hash = digest(bytes)
        try bytes.write(to: file)
        let beforeFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var before = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        for _ in 0..<128 {
            try autoreleasepool {
                XCTAssertEqual(
                    try BestEffortFileEncoder.read(
                        file: file, expectedBytes: bytes.count,
                        sha256: hash, limit: bytes.count, cancelled: { false }
                    ).count, bytes.count)
            }
        }
        var after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        let growth = max(0, after.ru_maxrss - before.ru_maxrss)
        print("S2 File encoder: 128MiB turnover, 1MiB file, peak RSS growth bytes: \(growth)")
        XCTAssertLessThan(growth, 64 * 1024 * 1024)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), beforeFiles)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testPauseAndRotationFenceTheAttachedWorkerAndWaitForPhysicalEncoderReturn() async throws {
        for rotation in [false, true] {
            let d = try driver()
            let i = intent(try root())
            XCTAssertTrue(i.attachBestEffortDelivery(d))
            XCTAssertFalse(i.attachBestEffortDelivery(d))
            let token = try await arm(i)
            XCTAssertTrue(d.startExplicitly(generation: token))
            let entered = expectation(description: "physical encoder entered")
            let release = DispatchSemaphore(value: 0)
            defer {
                release.signal()
                d.suspend(.stop)
            }
            var request = URLRequest(url: URL(string: "https://synthetic.invalid/media")!)
            request.httpMethod = "PUT"
            let media = BestEffortTransportDriver.Media(
                request: request, maximumBytes: 4, expiresAt: 30
            ) { _, _ in
                entered.fulfill()
                release.wait()
                return Data([1, 2, 3, 4])
            }
            XCTAssertTrue(
                d.offer(
                    unitID: UUID(), generation: token, logs: .init(resourceLogs: []), media: media))
            await fulfillment(of: [entered], timeout: 3)
            if rotation {
                let next = try XCTUnwrap(i.requestRotation())
                let resumed = await i.runRotation(
                    next, close: { true }, eligible: { true },
                    start: { _ in
                        XCTFail("logical close cannot release a physical encoder")
                        return true
                    })
                XCTAssertFalse(resumed)
            } else {
                i.pause()
            }
            XCTAssertFalse(i.bestEffortIsQuiescent)
            XCTAssertNil(i.requestStart(explicit: true))
            XCTAssertFalse(
                d.offer(unitID: UUID(), generation: token, logs: .init(resourceLogs: [])))
            release.signal()
            try await wait { i.bestEffortIsQuiescent }
            d.tick()  // No implicit restart after physical completion or network recovery.
            XCTAssertNotNil(d.snapshot.fence)
            XCTAssertFalse(i.isArmed)
        }
    }
    func testAuthorityExpiryNotifiesPhysicalFenceOnceAndStaleNotificationCannotStopNewIntent()
        async throws
    {
        for stale in [false, true] {
            let clock = Clock()
            let i = intent(try root())
            let d = try driver(now: { clock.read() })
            let flight = ScreenCaptureSingleFlight()
            XCTAssertTrue(i.attachBestEffortDelivery(d))
            let token = try await arm(i)
            XCTAssertTrue(d.startExplicitly(generation: token))
            XCTAssertTrue(flight.open(eligible: { true }))
            var notifications = 0
            i.onBestEffortRevocation = {
                notifications += 1
                flight.close()
            }
            clock.expire()
            d.tick()  // Notification is enqueued, never reenters the worker lock.
            if stale { i.pause() }  // Invalidate that message before MainActor can deliver it.
            await Task.yield()
            if !stale { try await wait { notifications == 1 } }
            d.tick()
            await Task.yield()
            XCTAssertEqual(notifications, stale ? 0 : 1)
            if !stale {
                XCTAssertTrue(flight.isClosedAndQuiescent)
                XCTAssertFalse(i.isArmed)
            }
            flight.close()
        }
    }

    func testInvalidMonotonicClockClosesTheNativeOwner() async throws {
        let clock = Clock()
        let i = intent(try root())
        let d = try driver(now: { clock.read() })
        XCTAssertTrue(i.attachBestEffortDelivery(d))
        let token = try await arm(i)
        XCTAssertTrue(d.startExplicitly(generation: token))
        var fenced = false
        i.onBestEffortRevocation = { fenced = true }
        clock.invalidate()
        d.tick()
        try await wait { fenced }
        XCTAssertFalse(i.isArmed)
        XCTAssertEqual(d.snapshot.fence, .clock)
        XCTAssertFalse(d.startExplicitly(generation: UUID()))
    }

    func testSleepLockRevocationAndWakeUseExistingEnvironmentIntentFences() async throws {
        for signal in [CaptureSourceEnvironment.Signal.sleep, .screensSleep, .resigned, .lockHint] {
            let i = intent(try root())
            let d = try driver()
            XCTAssertTrue(i.attachBestEffortDelivery(d))
            let token = try await arm(i)
            XCTAssertTrue(d.startExplicitly(generation: token))
            let environment = CaptureSourceEnvironment(consoleSession: { true })
            environment.onRevocation = {
                _ = i.beginShutdown(deliveryFence: environment.deliveryFence)
            }
            XCTAssertTrue(environment.acknowledgeCurrentUser())
            environment.receive(signal)
            XCTAssertFalse(environment.permitsCapture)
            XCTAssertEqual(d.snapshot.fence, environment.deliveryFence)
            XCTAssertFalse(
                d.offer(unitID: UUID(), generation: token, logs: .init(resourceLogs: [])))
            for wake in [CaptureSourceEnvironment.Signal.wake, .screensWake, .active, .unlockHint] {
                environment.receive(wake)
            }
            d.tick()
            XCTAssertFalse(environment.permitsCapture)
            XCTAssertFalse(i.isArmed)
            environment.revoke()
            XCTAssertEqual(d.snapshot.fence, .revoked)
            XCTAssertFalse(d.startExplicitly(generation: UUID()))
            environment.onRevocation = nil
        }
    }
}
