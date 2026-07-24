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
    private static let maximumAuthorizationResponseBytes = 1 * 1_024 * 1_024

    private let baseURL: URL
    let routeBinding: JazzArchiveUploadRouteBinding
    private let credential: @Sendable () async -> String?
    private let controlSession: JazzCredentialSafeHTTPSession
    private let bodySession: JazzCredentialSafeHTTPSession

    init(
        routeBinding: JazzArchiveUploadRouteBinding,
        credential: @escaping @Sendable () async -> String?,
        controlSessionConfiguration: URLSessionConfiguration? = nil,
        bodySessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        guard routeBinding.hasSignedAuthority,
            let normalized = JazzArchiveControlPlaneURL.normalize(
                routeBinding.ingestEndpoint),
            let normalizedURL = URL(string: normalized)
        else { throw JazzArchiveServerDownloadHTTPError.invalidEndpoint }
        self.baseURL = normalizedURL
        self.routeBinding = routeBinding
        self.credential = credential
        self.controlSession = Self.ephemeralSession(
            resourceTimeout: 30,
            configuration: controlSessionConfiguration)
        self.bodySession = Self.ephemeralSession(
            resourceTimeout: 3_600,
            configuration: bodySessionConfiguration)
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
        guard let token = await credential(), !token.isEmpty else {
            throw JazzArchiveServerDownloadHTTPError.missingCredential
        }
        let url = baseURL
            .appendingPathComponent(request.ingestId)
            .appendingPathComponent("download-grants")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try request.canonicalAuthorizationBody()
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(token, forHTTPHeaderField: "X-StorageApi-Token")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await controlSession.boundedData(
                for: urlRequest,
                maximumResponseBytes: Self.maximumAuthorizationResponseBytes)
        } catch JazzCredentialSafeHTTPSessionError.responseTooLarge {
            throw JazzArchiveServerDownloadHTTPError.invalidGrantResponse
        } catch {
            throw JazzArchiveServerDownloadHTTPError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw JazzArchiveServerDownloadHTTPError.http(
                0)
        }
        guard http.statusCode == 200 else {
            if JazzArchiveServerDownloadCompatibility.isLegacyOperationIdRejection(
                statusCode: http.statusCode,
                responseBody: data,
                expectedOperationId: request.downloadOperationId)
            {
                throw JazzArchiveServerDownloadError.serverUpgradeRequired
            }
            throw JazzArchiveServerDownloadHTTPError.http(http.statusCode)
        }
        let grant = try JSONDecoder().decode(JazzArchiveServerDownloadGrant.self, from: data)
        guard grant.downloadOperationId == request.downloadOperationId,
            http.value(forHTTPHeaderField: "Cache-Control")?
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
        let instructions: JazzArchiveServerDownloadInstructions
        do {
            instructions = try JazzArchiveServerDownloadInstructions(
                download: grant.download)
        } catch {
            throw JazzArchiveServerDownloadHTTPError.unsupportedDownloadInstructions
        }
        var request = URLRequest(url: instructions.url)
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
            http.statusCode == 200
        else {
            throw JazzArchiveServerDownloadHTTPError.http(
                (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        if http.value(forHTTPHeaderField: "Content-Range") != nil {
            throw JazzArchiveServerDownloadHTTPError.invalidGrantResponse
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

    private static func ephemeralSession(
        resourceTimeout: TimeInterval,
        configuration suppliedConfiguration: URLSessionConfiguration?
    ) -> JazzCredentialSafeHTTPSession {
        let configuration = suppliedConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return JazzCredentialSafeHTTPSession(configuration: configuration)
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
