import Foundation

/// Pure logic for the in-app update check against GitHub Releases
/// (`GET https://api.github.com/repos/keboola/jazz-desktop-client/releases/latest`): decode the
/// response, compare versions, and throttle the check to once a day. No networking, no
/// UserDefaults — kept in Core so it is fully unit-tested in CI (Golden Rule 4). The
/// system layer (``UpdateChecker`` in the executable) fetches, persists the last-check
/// stamp, and shows the menu item.
///
/// Failure policy mirrors the rest of the agent: anything unexpected (malformed JSON,
/// unparsable versions) means "no update" — the check must never block, nag, or crash.
public enum UpdateCheck {
    /// The latest published release, as much of it as the menu needs.
    public struct ReleaseInfo: Equatable, Sendable {
        /// Release tag as published, e.g. `"v0.22.0"` — shown verbatim in the menu item.
        public let tagName: String
        /// The release page the menu item opens in the browser.
        public let htmlURL: URL
        /// Publish time (informational; nil when absent or unparsable).
        public let publishedAt: Date?

        public init(tagName: String, htmlURL: URL, publishedAt: Date?) {
            self.tagName = tagName
            self.htmlURL = htmlURL
            self.publishedAt = publishedAt
        }
    }

    /// Minimum spacing between two checks: at most once a day, persisted across launches.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Decode the GitHub Releases "latest" API response. Lenient like the other API models
    /// (``KeboolaAPI``): only the fields we branch on are required, and any shape problem
    /// (missing tag, non-https URL, malformed JSON) returns nil — never a throw the caller
    /// must route somewhere.
    public static func parse(latestReleaseJSON data: Data) -> ReleaseInfo? {
        struct Payload: Decodable {
            let tagName: String
            let htmlUrl: String
            let publishedAt: String?

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlUrl = "html_url"
                case publishedAt = "published_at"
            }
        }
        guard
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            !payload.tagName.isEmpty,
            let url = URL(string: payload.htmlUrl),
            url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false
        else { return nil }
        let publishedAt = payload.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        return ReleaseInfo(tagName: payload.tagName, htmlURL: url, publishedAt: publishedAt)
    }

    /// Semver-ish "is `latest` strictly newer than `current`?", tolerant of a leading
    /// `v`/`V` and of unequal component counts (`1.2` == `1.2.0`). Prerelease/build
    /// suffixes (`-rc.1`, `+5`) are stripped before comparing, and equal numeric cores are
    /// never "newer" — so a prerelease of the running version can't nag. Either side
    /// unparsable (e.g. the `"dev"` placeholder of an unbundled build) → false: when in
    /// doubt, stay silent.
    public static func isNewer(current: String, latest: String) -> Bool {
        guard
            let currentCore = numericCore(current),
            let latestCore = numericCore(latest)
        else { return false }
        for i in 0..<max(currentCore.count, latestCore.count) {
            let c = i < currentCore.count ? currentCore[i] : 0
            let l = i < latestCore.count ? latestCore[i] : 0
            if l != c { return l > c }
        }
        return false
    }

    /// Whether a check is due: never checked, or the last one is at least ``interval``
    /// ago. A last-check stamp in the future (clock skew) reads as "recently checked" —
    /// the conservative answer for a nag-avoidance throttle.
    public static func shouldCheck(
        now: Date, lastCheck: Date?, interval: TimeInterval = checkInterval
    ) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// `"v1.2.3-rc.1"` → `[1, 2, 3]`; nil when any dot component is not a plain integer.
    static func numericCore(_ version: String) -> [Int]? {
        var s = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Drop the prerelease ("-rc.1") / build-metadata ("+5") tail, semver-style.
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        guard !s.isEmpty else { return nil }
        var core: [Int] = []
        for piece in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(piece), n >= 0 else { return nil }
            core.append(n)
        }
        return core
    }
}
