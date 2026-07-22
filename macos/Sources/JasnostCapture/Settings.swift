import Foundation

/// User-configurable agent settings, persisted in UserDefaults. Consent-first: nothing is
/// captured until the user starts a session, and never from denylisted apps.
///
/// Non-secret values only — the KBC token and the stream endpoint (its path embeds the
/// stream secret) live in the Keychain (``Keychain/Account``). The stack/project/identity
/// fields here are auto-detected from the token by ``KeboolaConnection`` and kept so the
/// UI can show what's connected without re-verifying.
final class AgentSettings {
    static let shared = AgentSettings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let userEmail = "userEmail"
        static let instanceName = "instanceName"
        static let denylist = "denylistBundleIDs"
        static let denylistInitialized = "denylistInitialized"
        static let screenshots = "captureScreenshots"
        static let narration = "captureNarration"
        static let highlightClicks = "highlightClicks"
        static let kbcStackURL = "kbcStackURL"
        static let kbcProjectId = "kbcProjectId"
        static let kbcProjectName = "kbcProjectName"
        static let reviewAppURL = "reviewAppURL"
        static let reconnectOnLaunch = "reconnectOnLaunch"
        static let continuousCapture = "continuousCapture"
        static let bdmLanguage = "bdmLanguage"
        static let lastAreaId = "lastAreaId"
        static let lastAreaName = "lastAreaName"
        static let lastUpdateCheckAt = "lastUpdateCheckAt"
    }

    /// Keboola stacks the token verify auto-detects across (label -> Storage API base URL).
    /// Non-secret. Order matters only for probe speed — the first stack that accepts the
    /// token wins.
    static let knownStacks: [(label: String, url: String)] = [
        ("EU Central (GCP)", "https://connection.europe-west3.gcp.keboola.com"),
        ("US (AWS, multi-tenant)", "https://connection.keboola.com"),
        ("EU (AWS)", "https://connection.eu-central-1.keboola.com"),
        ("US (GCP)", "https://connection.us-east4.gcp.keboola.com"),
        ("EU North (Azure)", "https://connection.north-europe.azure.keboola.com"),
    ]

    /// Sensible privacy defaults excluded on first run (secret-bearing apps). Shown in the
    /// UI and fully editable — not a hidden default.
    static let defaultDenylist: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
    ]

    /// Identity attributed to captured sessions (`enduser.id` on every OTLP record).
    /// Auto-filled from the token verify when empty; stays editable as a manual override.
    var userEmail: String {
        get { defaults.string(forKey: Key.userEmail) ?? "" }
        set { defaults.set(newValue, forKey: Key.userEmail) }
    }

    /// Name of THIS machine — `host.name` on every OTLP record (which computer is recording),
    /// distinct from ``userEmail`` (WHO). Auto-filled once from the OS hostname when empty and
    /// persisted, so the value is stable across sessions; stays editable as a manual override.
    var instanceName: String {
        get {
            let stored = defaults.string(forKey: Key.instanceName) ?? ""
            if !stored.isEmpty { return stored }
            // Compute once from the OS and persist, so the name is stable from here on (never
            // an invented constant — the machine's own name).
            let detected = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            defaults.set(detected, forKey: Key.instanceName)
            return detected
        }
        set { defaults.set(newValue, forKey: Key.instanceName) }
    }

    /// Apps that are NEVER captured. Everything else IS captured during a session. On first
    /// run this returns the sensible default exclusions; once the user edits it, their list
    /// (even if emptied) is respected.
    var denylist: Set<String> {
        get {
            guard defaults.bool(forKey: Key.denylistInitialized) else { return Self.defaultDenylist }
            return Set(defaults.stringArray(forKey: Key.denylist) ?? [])
        }
        set {
            defaults.set(Array(newValue).sorted(), forKey: Key.denylist)
            defaults.set(true, forKey: Key.denylistInitialized)
        }
    }

    var captureScreenshots: Bool {
        get { defaults.object(forKey: Key.screenshots) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.screenshots) }
    }

    var captureNarration: Bool {
        get { defaults.object(forKey: Key.narration) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.narration) }
    }

    /// Briefly highlight on screen the element the user clicks during capture (the visible half of
    /// "record what you show"). Default on; turn off if it's distracting.
    var highlightClicks: Bool {
        get { defaults.object(forKey: Key.highlightClicks) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.highlightClicks) }
    }

    /// Keboola Storage API base URL (the stack). Auto-detected from the token by
    /// ``KeboolaConnection`` — no manual picker. Non-secret; the token lives in the Keychain.
    var kbcStackURL: String {
        get { defaults.string(forKey: Key.kbcStackURL) ?? Self.knownStacks[0].url }
        set { defaults.set(newValue, forKey: Key.kbcStackURL) }
    }

    /// Keboola project id/name from the token verify — display-only ("what am I connected to").
    var kbcProjectId: String {
        get { defaults.string(forKey: Key.kbcProjectId) ?? "" }
        set { defaults.set(newValue, forKey: Key.kbcProjectId) }
    }

    var kbcProjectName: String {
        get { defaults.string(forKey: Key.kbcProjectName) ?? "" }
        set { defaults.set(newValue, forKey: Key.kbcProjectName) }
    }

    /// URL of the hosted jasnost review Data App (timeline + clarify + L4 + BDM workshop).
    /// Empty until the user sets it — the WebCanvas shows a setup hint instead of loading
    /// anything (no invented default URL).
    var reviewAppURL: String {
        get { defaults.string(forKey: Key.reviewAppURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.reviewAppURL) }
    }

    /// Human language a BDM workshop runs in (e.g. "Czech"), picked from the menu before starting.
    /// Empty = Auto (the model mirrors the spoken narration). Steers both the adaptive questions and
    /// the wording of the generated Business Data Model; persisted so the last choice is the default.
    var bdmLanguage: String {
        get { defaults.string(forKey: Key.bdmLanguage) ?? "" }
        set { defaults.set(newValue, forKey: Key.bdmLanguage) }
    }

    /// The Area (scope) the next capture is anchored to (ADR 0002 / docs/AREA_MODEL_PLAN.md). Picked
    /// from the menu, minted to a stable id by CaptureScope; sticky (the last pick is the default).
    /// Empty = the default "General" Area (the processor reads a missing area.id as General).
    var lastAreaId: String {
        get { defaults.string(forKey: Key.lastAreaId) ?? "" }
        set { defaults.set(newValue, forKey: Key.lastAreaId) }
    }
    var lastAreaName: String {
        get { defaults.string(forKey: Key.lastAreaName) ?? "" }
        set { defaults.set(newValue, forKey: Key.lastAreaName) }
    }

    /// When the GitHub-releases update check last ran (any outcome — the stamp is written
    /// before the fetch, so failures also wait out the throttle). Persisted so "at most
    /// once a day" holds across launches. Not user-facing; nil = never checked.
    var lastUpdateCheckAt: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheckAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheckAt) }
    }

    /// On launch, if a Keboola token is stored, re-verify it in the background (refreshing
    /// the detected stack/project/identity and surfacing an expired token in the menu).
    /// Default on; nothing else runs at launch — the spool sender drains regardless.
    var reconnectOnLaunch: Bool {
        get { defaults.object(forKey: Key.reconnectOnLaunch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.reconnectOnLaunch) }
    }

    /// Continuous capture: when on, capture starts automatically at launch (and right after a
    /// successful connect) and runs until paused, so the user just leaves jasnost running and
    /// brackets activities with labels. **Default off** — an always-on capture surface is opt-in
    /// for a consent-based tool; once enabled it persists across launches.
    var continuousCapture: Bool {
        get { defaults.object(forKey: Key.continuousCapture) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.continuousCapture) }
    }
}
