import Foundation

public enum JazzCredentialSafeHTTPSessionError: Error, Equatable {
    case invalidMaximumResponseBytes
    case responseTooLarge
    case missingResponse
}

/// URLSession follows HTTP redirects by default. That is unsafe for requests whose headers or URL
/// carry a credential: even when Foundation strips one familiar header, a provider-specific
/// header, signed URL, or path-embedded stream secret can still cross the configured authority.
///
/// All credential-bearing desktop HTTP adapters use this wrapper. The redirect delegate is owned
/// internally, so an injected test configuration cannot accidentally replace the fail-closed
/// policy.
public final class JazzCredentialSafeHTTPSession: @unchecked Sendable {
    private final class NoRedirectDelegate: NSObject, URLSessionDataDelegate,
        @unchecked Sendable
    {
        private struct PendingResponse {
            var data = Data()
            let maximumBytes: Int
            var continuation: CheckedContinuation<(Data, URLResponse), Error>? = nil
            var isCancelled = false
        }

        private let lock = NSLock()
        private var pending: [Int: PendingResponse] = [:]

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func reserve(
            _ task: URLSessionTask,
            maximumBytes: Int
        ) {
            lock.lock()
            precondition(pending[task.taskIdentifier] == nil)
            pending[task.taskIdentifier] = PendingResponse(
                maximumBytes: maximumBytes)
            lock.unlock()
        }

        func register(
            _ task: URLSessionTask,
            continuation: CheckedContinuation<(Data, URLResponse), Error>
        ) {
            let identifier = task.taskIdentifier
            var shouldStart = false
            var wasCancelled = false
            lock.lock()
            if var value = pending[identifier] {
                if value.isCancelled {
                    pending.removeValue(forKey: identifier)
                    wasCancelled = true
                } else {
                    value.continuation = continuation
                    pending[identifier] = value
                    shouldStart = true
                }
            } else {
                // A reserved suspended task cannot complete before registration. Missing state is
                // therefore fail-closed rather than permission to start an unbounded task.
                wasCancelled = true
            }
            lock.unlock()
            if wasCancelled {
                task.cancel()
                continuation.resume(throwing: CancellationError())
            } else if shouldStart {
                task.resume()
            }
        }

        func cancel(_ task: URLSessionTask) {
            let identifier = task.taskIdentifier
            var continuation: CheckedContinuation<(Data, URLResponse), Error>?
            lock.lock()
            if var value = pending[identifier] {
                value.isCancelled = true
                if value.continuation != nil {
                    continuation = value.continuation
                    pending.removeValue(forKey: identifier)
                } else {
                    // Cancellation may run before the operation closure registers its
                    // continuation. Keep this reservation as a one-shot cancellation marker.
                    pending[identifier] = value
                }
            }
            lock.unlock()
            task.cancel()
            continuation?.resume(throwing: CancellationError())
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            let identifier = dataTask.taskIdentifier
            lock.lock()
            let maximumBytes = pending[identifier]?.maximumBytes
            lock.unlock()
            guard let maximumBytes else {
                completionHandler(.allow)
                return
            }
            if response.expectedContentLength > Int64(maximumBytes) {
                fail(
                    identifier: identifier,
                    error: JazzCredentialSafeHTTPSessionError.responseTooLarge)
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            let identifier = dataTask.taskIdentifier
            var failedContinuation: CheckedContinuation<(Data, URLResponse), Error>?
            lock.lock()
            if var value = pending[identifier] {
                let remaining = value.maximumBytes - value.data.count
                if data.count > remaining {
                    failedContinuation = value.continuation
                    pending.removeValue(forKey: identifier)
                } else {
                    value.data.append(data)
                    pending[identifier] = value
                }
            }
            lock.unlock()
            if let failedContinuation {
                dataTask.cancel()
                failedContinuation.resume(
                    throwing: JazzCredentialSafeHTTPSessionError.responseTooLarge)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            lock.lock()
            let identifier = task.taskIdentifier
            let value: PendingResponse?
            if pending[identifier]?.continuation == nil {
                // A cancellation that raced before registration can still trigger this delegate
                // callback. Registration owns resuming that continuation with CancellationError.
                value = nil
            } else {
                value = pending.removeValue(forKey: identifier)
            }
            lock.unlock()
            guard let value, let continuation = value.continuation else { return }
            if let error {
                continuation.resume(throwing: error)
            } else if let response = task.response {
                continuation.resume(returning: (value.data, response))
            } else {
                continuation.resume(
                    throwing: JazzCredentialSafeHTTPSessionError.missingResponse)
            }
        }

        private func fail(identifier: Int, error: Error) {
            lock.lock()
            let value = pending.removeValue(forKey: identifier)
            lock.unlock()
            value?.continuation?.resume(throwing: error)
        }
    }

    private let session: URLSession
    private let delegate: NoRedirectDelegate

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        // Never let ambient process state participate in a credential-bearing request. In
        // particular, an injected `.default` configuration must not regain shared cookies,
        // authentication challenge credentials, response cache, or implicit cookie acceptance.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let delegate = NoRedirectDelegate()
        self.delegate = delegate
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func data(from url: URL) async throws -> (Data, URLResponse) {
        try await session.data(from: url)
    }

    /// Permanently cancels every in-flight task and prevents this session from issuing more work.
    /// Callers use this when an explicit consent or signed route authority is withdrawn.
    public func invalidateAndCancel() {
        session.invalidateAndCancel()
    }

    public func upload(
        for request: URLRequest,
        from bodyData: Data
    ) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, from: bodyData)
    }

    public func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, fromFile: fileURL)
    }

    public func bytes(
        for request: URLRequest
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await session.bytes(for: request)
    }

    /// Buffers only up to the caller-declared response limit. Both a declared Content-Length and
    /// chunked/unknown-length bodies are rejected before more bytes are retained.
    public func boundedData(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        guard maximumResponseBytes >= 0 else {
            throw JazzCredentialSafeHTTPSessionError.invalidMaximumResponseBytes
        }
        let task = session.dataTask(with: request)
        delegate.reserve(task, maximumBytes: maximumResponseBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.register(task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel(task)
        }
    }

    /// File-backed upload whose response is bounded before buffering, including chunked provider
    /// responses. The request body remains streamed by URLSession from the immutable queue file.
    public func boundedUpload(
        for request: URLRequest,
        fromFile fileURL: URL,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        guard maximumResponseBytes >= 0 else {
            throw JazzCredentialSafeHTTPSessionError.invalidMaximumResponseBytes
        }
        let task = session.uploadTask(with: request, fromFile: fileURL)
        delegate.reserve(task, maximumBytes: maximumResponseBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.register(task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel(task)
        }
    }
}
