import Foundation
import XCTest
import JazzCaptureCore
@testable import JazzCapture

/// Actual SettingsStore refresh and Toggle's published binding. Managed overrides and TCC/
/// enrollment/credential reads are injected; no window, real preferences, Keychain or recording.
@MainActor
final class SettingsStoreTests: XCTestCase {
    private final class ManagedDefaults: UserDefaults {
        var overrides: [String: Any] = [:]
        var writes = 0
        override func object(forKey key: String) -> Any? { overrides[key] ?? super.object(forKey: key) }
        override func string(forKey key: String) -> String? { object(forKey: key) as? String }
        override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
        override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
        override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
        override func set(_ value: Any?, forKey key: String) {
            writes += 1
            super.set(value, forKey: key)
        }
    }

    private let durability = JazzArchiveFilesystemDurability(
        synchronizeRegularFile: { _, _ in }, synchronizeDirectory: { _ in })
    private let restrictions: [String: Any] = ["version": 1, "requireReview": true, "requireEnrollment": true]

    private func fixture() throws -> (ManagedDefaults, AgentSettings, URL) {
        let name = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(ManagedDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let settings = AgentSettings(defaults: defaults, forced: { defaults.overrides[$0] != nil })
        settings.userEmail = "local@example.invalid"
        settings.instanceName = "Local test Mac"
        return (defaults, settings, root)
    }

    private func store(_ settings: AgentSettings, _ setup: CaptureSetup) -> SettingsStore {
        SettingsStore(settings: settings, readiness: setup.readiness,
            permissionStatus: { _ in .granted }, readGuidedCredential: { nil })
    }

    func testLocalOnlyCanAlwaysTurnOffToCompleteEnrolledOrManagedSetup() throws {
        for managed in [false, true] {
            let (defaults, settings, root) = try fixture()
            settings.setupLocalOnly = true
            var enrollment = CaptureSetupEnrollment(route: nil, profile: "Unassigned", present: false, usable: false)
            let setup = CaptureSetup(settings: settings, root: root, durability: durability,
                enrollment: { enrollment }, permissions: { _ in true })
            let store = store(settings, setup)
            store.acknowledgeSetup()
            XCTAssertTrue(setup.readiness.status().ready)
            if managed {
                defaults.overrides[AgentSettings.managedSetupKey] = restrictions
            } else {
                enrollment = .init(route: nil, profile: "Injected accepted enrollment", present: true, usable: true)
            }
            store.refreshPermissions()
            XCTAssertFalse(setup.readiness.status().ready)
            XCTAssertTrue(setup.readiness.requiresEnrollment)
            XCTAssertTrue(store.setupLocalOnly)
            XCTAssertTrue(store.canChangeLocalOnly, "the already-on Toggle must permit OFF")
            // Follow the same enablement decision and published binding as the real Toggle.
            if store.canChangeLocalOnly { store.setupLocalOnly = false }
            XCTAssertFalse(settings.setupLocalOnly)
            if managed {
                enrollment = .init(route: nil, profile: "Injected accepted enrollment", present: true, usable: true)
                store.refreshPermissions()
            }
            store.acknowledgeSetup()
            XCTAssertTrue(setup.readiness.status().ready)
            XCTAssertFalse(store.canChangeLocalOnly, "history still prohibits turning ON")
            store.setupLocalOnly = true
            XCTAssertFalse(settings.setupLocalOnly, "a stale binding cannot shed enrollment requirements")
        }
    }

    func testOpenSettingsRefreshMatchesAcknowledgmentAfterForcedFieldRemovalWithoutWriteback() throws {
        let (defaults, settings, root) = try fixture()
        settings.captureScreenshots = true
        settings.captureNarration = true
        settings.captureCoachLive = true
        settings.continuousCapture = true
        settings.denylist = ["local.excluded"]
        defaults.overrides = [AgentSettings.managedSetupKey: restrictions,
            "captureScreenshots": false, "captureNarration": false, "captureCoachLive.v1": false,
            "continuousCapture": false, "userEmail": "managed@example.invalid",
            "instanceName": "Managed test Mac", "denylistBundleIDs": ["managed.excluded"]]
        let setup = CaptureSetup(settings: settings, root: root, durability: durability,
            enrollment: { .init(route: nil, profile: "Injected accepted enrollment", present: true, usable: true) },
            permissions: { _ in true })
        let writesBeforeOpen = defaults.writes
        let store = store(settings, setup)
        XCTAssertFalse(store.captureScreenshots)
        XCTAssertEqual(store.userEmail, "managed@example.invalid")
        store.acknowledgeSetup()
        XCTAssertTrue(setup.readiness.status().ready)
        XCTAssertEqual(defaults.writes, writesBeforeOpen, "opening/refreshing must not rewrite local preferences")
        defaults.overrides = [AgentSettings.managedSetupKey: restrictions]
        let writesBeforeRefresh = defaults.writes
        store.refreshPermissions() // The polling path used while Settings remains open.
        let snapshot = try XCTUnwrap(store.setupStatus?.snapshot)
        XCTAssertTrue(snapshot.screenshots)
        XCTAssertTrue(snapshot.narration)
        XCTAssertTrue(snapshot.coachLive)
        XCTAssertTrue(snapshot.continuous)
        XCTAssertEqual(snapshot.user, "local@example.invalid")
        XCTAssertEqual(snapshot.machine, "Local test Mac")
        XCTAssertEqual(snapshot.exclusions, ["local.excluded"])
        XCTAssertEqual(store.captureScreenshots, snapshot.screenshots)
        XCTAssertEqual(store.captureNarration, snapshot.narration)
        XCTAssertEqual(store.captureCoachLive, snapshot.coachLive)
        XCTAssertEqual(store.continuousCapture, snapshot.continuous)
        XCTAssertEqual(store.userEmail, snapshot.user)
        XCTAssertEqual(store.instanceName, snapshot.machine)
        XCTAssertEqual(store.denylist, snapshot.exclusions)
        XCTAssertEqual(store.deliveryPolicy, snapshot.delivery)
        XCTAssertEqual(store.setupLocalOnly, snapshot.localOnly)
        XCTAssertEqual(defaults.writes, writesBeforeRefresh)
        XCTAssertFalse(setup.readiness.status().ready, "removal requires a new truthful notice")
        store.acknowledgeSetup()
        XCTAssertTrue(setup.readiness.status().ready)
        XCTAssertTrue(setup.readiness.admit())
        XCTAssertEqual(defaults.writes, writesBeforeRefresh, "acknowledgment changes only durable readiness evidence")
        // User edits still write through the same bindings; refresh suppression is not permanent.
        store.captureScreenshots = false
        XCTAssertFalse(settings.captureScreenshots)
        XCTAssertGreaterThan(defaults.writes, writesBeforeRefresh)
    }

    func testRestrictiveRefreshDoesNotOverwriteUnderlyingUnforcedPreferences() throws {
        let (defaults, settings, root) = try fixture()
        settings.captureScreenshots = true
        settings.captureNarration = true
        settings.captureCoachLive = true
        settings.continuousCapture = true
        var restricted = restrictions
        for key in ["screenshots", "narration", "coachLive", "continuous"] { restricted[key] = false }
        defaults.overrides[AgentSettings.managedSetupKey] = restricted
        let setup = CaptureSetup(settings: settings, root: root, durability: durability,
            enrollment: { .init(route: nil, profile: "Injected accepted enrollment", present: true, usable: true) },
            permissions: { _ in true })
        let before = defaults.writes
        let store = store(settings, setup)
        store.refreshPermissions()
        XCTAssertEqual(defaults.writes, before)
        defaults.overrides[AgentSettings.managedSetupKey] = restrictions
        store.refreshPermissions()
        XCTAssertTrue(store.captureScreenshots)
        XCTAssertTrue(store.captureNarration)
        XCTAssertTrue(store.captureCoachLive)
        XCTAssertTrue(store.continuousCapture)
        XCTAssertEqual(defaults.writes, before)
    }
}
