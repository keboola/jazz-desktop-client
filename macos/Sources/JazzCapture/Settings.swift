import Foundation
import JazzCaptureCore

extension Notification.Name {
    static let captureSetupWillChange = Notification.Name("dev.jazz.captureSetupWillChange")
    static let captureSetupDidChange = Notification.Name("dev.jazz.captureSetupDidChange")
    static let continuousCaptureDidChange = Notification.Name(
        "dev.jazz.continuousCaptureDidChange")
    static let captureCoachLiveConsentDidChange = Notification.Name(
        "dev.jazz.captureCoachLiveConsentDidChange")
}

/// User-configurable agent settings, persisted in UserDefaults. Consent-first: nothing is
/// captured until the user starts a session, and never from denylisted apps.
///
/// Non-secret values only — the KBC token and the stream endpoint (its path embeds the
/// stream secret) live in the Keychain (``Keychain/Account``). The stack/project/identity
/// fields here are auto-detected from the token by ``KeboolaConnection`` and kept so the
/// UI can show what's connected without re-verifying.
final class AgentSettings {
    static let shared = AgentSettings()
    private let defaults: UserDefaults
    private let forced: (String) -> Bool

    init(defaults: UserDefaults = .standard, forced: ((String) -> Bool)? = nil) {
        self.defaults = defaults
        self.forced = forced ?? { defaults.objectIsForced(forKey: $0) }
    }

    private(set) var enrollmentTransitions = 0
    func beginEnrollmentTransition() {
        enrollmentTransitions += 1
        NotificationCenter.default.post(name: .captureSetupWillChange, object: nil)
    }
    func endEnrollmentTransition() {
        enrollmentTransitions -= 1
        NotificationCenter.default.post(name: .captureSetupDidChange, object: nil)
    }
    var hasStoredEnrollmentRouting: Bool { defaults.object(forKey: Key.archiveEnrollmentRouting) != nil }

    static let managedSetupKey = "captureSetupRestrictions.v1"
    static let localOnlyKey = "captureSetupLocalOnly.v1"
    // Native forced preferences are provenance, never enrollment/signing authority.
    static let setupKeys = [managedSetupKey, localOnlyKey, "userEmail", "instanceName",
        "captureScreenshots", "captureNarration", "captureCoachLive.v1", "continuousCapture",
        "captureDeliveryPolicy", "archiveEnrollmentRouting.v1", "kbcStackURL", "kbcProjectId",
        "lastAreaId", "lastAreaName", "denylistBundleIDs"]

