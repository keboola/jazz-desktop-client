import Foundation

/// Build identity, read from the bundle's Info.plist (git-stamped by build-app.sh). Surfaced in
/// Settings so it's always clear which build is running — no more "am I on the old app?".
enum AppInfo {
    /// Product version alone (CFBundleShortVersionString) — what the update check compares
    /// against a release tag. "dev" outside a bundle (swift run), which the semver-tolerant
    /// compare treats as unparsable → never nags in dev.
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// The version exported as OTLP `service.version` / `client.version`: the bundle's product
    /// version, or "" (unknown) outside a bundle. Unlike ``shortVersion`` it never reports "dev",
    /// which a reader would mistake for a real release.
    static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    static var version: String {
        let short = shortVersion
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }
}
