import Foundation
import XCTest

@testable import JazzCaptureCore

final class BestEffortTransportDriverTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        func read() -> TimeInterval { lock.withLock { value } }
        func set(_ value: TimeInterval) { lock.withLock { self.value = value } }
    }
    enum Reply {
        case response(Int, [Data], [String: String] = [:])
        case disconnect, lostACK, hold
    }
    final class Server: @unchecked Sendable {
        let id = UUID().uuidString.lowercased()
        let lock = NSLock()
        var replies: [String: [Reply]]
        private var requests: [String: [Data]] = [:]
        init(_ replies: [String: [Reply]]) {
            self.replies = replies
            FaultProtocol.register(self)
        }
        func request(_ path: String, method: String = "POST") -> URLRequest {
            var request = URLRequest(url: URL(string: "https://\(id).invalid\(path)")!)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return request
        }
        var configuration: URLSessionConfiguration {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FaultProtocol.self]
            return config
        }
        func receive(_ path: String, data: Data) -> Reply {
            lock.withLock {
                let index = requests[path, default: []].count
                requests[path, default: []].append(data)
                let values = replies[path] ?? [.response(200, [Data("{}".utf8)])]
                return values[min(index, values.count - 1)]
            }
        }
        func bodies(_ path: String) -> [Data] { lock.withLock { requests[path] ?? [] } }
    }
    final class FaultProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var servers: [String: Server] = [:]
        static func register(_ server: Server) { lock.withLock { servers[server.id] = server } }
        static func reset() { lock.withLock { servers.removeAll() } }
        // Never fall through to real networking.
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let key = request.url!.host!.replacingOccurrences(of: ".invalid", with: "")
            guard let server = Self.lock.withLock({ Self.servers[key] }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1024)
                while data.count <= 128 * 1024 {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
            }
            switch server.receive(request.url!.path, data: data) {
            case .disconnect:
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case .hold: break
            case .lostACK:
                send(200, headers: [:])
                client?.urlProtocol(self, didLoad: Data("{".utf8))
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case .response(let status, let chunks, let headers):
                send(status, headers: headers)
                for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        private func send(_ status: Int, headers: [String: String]) {
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: headers)!,
                cacheStoragePolicy: .notAllowed)
        }
        override func stopLoading() {}
    }
    override func tearDown() {
        FaultProtocol.reset()
        super.tearDown()
    }
    let generation = UUID()
    let logs = Otlp.ExportLogsServiceRequest(resourceLogs: [])
    func driver(
        _ server: Server, clock: Clock = Clock(), queue: OperationQueue? = nil,
        automatic: Bool = false, deadline: TimeInterval = 60
    ) throws -> BestEffortTransportDriver {
        let limits = try BestEffortTransport.Limits(
            units: 4, bytes: 16384, partBytes: 4096,
            encodingParts: 4, inFlight: 2, inFlightBytes: 8192, age: 20, attemptTime: 5)
        let driver = try BestEffortTransportDriver(
            limits: limits, eventRequest: server.request("/events"),
            authorityDeadline: deadline, configuration: server.configuration, delegateQueue: queue,
            now: { clock.read() }, automaticallySchedule: automatic)
        XCTAssertTrue(driver.startExplicitly(generation: generation))
        return driver
    }
    func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line)
        async throws
    {
        let end = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > end {
                XCTFail("bounded wait expired", file: file, line: line)
                throw URLError(.timedOut)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    func testDisconnectLostMalformedPartialAndUnexpectedACKNeverReplay() async throws {
        for reply in [
            Reply.disconnect, .lostACK, .response(200, [Data("{".utf8)]),
            .response(200, [Data(#"{"partialSuccess":{"rejectedLogRecords":"1"}}"#.utf8)]),
            .response(499, []), .response(201, []),
        ] {
            let server = Server(["/events": [reply]])
            let d = try driver(server)
            defer { d.suspend(.stop) }
            XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs))
            try await wait { d.snapshot.units == 0 }
            XCTAssertEqual(d.drainReports().first?.event, .unknown)
            d.tick()
            XCTAssertEqual(server.bodies("/events").count, 1)
        }
    }
    func test429SchedulerHonorsRetryAfterAndReusesExactEncodedBody() async throws {
        let clock = Clock()
        let server = Server([
            "/events": [
                .response(429, [], ["Retry-After": "3"]), .response(200, [Data("{}".utf8)]),
            ]
        ])
        let d = try driver(server, clock: clock)
        defer { d.suspend(.stop) }
        XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs))
        try await wait { server.bodies("/events").count == 1 && d.snapshot.inFlight == 0 }
        clock.set(2.99)
        d.tick()
        XCTAssertEqual(server.bodies("/events").count, 1)
        clock.set(3)
        d.tick()
        try await wait { d.snapshot.units == 0 }
        let bodies = server.bodies("/events")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(
            try JSONDecoder().decode(Otlp.ExportLogsServiceRequest.self, from: bodies[0]), logs)
        XCTAssertEqual(d.drainReports().first?.event, .hopAccepted)
    }
    func testSingleAutomaticTimerSchedulesRetryWithoutCaptureOffers() async throws {
        let clock = Clock()
        let server = Server(["/events": [.response(503, []), .response(200, [Data("{}".utf8)])]])
        let d = try driver(server, clock: clock, automatic: true)
        defer { d.suspend(.stop) }
        XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs))
        try await wait { server.bodies("/events").count == 1 && d.snapshot.inFlight == 0 }
        clock.set(1)
        try await wait { d.snapshot.units == 0 }
        XCTAssertEqual(server.bodies("/events").count, 2)
    }
    func testCancellationAndDeadlineHoldHTTPLeaseUntilDelegateReturn() async throws {
        for fence in [BestEffortTransport.Fence.pause, .stop, .lock, .sleep, .revoked] {
            let clock = Clock()
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.isSuspended = true
            defer { queue.isSuspended = false }
            let server = Server(["/events": [.hold]])
            let d = try driver(server, clock: clock, queue: queue)
            XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs))
            try await wait { server.bodies("/events").count == 1 }
            clock.set(5)
            d.tick()
            d.suspend(fence)
            XCTAssertEqual(d.snapshot.inFlight, 1)
            XCTAssertEqual(d.adapterUsage.uploads, 1)
            XCTAssertGreaterThan(d.snapshot.reservedBytes, 0)
            XCTAssertFalse(d.startExplicitly(generation: UUID()))
            XCTAssertFalse(d.offer(unitID: UUID(), generation: generation, logs: logs))
            queue.isSuspended = false
            try await wait { d.snapshot.units == 0 }
            XCTAssertEqual(d.drainReports().first?.event, .unknown)
            XCTAssertEqual(server.bodies("/events").count, 1)
        }
    }
    func testBoundedACKBuffersRejectDeclaredAndChunkedOversize() async throws {
        let cap = BestEffortOTLPAcknowledgement.maximumBytes
        for reply in [
            Reply.response(200, [], ["Content-Length": "1000000"]),
            .response(200, [Data(repeating: 32, count: cap - 1), Data([32, 32])]),
        ] {
            let server = Server(["/events": [reply]])
            let d = try driver(server)
            defer { d.suspend(.stop) }
            XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs))
            XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs))
            try await wait { d.snapshot.units == 0 }
            XCTAssertTrue(d.drainReports().allSatisfy { $0.event == .unknown })
            XCTAssertLessThanOrEqual(d.adapterUsage.peakResponseBytes, cap * 2)
            XCTAssertEqual(d.adapterUsage.responseBytes, 0)
        }
    }
    func testIndependentMediaAndEventFailuresAndUncertainFileACK() async throws {
        for eventFails in [false, true] {
            let server = Server([
                "/events": [eventFails ? .disconnect : .response(200, [Data("{}".utf8)])],
                "/media": [eventFails ? .response(204, []) : .lostACK],
            ])
            let d = try driver(server)
            defer { d.suspend(.stop) }
            let media = BestEffortTransportDriver.Media(
                request: server.request("/media", method: "PUT"),
                maximumBytes: 4, expiresAt: 30
            ) { _, _ in Data([1, 2, 3, 4]) }
            XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs, media: media))
            try await wait { d.snapshot.units == 0 }
            let report = d.drainReports().first!
            XCTAssertEqual(report.event, eventFails ? .unknown : .hopAccepted)
            XCTAssertEqual(report.media, eventFails ? .hopAccepted : .unknown)
            XCTAssertTrue(report.coverageUnknown)
            XCTAssertEqual(server.bodies("/media"), [Data([1, 2, 3, 4])])
        }
    }
    func testNoncooperativeEncoderRetainsReservationAcrossFence() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = Server([:])
        let d = try driver(Server([:]))
        let media = BestEffortTransportDriver.Media(
            request: server.request("/media", method: "PUT"),
            maximumBytes: 4096, expiresAt: 30
        ) { _, _ in
            entered.signal()
            release.wait()
            return Data([1])
        }
        XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs, media: media))
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        d.suspend(.pause)
        // The independent event encoder may also still own a slot at the fence. Observe its
        // actual completion rather than assuming an OperationQueue execution order.
        try await wait { d.snapshot.encodingParts == 1 }
        XCTAssertEqual(d.snapshot.encodingParts, 1)
        XCTAssertEqual(d.adapterUsage.encoders, 1)
        XCTAssertGreaterThanOrEqual(d.snapshot.reservedBytes, 4096)
        XCTAssertFalse(d.startExplicitly(generation: UUID()))
        release.signal()
        try await wait { d.snapshot.units == 0 }
        XCTAssertEqual(server.bodies("/media").count, 0)
        XCTAssertTrue(d.startExplicitly(generation: UUID()))
        d.suspend(.stop)
    }
    func testSaturationBoundsMetadataEncodersHTTPAndReports() async throws {
        let server = Server(["/events": [.hold]])
        let d = try driver(server)
        defer { d.suspend(.stop) }
        // Establish actual held HTTP owners first; do not assume encoder/URLSession scheduling
        // happened during a fast producer loop (or let the bound test pass vacuously).
        for count in 1...2 {
            XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs))
            try await wait {
                server.bodies("/events").count >= count && d.adapterUsage.encoders == 0
            }
        }
        for _ in 0..<2000 {
            _ = d.offer(unitID: UUID(), generation: generation, logs: logs)
            let s = d.snapshot
            let a = d.adapterUsage
            XCTAssertLessThanOrEqual(s.units, 4)
            XCTAssertLessThanOrEqual(s.reservedBytes, 16384)
            XCTAssertLessThanOrEqual(a.encoders, 4)
            XCTAssertLessThanOrEqual(a.uploads, 2)
            XCTAssertLessThanOrEqual(a.reports, 4)
            XCTAssertLessThanOrEqual(a.responseBytes, 2 * 65536)
        }
        d.suspend(.stop)
        try await wait { d.snapshot.units == 0 }
        XCTAssertLessThanOrEqual(d.adapterUsage.reports, 4)
        XCTAssertGreaterThanOrEqual(server.bodies("/events").count, 2)
    }
    func testHTTPByteCeilingBlocksDispatchEvenWithUnusedTaskSlots() async throws {
        let server = Server(["/media": [.hold]])
        let limits = try BestEffortTransport.Limits(
            units: 4, bytes: 8192, partBytes: 4096,
            encodingParts: 4, inFlight: 3, inFlightBytes: 4096)
        let d = try BestEffortTransportDriver(
            limits: limits, eventRequest: server.request("/events"),
            authorityDeadline: 60, configuration: server.configuration, now: { 0 },
            automaticallySchedule: false)
        defer { d.suspend(.stop) }
        XCTAssertTrue(d.startExplicitly(generation: generation))
        let media = BestEffortTransportDriver.Media(
            request: server.request("/media", method: "PUT"),
            maximumBytes: 4096, expiresAt: 30
        ) { limit, _ in Data(repeating: 42, count: limit) }
        XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs, media: media))
        try await wait { server.bodies("/media").count == 1 && d.adapterUsage.encoders == 0 }
        let events = server.bodies("/events").count
        XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs))
        try await wait { d.adapterUsage.encoders == 0 }
        d.tick()
        XCTAssertEqual(d.snapshot.inFlightBytes, 4096)
        XCTAssertEqual(d.adapterUsage.uploads, 1)
        XCTAssertEqual(server.bodies("/events").count, events)
        d.suspend(.stop)
        try await wait { d.snapshot.units == 0 }
    }

    @MainActor
    func testHTTPRevocationNotifiesNativeOwnerOnceWithOriginalGeneration() async throws {
        let server = Server(["/events": [.response(401, [])]])
        let d = try driver(server)
        var notifications: [UUID] = []
        let notified = expectation(description: "revocation delivered")
        d.onRevocation {
            notifications.append($0)
            notified.fulfill()
        }
        XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs))
        await fulfillment(of: [notified], timeout: 3)
        try await wait { d.snapshot.units == 0 }
        d.tick()
        await Task.yield()
        XCTAssertEqual(notifications, [generation])
        XCTAssertEqual(d.snapshot.fence, .revoked)
        XCTAssertFalse(d.offer(unitID: UUID(), generation: generation, logs: logs))
    }

    func testExpiredAuthorityAndGrantDoNotStartMoreIO() async throws {
        let clock = Clock()
        let server = Server(["/events": [.hold]])
        let d = try driver(server, clock: clock, deadline: 3)
        XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs))
        try await wait { server.bodies("/events").count == 1 }
        clock.set(3)
        d.tick()
        try await wait { d.snapshot.units == 0 }
        XCTAssertEqual(d.snapshot.fence, .revoked)
        XCTAssertFalse(d.startExplicitly(generation: UUID()))
        XCTAssertFalse(d.offer(unitID: UUID(), generation: generation, logs: logs))
        let other = try driver(server, clock: clock)
        defer { other.suspend(.stop) }
        let media = BestEffortTransportDriver.Media(
            request: server.request("/media", method: "PUT"),
            maximumBytes: 4, expiresAt: 2
        ) { _, _ in
            XCTFail("expired grant encoder ran")
            return Data([1])
        }
        XCTAssertFalse(
            other.offer(unitID: UUID(), generation: generation, logs: logs, media: media))
        XCTAssertEqual(server.bodies("/media").count, 0)
    }
    func testMediaGrantExpiringDuringEncodingNeverDispatchesItsBytes() async throws {
        let server = Server([:])
        let clock = Clock()
        let d = try driver(server, clock: clock)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            d.suspend(.stop)
        }
        let media = BestEffortTransportDriver.Media(
            request: server.request("/media", method: "PUT"),
            maximumBytes: 4, expiresAt: 3
        ) { _, _ in
            entered.signal()
            release.wait()
            return Data([1])
        }
        XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs, media: media))
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        try await wait { server.bodies("/events").count == 1 && d.snapshot.inFlight == 0 }
        clock.set(3)
        release.signal()
        try await wait { d.snapshot.units == 0 }
        let report = try XCTUnwrap(d.drainReports().first)
        XCTAssertEqual(report.event, .hopAccepted)
        XCTAssertEqual(report.media, .unavailable)
        XCTAssertEqual(server.bodies("/media").count, 0)
    }

    func testInvalidRetryAfterAndUntrustedRequestFormsFailClosed() async throws {
        for value in [
            "-1", "bogus", "Wed, 21 Oct 2099 07:28:00 GMT", String(repeating: "9", count: 400),
        ] {
            let server = Server(["/events": [.response(429, [], ["Retry-After": value])]])
            let d = try driver(server)
            defer { d.suspend(.stop) }
            XCTAssertTrue(d.offer(unitID: UUID(), generation: generation, logs: logs))
            try await wait { d.snapshot.units == 0 }
            XCTAssertEqual(d.drainReports().first?.event, .unknown)
            XCTAssertEqual(server.bodies("/events").count, 1)
        }
        let limits = try BestEffortTransport.Limits()
        for url in [
            "http://synthetic.invalid/logs", "https://user:synthetic@synthetic.invalid/logs",
            "https://synthetic.invalid/logs#fragment",
        ] {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "POST"
            XCTAssertThrowsError(
                try BestEffortTransportDriver(
                    limits: limits, eventRequest: request, authorityDeadline: 30, now: { 0 }))
        }
        let server = Server([:])
        for header in ["Host", "Content-Length", "Transfer-Encoding", "Cookie"] {
            var request = server.request("/events")
            request.setValue("synthetic", forHTTPHeaderField: header)
            XCTAssertThrowsError(
                try BestEffortTransportDriver(
                    limits: limits, eventRequest: request, authorityDeadline: 30, now: { 0 }))
        }
    }

    func testOTLPPreflightBoundsEscapesAndRejectsLargeAndNonfiniteModels() throws {
        func model(_ value: Otlp.AnyValue) -> Otlp.ExportLogsServiceRequest {
            .init(resourceLogs: [
                .init(
                    resource: .init(attributes: []),
                    scopeLogs: [
                        .init(
                            scope: .init(name: "synthetic"),
                            logRecords: [
                                .init(
                                    timeUnixNano: "1", observedTimeUnixNano: "1",
                                    severityText: "INFO", severityNumber: 9, traceId: "t",
                                    spanId: "s", body: value, attributes: [])
                            ])
                    ])
            ])
        }
        for value in [Otlp.AnyValue.string("\u{0}\n\"\\/🦄"), .int(.min), .bool(true), .double(1.5)]
        {
            let m = model(value)
            let bound = try XCTUnwrap(BestEffortLogEncoding.maximumBytes(m, limit: 4096))
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(m).count, bound)
            XCTAssertEqual(BestEffortLogEncoding.compact(m), m)
        }
        XCTAssertNil(BestEffortLogEncoding.maximumBytes(model(.double(.nan)), limit: 4096))
        XCTAssertNil(
            BestEffortLogEncoding.maximumBytes(
                model(.string(String(repeating: "x", count: 10000))), limit: 4096))
    }
}
