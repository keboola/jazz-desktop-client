import Foundation
import Network
import XCTest

@testable import JasnostCaptureCore

final class CredentialSafeHTTPSessionTests: XCTestCase {
    private final class RedirectHTTPServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "jazz.redirect-test-server")
        private let lock = NSLock()
        private var requests: [String] = []
        private var readyHandler: (() -> Void)?
        private var startError: Error?

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
        }

        deinit { listener.cancel() }

        func start(ready: @escaping () -> Void) {
            readyHandler = ready
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    readyHandler?()
                    readyHandler = nil
                case let .failed(error):
                    startError = error
                    readyHandler?()
                    readyHandler = nil
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        func sourceURL(path: String) throws -> URL {
            if let startError { throw startError }
            guard let port = listener.port,
                let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")
            else { throw URLError(.cannotConnectToHost) }
            return url
        }

        func requestCount(path: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return requests.filter { requestPath($0) == path }.count
        }

        func request(path: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return requests.first { requestPath($0) == path }
        }

        private func handle(_ connection: NWConnection) {
            connection.start(queue: queue)
            receive(on: connection, accumulated: Data())
        }

        private func receive(on connection: NWConnection, accumulated: Data) {
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1_024
            ) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                var bytes = accumulated
                if let data { bytes.append(data) }
                if bytes.range(of: Data("\r\n\r\n".utf8)) == nil,
                    !isComplete,
                    error == nil
                {
                    receive(on: connection, accumulated: bytes)
                    return
                }
                guard let request = String(data: bytes, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                lock.lock()
                requests.append(request)
                lock.unlock()

                let path = requestPath(request)
                let response: String
                if path == "/large-length" || path == "/upload-large" {
                    let body = String(repeating: "x", count: 8_192)
                    response =
                        "HTTP/1.1 200 OK\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n\(body)"
                } else if path == "/large-chunked" {
                    let first = String(repeating: "a", count: 48)
                    let second = String(repeating: "b", count: 48)
                    response =
                        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n30\r\n\(first)\r\n30\r\n\(second)\r\n0\r\n\r\n"
                } else if path == "/redirect-target" || path == "/bounded" {
                    response =
                        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                } else if path == "/delayed-data" || path == "/delayed-upload" {
                    response =
                        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                } else {
                    let port = listener.port?.rawValue ?? 0
                    response = """
                        HTTP/1.1 307 Temporary Redirect\r
                        Location: http://127.0.0.1:\(port)/redirect-target\r
                        Content-Length: 0\r
                        Connection: close\r
                        \r

                        """
                }
                let send = {
                    connection.send(
                        content: Data(response.utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
                }
                if path == "/delayed-data" || path == "/delayed-upload" {
                    queue.asyncAfter(deadline: .now() + 1, execute: send)
                } else {
                    send()
                }
            }
        }

        private func requestPath(_ request: String) -> String? {
            request.split(separator: "\n", maxSplits: 1)
                .first?
                .split(separator: " ")
                .dropFirst()
                .first
                .map(String.init)
        }
    }

    func testInjectedConfigurationCannotRestoreAmbientCredentialState() {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        configuration.urlCredentialStorage = .shared
        configuration.urlCache = .shared

        _ = JazzCredentialSafeHTTPSession(configuration: configuration)

        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testStorageTokenRequestNeverReachesRedirectTarget() async throws {
        let (server, sourceURL) = try await server(path: "/storage-source")
        var request = URLRequest(url: sourceURL)
        request.setValue(
            "8625-123456-scoped-device-token-value",
            forHTTPHeaderField: "X-StorageApi-Token")

        await exerciseRedirect(server: server, request: request) { session, request in
            _ = try await session.data(for: request)
        }
        XCTAssertTrue(
            try XCTUnwrap(server.request(path: "/storage-source"))
                .contains("X-StorageApi-Token: 8625-123456-scoped-device-token-value"))
    }

    func testArchiveBearerUploadNeverReachesRedirectTarget() async throws {
        let (server, sourceURL) = try await server(path: "/archive-source")
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "PUT"
        request.setValue(
            "Bearer archive-upload-grant",
            forHTTPHeaderField: "Authorization")

        await exerciseRedirect(server: server, request: request) { session, request in
            _ = try await session.upload(for: request, from: Data("archive".utf8))
        }
        XCTAssertTrue(
            try XCTUnwrap(server.request(path: "/archive-source"))
                .contains("Authorization: Bearer archive-upload-grant"))
    }

    func testPathEmbeddedStreamSecretNeverReachesRedirectTarget() async throws {
        let path = "/source/stream-secret-value/v1/logs"
        let (server, sourceURL) = try await server(path: path)
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "POST"

        await exerciseRedirect(server: server, request: request) { session, request in
            let (bytes, _) = try await session.bytes(for: request)
            var iterator = bytes.makeAsyncIterator()
            _ = try await iterator.next()
        }
        XCTAssertEqual(server.requestCount(path: path), 1)
    }

    func testBoundedDataRejectsDeclaredAndChunkedBodiesBeforeBufferingPastLimit()
        async throws
    {
        for path in ["/large-length", "/large-chunked"] {
            let (server, sourceURL) = try await server(path: path)
            let session = JazzCredentialSafeHTTPSession(
                configuration: .ephemeral)
            do {
                _ = try await session.boundedData(
                    for: URLRequest(url: sourceURL),
                    maximumResponseBytes: 64)
                XCTFail("\(path) exceeded its response bound")
            } catch {
                XCTAssertEqual(
                    error as? JazzCredentialSafeHTTPSessionError,
                    .responseTooLarge,
                    path)
            }
            XCTAssertEqual(server.requestCount(path: path), 1)
        }
    }

    func testBoundedDataReturnsSmallExactResponse() async throws {
        let (server, sourceURL) = try await server(path: "/bounded")
        let (data, response) = try await JazzCredentialSafeHTTPSession(
            configuration: .ephemeral
        ).boundedData(
            for: URLRequest(url: sourceURL),
            maximumResponseBytes: 2)
        XCTAssertEqual(data, Data("ok".utf8))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(server.requestCount(path: "/bounded"), 1)
    }

    func testBoundedFileUploadRejectsOversizedProviderResponse() async throws {
        let (server, sourceURL) = try await server(path: "/upload-large")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-bounded-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("archive".utf8).write(to: file)
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "PUT"
        do {
            _ = try await JazzCredentialSafeHTTPSession(
                configuration: .ephemeral
            ).boundedUpload(
                for: request,
                fromFile: file,
                maximumResponseBytes: 64)
            XCTFail("provider response exceeded its upload-response bound")
        } catch {
            XCTAssertEqual(
                error as? JazzCredentialSafeHTTPSessionError,
                .responseTooLarge)
        }
        XCTAssertEqual(server.requestCount(path: "/upload-large"), 1)
    }

    func testBoundedDataCancellationCancelsPendingTaskExactlyOnce() async throws {
        let (server, sourceURL) = try await server(path: "/delayed-data")
        let session = JazzCredentialSafeHTTPSession(configuration: .ephemeral)
        let operation = Task {
            _ = try await session.boundedData(
                for: URLRequest(url: sourceURL),
                maximumResponseBytes: 64)
        }
        try await waitForRequest(server: server, path: "/delayed-data")
        operation.cancel()
        do {
            try await operation.value
            XCTFail("cancelled bounded data request completed")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(server.requestCount(path: "/delayed-data"), 1)
    }

    func testBoundedFileUploadCancellationCancelsPendingTaskExactlyOnce() async throws {
        let (server, sourceURL) = try await server(path: "/delayed-upload")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-cancelled-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("archive".utf8).write(to: file)
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "PUT"
        let session = JazzCredentialSafeHTTPSession(configuration: .ephemeral)
        let operation = Task {
            _ = try await session.boundedUpload(
                for: request,
                fromFile: file,
                maximumResponseBytes: 64)
        }
        try await waitForRequest(server: server, path: "/delayed-upload")
        operation.cancel()
        do {
            try await operation.value
            XCTFail("cancelled bounded upload completed")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(server.requestCount(path: "/delayed-upload"), 1)
    }

    private func server(path: String) async throws -> (RedirectHTTPServer, URL) {
        let server = try RedirectHTTPServer()
        let ready = expectation(description: "loopback redirect server ready")
        server.start { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 3)
        return (server, try server.sourceURL(path: path))
    }

    private func exerciseRedirect(
        server: RedirectHTTPServer,
        request: URLRequest,
        operation: (
            JazzCredentialSafeHTTPSession,
            URLRequest
        ) async throws -> Void
    ) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let session = JazzCredentialSafeHTTPSession(configuration: configuration)

        do {
            try await operation(session, request)
        } catch {
            // Refusing a redirect may surface either the original 3xx or cancellation depending
            // on the URLSession async API. No follow-up request is the security invariant.
        }

        XCTAssertEqual(server.requestCount(path: "/redirect-target"), 0)
    }

    private func waitForRequest(
        server: RedirectHTTPServer,
        path: String
    ) async throws {
        for _ in 0..<200 {
            if server.requestCount(path: path) == 1 { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("loopback server did not receive \(path)")
    }
}
