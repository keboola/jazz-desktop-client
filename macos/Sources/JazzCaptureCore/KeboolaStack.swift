import Foundation

/// Pure validation and routing helpers for Keboola Storage API stack URLs.
///
/// A newly-issued enrollment bundle carries its exact stack so a dedicated/single-tenant project
/// (for example ``connection.<tenant>.keboola.cloud``) never depends on the desktop's finite list of
/// public stacks. The URL is non-secret, but it receives the device token in ``tokens/verify`` so
/// only canonical HTTPS Keboola connection hosts are accepted.
public enum KeboolaStack {
    /// Return a canonical Storage API base URL, or ``nil`` when ``raw`` is not a supported Keboola
    /// connection host. Paths, credentials, ports, queries, and fragments are rejected.
    public static func normalize(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            var components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            let rawHost = components.host
        else { return nil }

        let host = rawHost.lowercased()
        let isKeboolaHost =
            host.hasPrefix("connection.")
            && (host.hasSuffix(".keboola.com") || host.hasSuffix(".keboola.cloud"))
        guard
            isKeboolaHost,
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/"
        else { return nil }

        components.scheme = "https"
        components.host = host
        components.path = ""
        return components.string
    }

    /// Preferred stack first, then the built-in public stacks, normalized and de-duplicated.
    /// Invalid candidates are discarded rather than receiving a token-bearing verify request.
    public static func verificationCandidates(
        preferred: String?, known: [String]
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in ([preferred].compactMap { $0 } + known) {
            guard let normalized = normalize(raw), seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}
