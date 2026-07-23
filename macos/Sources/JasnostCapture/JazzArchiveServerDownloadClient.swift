import Foundation
import JasnostCaptureCore

enum JazzArchiveServerDownloadHTTPError: Error, CustomStringConvertible {
    case invalidEndpoint
    case missingCredential
    case invalidGrantResponse
    case unsupportedDownloadInstructions
    case http(Int)
    case transport(String)

    var description: String {
        switch self {
        case .invalidEndpoint: return "Jazz Archive download endpoint is invalid."
        case .missingCredential: return "Jazz Archive download credential is unavailable."
        case .invalidGrantResponse: return "Jazz Archive download grant response is inconsistent."
        case .unsupportedDownloadInstructions:
            return "Jazz Archive direct-download instructions are unsupported."
        case let .http(status): return "Jazz Archive download returned HTTP \(status)."
        case let .transport(message): return "Jazz Archive download failed: \(message)"
        }
    }
}

/// HTTPS adapter for the READY-only server hand-off. The control-plane token is read lazily from
/// Keychain by the injected closure and is never sent to the provider's opaque signed URL.
final class JazzArchiveServerDownloadHTTPTransport:
    @unchecked Sendable, JazzArchiveServerDownloadTransport
{
    private let baseURL: URL
    private let credential: @Sendable () -> String?
    private let controlSession: URLSession
    private let bodySession: URLSession

    init(
        baseURL: URL,
        credential: @escaping @Sendable () -> String?,
        controlSession: URLSession? = nil,
        bodySession: URLSession? = nil
    ) throws {
        guard let normalized = JazzArchiveControlPlaneURL.normalize(baseURL.absoluteString),
            let normalizedURL = URL(string: normalized)
        else { throw JazzArchiveServerDownloadHTTPError.invalidEndpoint }
        self.baseURL = normalizedURL
        self.credential = credential
        self.controlSession = controlSession ?? Self.ephemeralSession(resourceTimeout: 30)
        self.bodySession = bodySession ?? Self.ephemeralSession(resourceTimeout: 3_600)
    }

    func authorize(
        _ request: JazzArchiveServerDownloadRequest
    ) async throws -> JazzArchiveServerDownloadGrant {
        guard !request.ingestId.isEmpty,
            request.ingestId.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression) != nil
        else {
            throw JazzArchiveServerDownloadHTTPError.invalidEndpoint
        }
        guard let token = credential(), !token.isEmpty else {
            throw JazzArchiveServerDownloadHTTPError.missingCredential
        }
        let url = baseURL
            .appendingPathComponent(request.ingestId)
            .appendingPathComponent("download-grants")
        let body: JazzArchiveJSONValue = .object([
            "companyId": .string(request.scope.companyId),
            "areaId": .string(request.scope.areaId),
            "deviceId": .string(request.scope.deviceId),
        ])
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JazzArchiveCanonicalJSON.encode(body)
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(token, forHTTPHeaderField: "X-StorageApi-Token")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await controlSession.data(for: urlRequest)
        } catch {
            throw JazzArchiveServerDownloadHTTPError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw JazzArchiveServerDownloadHTTPError.http(
                (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let grant = try JSONDecoder().decode(JazzArchiveServerDownloadGrant.self, from: data)
        guard http.value(forHTTPHeaderField: "Cache-Control")?
            .lowercased().contains("no-store") == true,
            http.value(forHTTPHeaderField: "X-Jazz-Archive-Id") == grant.archiveId,
            http.value(forHTTPHeaderField: "X-Jazz-Content-Digest") == grant.contentDigest,
            http.value(forHTTPHeaderField: "X-Jazz-Raw-Sha256") == grant.rawSha256,
            http.value(forHTTPHeaderField: "X-Jazz-Byte-Length") == String(grant.byteLength),
            http.value(forHTTPHeaderField: "ETag") == "\"sha256:\(grant.rawSha256)\""
        else { throw JazzArchiveServerDownloadHTTPError.invalidGrantResponse }
        return grant
    }

    func openBody(
        for grant: JazzArchiveServerDownloadGrant
    ) async throws -> any JazzArchiveServerDownloadBody {
        guard case let .string(method)? = grant.download["method"],
            method == "GET",
            case let .string(rawURL)? = grant.download["url"],
            let url = URL(string: rawURL),
            url.scheme?.lowercased() == "https",
            url.host != nil,
            url.user == nil,
            url.password == nil,
            url.fragment == nil
        else { throw JazzArchiveServerDownloadHTTPError.unsupportedDownloadInstructions }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // Deliberately no X-StorageApi-Token: the provider URL is already the bounded grant.
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await bodySession.bytes(for: request)
        } catch {
            throw JazzArchiveServerDownloadHTTPError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw JazzArchiveServerDownloadHTTPError.http(
                (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        if let contentEncoding = http.value(forHTTPHeaderField: "Content-Encoding"),
            contentEncoding.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() != "identity"
        {
            throw JazzArchiveServerDownloadHTTPError.invalidGrantResponse
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length"),
            Int64(length) != grant.byteLength
        {
            throw JazzArchiveServerDownloadHTTPError.invalidGrantResponse
        }
        return JazzArchiveURLSessionBody(bytes: bytes)
    }

    private static func ephemeralSession(resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}

private actor JazzArchiveURLSessionBody: JazzArchiveServerDownloadBody {
    private var iterator: URLSession.AsyncBytes.Iterator
    private let chunkSize = 64 * 1_024

    init(bytes: URLSession.AsyncBytes) {
        self.iterator = bytes.makeAsyncIterator()
    }

    func nextChunk() async throws -> Data? {
        var chunk = Data()
        chunk.reserveCapacity(chunkSize)
        var current = iterator
        while chunk.count < chunkSize, let byte = try await current.next() {
            chunk.append(byte)
        }
        iterator = current
        return chunk.isEmpty ? nil : chunk
    }
}