    func isForced(_ key: String) -> Bool { forced(key) }
    var managedSetupPresent: Bool { Self.setupKeys.contains(where: forced) }
    var managedRestrictions: CaptureManagedRestrictions? {
        guard forced(Self.managedSetupKey),
            let value = defaults.object(forKey: Self.managedSetupKey) as? [String: Any],
            JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return try? CaptureManagedRestrictions.decode(data)
    }
    var managedSetupError: String? {
        if defaults.object(forKey: Self.managedSetupKey) != nil && !forced(Self.managedSetupKey) {
            return "Managed restrictions lack native forced-preference provenance — ask your administrator"
        }
        if managedSetupPresent && managedRestrictions == nil {
            return "Managed setup is missing or malformed — administrator must restore captureSetupRestrictions.v1"
        }
        // Directly forced modality/mode keys may only narrow, never opt a user into recording.
        for key in [Key.screenshots, Key.narration, Key.captureCoachLive, Key.continuousCapture] where forced(key) {
            guard let bytes = try? JSONSerialization.data(withJSONObject: [defaults.object(forKey: key) as Any]),
                let values = try? JSONDecoder().decode([Bool].self, from: bytes), values == [false]
            else { return "Managed recording/modality values must be Boolean false — contact your administrator" }
        }
        if forced(Key.deliveryPolicy), defaults.string(forKey: Key.deliveryPolicy) != "confirmedArchive" {
            return "Managed delivery must require confirmed archives — contact your administrator"
        }
        for key in [Key.userEmail, Key.instanceName] where forced(key) {
            guard let value = defaults.object(forKey: key) as? String,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return "Managed identity fields must be nonempty text — contact your administrator" }
        }
        if forced(Key.denylist), defaults.stringArray(forKey: Key.denylist) == nil {
            return "Managed excluded apps must be an array of bundle IDs — contact your administrator"
        }
        if forced(Self.localOnlyKey) { return "Managed installations cannot force unmanaged local-only setup" }
        return nil
    }
    var managedSetupFingerprint: String {
        let values = Self.setupKeys.filter(forced).reduce(into: [String: Any]()) {
            let value = defaults.object(forKey: $1)
            $0[$1] = (value as? Data).map { $0.base64EncodedString() } ?? value ?? NSNull()
        }
        guard JSONSerialization.isValidJSONObject(values),
            let bytes = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
            let text = String(data: bytes, encoding: .utf8) else { return "invalid" }
        return text
    }
    var setupLocalOnly: Bool {
        get { defaults.object(forKey: Self.localOnlyKey) as? Bool ?? false }
        set { setSetupValue(newValue, key: Self.localOnlyKey) }
    }

    private func setSetupValue(_ value: Any?, key: String) {
        guard !forced(key) else { return }
        if let old = defaults.object(forKey: key) as? NSObject, let value, old.isEqual(value) { return }
        if defaults.object(forKey: key) == nil && value == nil { return }
        NotificationCenter.default.post(name: .captureSetupWillChange, object: nil)
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .captureSetupDidChange, object: nil)
    }

    private enum Key {
        static let userEmail = "userEmail"
        static let instanceName = "instanceName"
        static let denylist = "denylistBundleIDs"
        static let denylistInitialized = "denylistInitialized"
        static let screenshots = "captureScreenshots"
        static let narration = "captureNarration"
        static let localDiskReserveBytes = "localDiskReserveBytes.v1"
        static let captureCoachLive = "captureCoachLive.v1"
        static let highlightClicks = "highlightClicks"
        static let kbcStackURL = "kbcStackURL"
        static let kbcProjectId = "kbcProjectId"
        static let kbcProjectName = "kbcProjectName"
        static let archiveEnrollmentRouting = "archiveEnrollmentRouting.v1"
        static let deviceTokenRenewalAnchor = "deviceTokenRenewalAnchor.v1"
        static let deliveryPolicy = "captureDeliveryPolicy"
        static let reviewAppURL = "reviewAppURL"
        static let guidedExecutionURL = "guidedExecutionURL"
        static let reconnectOnLaunch = "reconnectOnLaunch"
        static let continuousCapture = "continuousCapture"
        static let bdmLanguage = "bdmLanguage"
        static let lastAreaId = "lastAreaId"
        static let lastAreaName = "lastAreaName"
        static let lastUpdateCheckAt = "lastUpdateCheckAt"
    }

    /// Public Keboola stacks used only as backward-compatible token-verify fallbacks. New device
    /// bundles carry their exact stack (including dedicated stacks); reconnect prefers the last
    /// verified stack before trying this list.
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
        set { setSetupValue(newValue, key: Key.userEmail) }
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
        set { setSetupValue(newValue, key: Key.instanceName) }
    }

    /// Apps that are NEVER captured. Everything else IS captured during a session. On first
    /// run this returns the sensible default exclusions; once the user edits it, their list
    /// (even if emptied) is respected.
    var denylist: Set<String> {
        get {
            guard defaults.bool(forKey: Key.denylistInitialized) || forced(Key.denylist) else {
                return Self.defaultDenylist
            }
            return Set(defaults.stringArray(forKey: Key.denylist) ?? [])
        }
        set {
            setSetupValue(Array(newValue).sorted(), key: Key.denylist)
            defaults.set(true, forKey: Key.denylistInitialized)
        }
    }

    var captureScreenshots: Bool {
        get { managedRestrictions?.screenshots ?? (defaults.object(forKey: Key.screenshots) as? Bool ?? true) }
        set { setSetupValue(newValue, key: Key.screenshots) }
    }

    /// Decimal bytes, validated by CaptureDiskReserve at every admission. An invalid stored
    /// type/value blocks capture rather than silently substituting a permissive default.
    var localDiskReserveBytes: String {
        get {
            guard let value = defaults.object(forKey: Key.localDiskReserveBytes) else {
                return String(CaptureDiskReserve.initialReserveBytes)
            }
            return value as? String ?? ""
        }
        set { defaults.set(newValue, forKey: Key.localDiskReserveBytes) }
    }

    /// Engineering-only decimal settings. Invalid types/values block rather than relax limits.
    var chunkDurationSeconds: String {
        guard let value = defaults.object(forKey: "chunkDurationSeconds.v1") else {
            return String(Int(CaptureChunkBoundary.defaultDuration))
        }
        return value as? String ?? ""
    }
    var chunkTargetBytes: String {
        guard let value = defaults.object(forKey: "chunkTargetBytes.v1") else {
            return String(CaptureChunkBoundary.defaultTargetBytes)
        }
        return value as? String ?? ""
    }

    var captureNarration: Bool {
        get { managedRestrictions?.narration ?? (defaults.object(forKey: Key.narration) as? Bool ?? true) }
        set { setSetupValue(newValue, key: Key.narration) }
    }

    var captureCoachLive: Bool {
        get {
            if managedRestrictions?.coachLive == false { return false }
            return CaptureCoachLiveConsent.isEnabled(
                storedValue: defaults.object(forKey: Key.captureCoachLive) as? Bool)
        }
        set {
            let changed = captureCoachLive != newValue
            setSetupValue(newValue, key: Key.captureCoachLive)
            if changed {
                NotificationCenter.default.post(
                    name: .captureCoachLiveConsentDidChange, object: nil)
            }
        }
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
        set { setSetupValue(newValue, key: Key.kbcStackURL) }
    }

    /// Crash boundary used only when switching into legacy raw-token mode. The verified stack must
    /// reach persistent storage before a raw token can become authoritative.
    @discardableResult
    func commitKBCStackURL(_ value: String) -> Bool {
        setSetupValue(value, key: Key.kbcStackURL)
        return defaults.synchronize()
    }

    /// Keboola project id/name from the token verify — display-only ("what am I connected to").
    var kbcProjectId: String {
        get { defaults.string(forKey: Key.kbcProjectId) ?? "" }
        set { setSetupValue(newValue, key: Key.kbcProjectId) }
    }

    var kbcProjectName: String {
        get { defaults.string(forKey: Key.kbcProjectName) ?? "" }
        set { defaults.set(newValue, forKey: Key.kbcProjectName) }
    }

    /// Non-secret routing bound by the server-issued enrollment bundle. Missing values never fall
    /// back to project/user guesses: confirmed archives stay local until a complete bundle arrives.
    var archiveEnrollmentRouting: JazzArchiveEnrollmentRouting? {
        get {
            guard let data = defaults.data(forKey: Key.archiveEnrollmentRouting) else { return nil }
            return try? JSONDecoder().decode(JazzArchiveEnrollmentRouting.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                if let oldRoute = archiveUploadRouteBinding,
                    let newRoute = try? newValue.uploadRouteBinding(),
                    oldRoute.hasSameDeliveryAuthority(as: newRoute) {
                    // Credential renewal is not a material setup change; retain the existing
                    // notice and capture intent, while fresh trust/expiry checks remain in force.
                    defaults.set(data, forKey: Key.archiveEnrollmentRouting)
                    NotificationCenter.default.post(name: .captureSetupDidChange, object: nil)
                } else { setSetupValue(data, key: Key.archiveEnrollmentRouting) }
            } else {
                setSetupValue(nil, key: Key.archiveEnrollmentRouting)
            }
        }
    }

    /// Where the unattended token-renewal schedule is anchored (non-secret: a token id, the moment
    /// that credential was issued to this Mac, and the server's own lead time). Keyed by token id,
    /// so a credential replaced by any other path — an admin bundle import, a device-bound
    /// redemption — cannot inherit a stale schedule.
    var deviceTokenRenewalAnchor: JazzDeviceTokenRenewalAnchor? {
        get {
            guard let data = defaults.data(forKey: Key.deviceTokenRenewalAnchor) else { return nil }
            return try? JSONDecoder().decode(JazzDeviceTokenRenewalAnchor.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.deviceTokenRenewalAnchor)
            } else {
                defaults.removeObject(forKey: Key.deviceTokenRenewalAnchor)
            }
        }
    }

    private var validatedArchiveEnrollmentRouting: JazzArchiveEnrollmentRouting? {
        guard let routing = archiveEnrollmentRouting,
            routing.projectId == kbcProjectId,
            KeboolaStack.normalize(routing.stackURL) == KeboolaStack.normalize(kbcStackURL),
            JazzArchiveControlPlaneURL.normalize(routing.archiveIngestURL)
                == routing.archiveIngestURL
        else { return nil }
        return routing
    }

    var archiveIngestURL: String {
        validatedArchiveEnrollmentRouting?.archiveIngestURL ?? ""
    }
    var deviceTokenExpiresAt: String { archiveEnrollmentRouting?.expiresAt ?? "" }

    /// Local-first confirmation is the default. The legacy live projection is opt-in and can be
    /// rolled back without changing canonical archive/capture/event/artifact identities.
    var deliveryPolicy: JazzCaptureDeliveryPolicy {
        get {
            if managedSetupPresent { return .confirmedArchive }
            return defaults.string(forKey: Key.deliveryPolicy)
                .flatMap(JazzCaptureDeliveryPolicy.init(rawValue:)) ?? .confirmedArchive
        }
        set { setSetupValue(newValue.rawValue, key: Key.deliveryPolicy) }
    }

    var archiveUploadScope: JazzArchiveUploadScope? {
        validatedArchiveEnrollmentRouting?.scope
    }

    var normalizedArchiveIngestURL: String? {
        JazzArchiveControlPlaneURL.normalize(archiveIngestURL)
    }

    /// Exact non-secret enrollment authority persisted into a delivery item before its first
    /// network attempt. A later bundle may rotate audit/credential snapshots, but never the
    /// issuer/audience, endpoint, stack, project, or company/area/device authority.
    var archiveUploadRouteBinding: JazzArchiveUploadRouteBinding? {
        try? validatedArchiveEnrollmentRouting?.uploadRouteBinding()
    }

    var hasArchiveDeliveryConfiguration: Bool {
        archiveUploadRouteBinding != nil
    }

    /// URL of the hosted jazz review Data App (timeline + clarify + L4 + BDM workshop).
    /// Empty until the user sets it — the WebCanvas shows a setup hint instead of loading
    /// anything (no invented default URL).
    var reviewAppURL: String {
        get { defaults.string(forKey: Key.reviewAppURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.reviewAppURL) }
    }

    /// Non-secret base URL for the Jazz governance API. The separately scoped credential remains
    /// in Keychain and is loaded only at request time.
    var guidedExecutionURL: String {
        get { defaults.string(forKey: Key.guidedExecutionURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.guidedExecutionURL) }
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
        set { setSetupValue(newValue, key: Key.lastAreaId) }
    }
    var lastAreaName: String {
        get { defaults.string(forKey: Key.lastAreaName) ?? "" }
        set { setSetupValue(newValue, key: Key.lastAreaName) }
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
    /// successful connect) and runs until paused, so the user just leaves jazz running and
    /// brackets activities with labels. **Default off** — an always-on capture surface is opt-in
    /// for a consent-based tool; once enabled it persists across launches.
    var continuousCapture: Bool {
        get { managedRestrictions?.continuous ?? (defaults.object(forKey: Key.continuousCapture) as? Bool ?? false) }
        set {
            guard continuousCapture != newValue else { return }
            setSetupValue(newValue, key: Key.continuousCapture)
            NotificationCenter.default.post(name: .continuousCaptureDidChange, object: nil)
        }
    }
}
