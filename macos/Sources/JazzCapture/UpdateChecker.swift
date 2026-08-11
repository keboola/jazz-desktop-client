import AppKit
import Foundation
import JazzCaptureCore

/// System-layer half of the update check: fetch the latest GitHub release (at most once a
/// day, stamp persisted in UserDefaults), compare against the running bundle's version,
/// and remember the result so the menu can show an unobtrusive
/// "Update available — vX.Y.Z" item. All decisions (parse / compare / throttle) live in
/// ``UpdateCheck`` (Core, CI-tested); this class only does I/O.
///
/// Failure policy: EVERY failure (offline, rate-limited, malformed response) is a silent
/// no-op — the check never blocks launch, never dialogs, never retries eagerly. No
/// auto-download either: the menu item just opens the release page in the browser.
@MainActor
final class UpdateChecker {
    /// The newer release, once one was found; nil until then. Read by the menu builder.
    private(set) var available: UpdateCheck.ReleaseInfo?
    /// Fired (on the main actor) when ``available`` flips non-nil, so the menu rebuilds.
    var onUpdateFound: (() -> Void)?

    /// GitHub Releases "latest" endpoint — excludes drafts and prereleases by definition.
    static let releasesLatestURL = URL(
        string: "https://api.github.com/repos/keboola/jazz-desktop-client/releases/latest")!

    /// Tight budgets, like the agent's other small-JSON calls (``RegistryFetcher``): this
    /// is a background nicety, not worth waiting on.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    /// Run the check if the daily throttle allows. The stamp is written BEFORE the fetch,
    /// so a failing network can't turn the check into a hammer — failures also wait out
    /// the full interval.
    func checkIfDue(now: Date = Date()) async {
        guard
            UpdateCheck.shouldCheck(
                now: now, lastCheck: AgentSettings.shared.lastUpdateCheckAt)
        else { return }
        AgentSettings.shared.lastUpdateCheckAt = now

        var request = URLRequest(url: Self.releasesLatestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard
            let (data, response) = try? await Self.session.data(for: request),
            let code = (response as? HTTPURLResponse)?.statusCode,
            (200..<300).contains(code),
            let release = UpdateCheck.parse(latestReleaseJSON: data),
            UpdateCheck.isNewer(current: AppInfo.shortVersion, latest: release.tagName)
        else { return }
        available = release
        onUpdateFound?()
    }

    /// Open the found release's page in the default browser (the menu item's action).
    func openReleasePage() {
        guard let url = available?.htmlURL else { return }
        NSWorkspace.shared.open(url)
    }
}
