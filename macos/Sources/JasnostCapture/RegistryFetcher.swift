import Foundation
import JasnostCaptureCore

/// Fetches an Area's declared process inventory for **Guided capture** (ADR 0002): the Area
/// registry is one JSON document per Area, persisted by the Data App as a Keboola Storage File
/// tagged `jasnost-area-registry` + `area:<areaId>` (see `contract/schema/area-registry.schema.json`).
/// The agent lists by those tags with its Keychain token (same ``KeboolaClient`` plumbing as the
/// narration dedup), downloads the newest document over its signed read URL, and decodes it via
/// the tolerant ``AreaRegistry/parse(data:)``.
///
/// Failure policy: EVERY failure path (offline, no registry yet, bad token, malformed document)
/// returns `[]`, which downstream reads as **Explore mode** (free-text labels — exactly today's
/// behavior). A registry fetch must never block, delay, or crash capture: the caller fires it
/// asynchronously at session start and caches the result for the session
/// (``CaptureController/processInventory``).
enum RegistryFetcher {
    /// Storage-File tag identifying Area-registry documents (mirrors the processor's persist path).
    static let registryTag = "jasnost-area-registry"

    /// The registry document is small JSON — tight budgets, like the client's other JSON calls.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// Fetch and decode the newest registry document for ``areaId``, returning its declared
    /// process choices in declaration order — or `[]` on any failure (silent Explore fallback).
    static func fetchInventory(areaId: String, stackURL: String) async -> [ProcessChoice] {
        let client = KeboolaClient(stackURL: stackURL)
        // listFiles AND-filters client-side (the Storage API ORs multiple tags[] — see
        // KeboolaAPI.filesMatchingAllTags) and already returns [] on any transport failure.
        let files = await client.listFiles(tags: [registryTag, "area:\(areaId)"])
        // Newest wins: a save replaces-not-appends, but a superseded document can linger until
        // reaped — order by created (ISO-8601 sorts lexicographically), file id breaks ties.
        guard
            let newest = files.max(by: { ($0.created ?? "", $0.id) < ($1.created ?? "", $1.id) }),
            let signedURL = newest.url,
            let data = await download(signedURL),
            let registry = AreaRegistry.parse(data: data)
        else { return [] }
        return registry.processChoices
    }

    /// GET a small blob from a signed GCS read URL (self-contained — no token header, like the
    /// narration dedup's HEAD probe). nil on any transport/HTTP failure.
    private static func download(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        guard
            let (data, response) = try? await session.data(from: url),
            let code = (response as? HTTPURLResponse)?.statusCode,
            (200..<300).contains(code)
        else { return nil }
        return data
    }
}
