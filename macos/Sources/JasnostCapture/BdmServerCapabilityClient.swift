import Foundation

enum BdmServerCapabilityError: Error, Equatable {
    case invalidEndpoint
    case unavailable
    case unexpectedStatus(Int)
    case responseTooLarge
    case invalidResponse
}

struct BdmServerCapabilities: Decodable, Equatable, Sendable {
    let capabilitiesVersion: Int
    let agentConfigured: Bool
    let agentEnabled: Bool
    let backend: String?
    let visionConfigured: Bool
    let visionEnabled: Bool
    let transcriptionEnabled: Bool
    let transcriptionBackend: String?

    var adaptiveWorkshopEnabled: Bool {
        capabilitiesVersion == 1
            && agentConfigured
            && agentEnabled
            && (backend == "anthropic" || backend == "kbagent")
    }

    func validate() throws {
        guard capabilitiesVersion == 1,
            !agentEnabled || agentConfigured,
            !agentEnabled || backend == "anthropic" || backend == "kbagent",
            !visionEnabled || visionConfigured,
            !visionEnabled || backend != nil,
            !transcriptionEnabled || transcriptionBackend == "gemini",
            transcriptionEnabled == (transcriptionBackend != nil)
        else {
            throw BdmServerCapabilityError.invalidResponse
        }
    }
}

/// Credential-free, bounded capability handshake for the hosted BDM workshop.
///
/// A configured review URL is not proof that an LLM exists. The desktop calls this endpoint before
/// entering adaptive mode and falls back to its local script on every failure.
final class BdmServerCapabilityHTTPClient: @unchecked Sendable {
    private static let maximumResponseBytes = 256 * 1_024

    private let endpoint: URL
    private let session: URLSession

    init(
        reviewAppURL: String,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        guard let endpoint = Self.endpoint(reviewAppURL: reviewAppURL) else {
            throw BdmServerCapabilityError.invalidEndpoint
        }
        self.endpoint = endpoint
        let configuration = sessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func capabilities() async throws -> BdmServerCapabilities {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BdmServerCapabilityError.unavailable
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw BdmServerCapabilityError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse,
            Self.sameOrigin(http.url, endpoint)
        else {
            throw BdmServerCapabilityError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw BdmServerCapabilityError.unexpectedStatus(http.statusCode)
        }
        let value: BdmServerCapabilities
        do {
            value = try JSONDecoder().decode(BdmServerCapabilities.self, from: data)
        } catch {
            throw BdmServerCapabilityError.invalidResponse
        }
        try value.validate()
        return value
    }

    private static func endpoint(reviewAppURL: String) -> URL? {
        let raw = reviewAppURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            scheme == "https" || (scheme == "http" && isLoopback(host))
        else {
            return nil
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath =
            "/" + ([basePath, "api", "interview-script"].filter { !$0.isEmpty }.joined(separator: "/"))
        return components.url
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func sameOrigin(_ left: URL?, _ right: URL) -> Bool {
        guard let left,
            let leftComponents = URLComponents(url: left, resolvingAgainstBaseURL: false),
            let rightComponents = URLComponents(url: right, resolvingAgainstBaseURL: false)
        else {
            return false
        }
        return leftComponents.scheme?.lowercased() == rightComponents.scheme?.lowercased()
            && leftComponents.host?.lowercased() == rightComponents.host?.lowercased()
            && leftComponents.port == rightComponents.port
    }
}
