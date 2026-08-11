import AppKit

/// The currently focused application.
struct FrontApp {
    var bundleID: String?
    var name: String?
    var version: String?
    var pid: pid_t
}

enum AppContext {
    static func frontmost() -> FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontApp(
            bundleID: app.bundleIdentifier,
            name: app.localizedName,
            version: app.bundleURL.flatMap(Bundle.init(url:))?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            pid: app.processIdentifier
        )
    }
}
