import Foundation

/// URLSession follows HTTP redirects by default. That is unsafe for requests whose headers or URL
/// carry a credential: even when Foundation strips one familiar header, a provider-specific
/// header, signed URL, or path-embedded stream secret can still cross the configured authority.
///
/// All credential-bearing desktop HTTP adapters use this wrapper. The redirect delegate is owned
/// internally, so an injected test configuration cannot accidentally replace the fail-closed
/// policy.
public final class JazzCredentialSafeHTTPSession: @unchecked Sendable {
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate,
        @unchecked Sendable
    {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let session: URLSession

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
        self.session = URLSession(
            configuration: configuration,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func data(from url: URL) async throws -> (Data, URLResponse) {
        try await session.data(from: url)
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
}
