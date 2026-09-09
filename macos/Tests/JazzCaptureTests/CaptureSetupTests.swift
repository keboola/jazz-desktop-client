import Foundation
import XCTest
import JazzCaptureCore
import JazzEnrollmentSecurity
@testable import JazzCapture

/// Production settings/trust resolution and requestStart/post-await admission seams. No native
/// recorder, TCC call, Keychain, real preferences, network, installed app or session-lock probe.
@MainActor
final class CaptureSetupTests: XCTestCase {
    private let durability = JazzArchiveFilesystemDurability(
        synchronizeRegularFile: { _, _ in }, synchronizeDirectory: { _ in })
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private actor Gate {
        var waiter: CheckedContinuation<Void, Never>?
        var waiting = false
        func wait() async { waiting = true; await withCheckedContinuation { waiter = $0 } }
        func release() { waiter?.resume(); waiter = nil }
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func settings(forced: @escaping (String) -> Bool = { _ in false }) -> (AgentSettings, UserDefaults) {
        let name = "CaptureSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set("test@example.invalid", forKey: "userEmail")
        defaults.set("Synthetic Mac", forKey: "instanceName")
        return (AgentSettings(defaults: defaults, forced: forced), defaults)
    }

    private var local: CaptureSetupEnrollment {
        .init(route: nil, profile: "Unassigned — no enrollment", present: false, usable: false)
    }

    private func signed() throws -> (JazzSignedDeviceCredentialEnvelope, EnrollmentAcceptanceRecord, EnrollmentTrustPolicy) {
        let authority = try JazzArchiveSignedEnrollmentAuthority(issuer: "https://issuer.example.invalid", audience: "test-desktop",
            bundleId: "jdb_" + String(repeating: "a", count: 32), generation: 1, envelopeDigest: String(repeating: "b", count: 64))
        let scope = try JazzArchiveUploadScope(companyId: "test-company", areaId: "test-area", deviceId: "test-device")
        let routing = JazzArchiveEnrollmentRouting(projectId: "123", stackURL: "https://connection.test.keboola.com", scope: scope,
            archiveIngestURL: "https://ingest.example.invalid/api/archive-ingests", tokenId: "synthetic-token-id",
            expiresAt: Timestamps.iso8601(now.addingTimeInterval(60)), signedAuthority: authority, authorizationProfile: .signedJWS)
        let envelope = try JazzSignedDeviceCredentialEnvelope(token: "synthetic-not-a-credential", expiresAt: routing.expiresAt,
            routeBinding: routing.signedUploadRouteBinding(), enrollmentRouting: routing, streamSourceId: nil, streamEndpoint: nil)
        let ledger = FileEnrollmentAcceptanceStore(fileURL: try root().appendingPathComponent("acceptance.json"))
        _ = try ledger.authorizeAndRecord(deviceId: scope.deviceId, generation: authority.generation,
            bundleId: authority.bundleId, envelopeDigest: authority.envelopeDigest, acceptedAt: now)
        let record = try XCTUnwrap(ledger.records()[scope.deviceId])
        let trust = try EnrollmentTrustPolicy(issuer: authority.issuer, audience: authority.audience,
            publicKeysByKeyID: ["test-key": Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")])
        return (envelope, record, trust)
    }

    private func readEnrollment(_ settings: AgentSettings, failure: String?,
        envelope: JazzSignedDeviceCredentialEnvelope? = nil) -> CaptureSetupEnrollment
    {
        CaptureSetupEnrollment.current(settings: settings, readPending: {
            if failure == "pending" { throw CocoaError(.fileReadNoPermission) }
            return false
        }, readEnvelope: {
            if failure == "envelope" { throw CocoaError(.fileReadNoPermission) }
            return envelope
        }, readAcceptance: { _ in
            if failure == "acceptance" { throw CocoaError(.fileReadNoPermission) }
            return nil
        }, loadTrust: { nil }, readMVPCredential: {
            if failure == "mvp" { throw CocoaError(.fileReadNoPermission) }
            return false
        }, hasDeviceBoundActivation: { _ in false })
    }

    func testNeverEnrolledReadFailureBlocksTemporarilyWithoutManufacturingHistory() throws {
        for failedRead in ["pending", "envelope", "mvp"] {
            let (settings, _) = settings()
            settings.setupLocalOnly = true
            let root = try root()
            var failure: String?
            let setup = CaptureSetup(settings: settings, root: root, durability: durability,
                enrollment: { self.readEnrollment(settings, failure: failure) }, permissions: { _ in true })
            XCTAssertTrue(setup.readiness.acknowledge())
            XCTAssertTrue(setup.readiness.admit())
            failure = failedRead
            XCTAssertFalse(setup.readiness.permitsAdmission())
            XCTAssertFalse(setup.readiness.status().canAcknowledge)
            XCTAssertTrue(setup.readiness.status().snapshot.enrollmentProfile.contains("unavailable"))
            XCTAssertTrue(setup.readiness.status().snapshot.company.contains("Unknown"))
            XCTAssertTrue(setup.readiness.status().snapshot.destination.contains("Unknown"))
            XCTAssertFalse(setup.readiness.requiresEnrollment, "unavailable is not positively observed enrollment")
            let unavailableRelaunch = CaptureSetup(settings: settings, root: root, durability: durability,
                enrollment: { self.readEnrollment(settings, failure: failure) }, permissions: { _ in true })
            XCTAssertFalse(unavailableRelaunch.readiness.acknowledge())
            XCTAssertFalse(unavailableRelaunch.readiness.requiresEnrollment)
            failure = nil // All injected reads now positively confirm absence.
            let recovered = CaptureSetup(settings: settings, root: root, durability: durability,
                enrollment: { self.readEnrollment(settings, failure: failure) }, permissions: { _ in true })
            XCTAssertFalse(recovered.readiness.requiresEnrollment)
            XCTAssertTrue(recovered.readiness.acknowledge())
            XCTAssertTrue(recovered.readiness.admit())
            let acknowledgedRelaunch = CaptureSetup(settings: settings, root: root, durability: durability,
                enrollment: { self.readEnrollment(settings, failure: nil) }, permissions: { _ in true })
            XCTAssertTrue(acknowledgedRelaunch.readiness.status().ready)
        }
    }

    func testEvidenceReadFailureNeverErasesRealManagedOrEnrollmentHistory() throws {
        for managed in [false, true] {
            var forced = managed
            let (settings, defaults) = settings(forced: { forced && $0 == AgentSettings.managedSetupKey })
            if managed {
                defaults.set(["version": 1, "requireReview": true, "requireEnrollment": true],
                    forKey: AgentSettings.managedSetupKey)
            }
            let root = try root()
            var priorEnrollment = !managed
            let setup = CaptureSetup(settings: settings, root: root, durability: durability,
                enrollment: {
                    priorEnrollment ? .init(route: nil, profile: "Injected accepted enrollment", present: true, usable: true)
                        : self.readEnrollment(settings, failure: nil)
                }, permissions: { _ in true })
            _ = setup.readiness.status()
            XCTAssertTrue(setup.readiness.requiresEnrollment)
            priorEnrollment = false
            forced = false
            defaults.removeObject(forKey: AgentSettings.managedSetupKey)
            settings.setupLocalOnly = true
            for failure in ["pending", nil] as [String?] {
                let reopened = CaptureSetup(settings: settings, root: root, durability: durability,
                    enrollment: { self.readEnrollment(settings, failure: failure) }, permissions: { _ in true })
                XCTAssertTrue(reopened.readiness.requiresEnrollment)
                XCTAssertFalse(reopened.readiness.acknowledge())
                XCTAssertFalse(reopened.readiness.admit())
            }
        }
    }

    func testObservedSignedEnvelopeStillCountsWhenAcceptanceReadFails() throws {
        let (settings, _) = settings()
        let (envelope, _, _) = try signed()
        let evidence = readEnrollment(settings, failure: "acceptance", envelope: envelope)
        XCTAssertTrue(evidence.present, "the envelope was positively observed before the later read failed")
        XCTAssertFalse(evidence.usable)
        let setup = CaptureSetup(settings: settings, root: try root(), durability: durability,
            enrollment: { evidence }, permissions: { _ in true })
        XCTAssertFalse(setup.readiness.status().ready)
        XCTAssertTrue(setup.readiness.requiresEnrollment)
    }

    func testResolutionRequiresAtomicAcceptedSignedEvidenceNotPreferenceOrHealth() throws {
        let (envelope, accepted, trust) = try signed()
        func resolve(envelope value: JazzSignedDeviceCredentialEnvelope?, record: EnrollmentAcceptanceRecord?, trust policy: EnrollmentTrustPolicy?, pending: Bool = false, at: Date? = nil) -> CaptureSetupEnrollment {
            CaptureSetupEnrollment.resolve(pending: pending, envelope: value, accepted: record, trust: policy,
                projectedRoute: envelope.routeBinding, routingPresent: true, mvpCredentialPresent: true,
                mvpExpiry: now.addingTimeInterval(60), now: at ?? now)
        }
        let verified = resolve(envelope: envelope, record: accepted, trust: trust)
        XCTAssertTrue(verified.usable)
        XCTAssertTrue(verified.profile.contains("Signed enrollment accepted"))
        XCTAssertTrue(verified.profile.contains("device-bound activation provenance not recorded"))
        XCTAssertEqual(verified.route?.scope.companyId, "test-company")
        // Even a signedAuthority-looking preference route plus a token/health success is not trust.
        XCTAssertFalse(resolve(envelope: nil, record: accepted, trust: trust).usable)
        XCTAssertFalse(resolve(envelope: envelope, record: nil, trust: trust).usable)
        XCTAssertFalse(resolve(envelope: envelope, record: accepted, trust: nil).usable)
        let pending = resolve(envelope: envelope, record: accepted, trust: trust, pending: true)
        XCTAssertFalse(pending.usable)
        XCTAssertTrue(pending.profile.contains("Pending"))
        let expired = resolve(envelope: envelope, record: accepted, trust: trust, at: now.addingTimeInterval(120))
        XCTAssertFalse(expired.usable)
        XCTAssertTrue(expired.profile.contains("Expired"))
        XCTAssertFalse(CaptureSetupEnrollment.resolve(pending: false, envelope: envelope, accepted: accepted,
            trust: trust, projectedRoute: nil, routingPresent: false, mvpCredentialPresent: false,
            mvpExpiry: nil, now: now).usable, "missing repairable projection cannot silently change actual capture scope")
    }

    func testMVPIsExplicitlyUnverifiedAndNeedsStoredCredentialAndUnexpiredHandoff() throws {
        let (envelope, _, _) = try signed()
        let route = try JazzArchiveUploadRouteBinding(mvpIngestEndpoint: envelope.routeBinding.ingestEndpoint,
            stackURL: envelope.routeBinding.stackURL, projectId: "123", tokenId: "synthetic",
            scope: envelope.routeBinding.scope)
        for credential in [false, true] {
            for expired in [false, true] {
                let result = CaptureSetupEnrollment.resolve(pending: false, envelope: nil, accepted: nil, trust: nil,
                    projectedRoute: route, routingPresent: true, mvpCredentialPresent: credential,
                    mvpExpiry: now.addingTimeInterval(expired ? -1 : 60), now: now)
                XCTAssertEqual(result.usable, credential && !expired)
                if result.usable { XCTAssertTrue(result.profile.contains("NOT cryptographically verified")) }
            }
        }
    }

    func testProductionInputAndTemporarySetupSupportOfflineLocalOnlyAndDeniedPermissions() throws {
        let (settings, _) = settings()
        var allowed: Set<Permission> = []
        let setup = CaptureSetup(settings: settings, root: try root(), durability: durability,
            enrollment: { self.local }, permissions: { allowed.contains($0) })
        XCTAssertFalse(setup.readiness.admit())
        settings.setupLocalOnly = true
        allowed.insert(.accessibility)
        XCTAssertFalse(setup.readiness.acknowledge(), "requested screenshots/narration still missing")
        settings.captureScreenshots = false
        settings.captureNarration = false
        XCTAssertTrue(setup.readiness.acknowledge())
        XCTAssertTrue(setup.readiness.admit())
        XCTAssertEqual(setup.readiness.status().snapshot.company, "Unassigned")
        XCTAssertTrue(setup.readiness.status().snapshot.destination.contains("Local"))
        allowed.remove(.accessibility)
        XCTAssertFalse(setup.readiness.permitsAdmission())
        allowed.insert(.accessibility)
        XCTAssertTrue(setup.readiness.status().ready)
        XCTAssertFalse(setup.readiness.permitsAdmission(), "permission restoration is not a new Start")
    }

    func testNativeManagedProvenanceNarrowingMalformedAndRemovalHistory() throws {
        var forced: Set<String> = [AgentSettings.managedSetupKey]
        let (settings, defaults) = settings(forced: { forced.contains($0) })
        let root = try root()
        let (envelope, accepted, trust) = try signed()
        let enrollment = CaptureSetupEnrollment.resolve(pending: false, envelope: envelope, accepted: accepted,
            trust: trust, projectedRoute: envelope.routeBinding, routingPresent: true,
            mvpCredentialPresent: false, mvpExpiry: nil, now: now)
        let restrictions: [String: Any] = ["version": 1, "requireEnrollment": true, "requireReview": true,
            "continuous": false, "screenshots": false, "narration": false, "coachLive": false]
        defaults.set(restrictions, forKey: AgentSettings.managedSetupKey)
        settings.captureScreenshots = true
        settings.captureNarration = true
        settings.captureCoachLive = true
        settings.deliveryPolicy = .liveCompatibility
        settings.continuousCapture = true
        XCTAssertFalse(settings.captureScreenshots)
        XCTAssertFalse(settings.captureNarration)
        XCTAssertFalse(settings.captureCoachLive)
        XCTAssertFalse(settings.continuousCapture)
        XCTAssertEqual(settings.deliveryPolicy, .confirmedArchive)
        XCTAssertNil(settings.managedSetupError)
        let setup = CaptureSetup(settings: settings, root: root, durability: durability,
            enrollment: { enrollment }, permissions: { _ in true })
        XCTAssertTrue(setup.readiness.acknowledge())
        XCTAssertTrue(setup.readiness.admit())
        defaults.set(["version": 1, "requireReview": false], forKey: AgentSettings.managedSetupKey)
        XCTAssertNotNil(settings.managedSetupError)
        XCTAssertFalse(setup.readiness.permitsAdmission())
        forced = []
        defaults.removeObject(forKey: AgentSettings.managedSetupKey)
        settings.setupLocalOnly = true
        let reopened = CaptureSetup(settings: settings, root: root, durability: durability,
            enrollment: { self.local }, permissions: { _ in true })
        XCTAssertFalse(reopened.readiness.acknowledge())
        XCTAssertTrue(reopened.readiness.status().blockers.contains { $0.contains("removed") })
        defaults.set(restrictions, forKey: AgentSettings.managedSetupKey)
        XCTAssertTrue(settings.managedSetupError?.contains("provenance") == true)
    }

    func testDirectForcedFieldsAreLockedAndMalformedValuesBlock() {
        var forced: Set<String> = [AgentSettings.managedSetupKey, "userEmail", "captureScreenshots"]
        let (settings, defaults) = settings(forced: { forced.contains($0) })
        defaults.set(["version": 1, "requireEnrollment": true, "requireReview": true], forKey: AgentSettings.managedSetupKey)
        settings.userEmail = "must-not-overwrite@example.invalid"
        XCTAssertEqual(settings.userEmail, "test@example.invalid")
        for invalid: Any in [true, "false", 0, 1] {
            defaults.set(invalid, forKey: "captureScreenshots")
            XCTAssertNotNil(settings.managedSetupError)
        }
        defaults.set(false, forKey: "captureScreenshots")
        XCTAssertNil(settings.managedSetupError)
        for value: Any in ["malformed", true, 7, ["unknown": "value"]] {
            defaults.set(value, forKey: AgentSettings.managedSetupKey)
            XCTAssertNotNil(settings.managedSetupError)
        }
        forced.remove(AgentSettings.managedSetupKey)
        defaults.removeObject(forKey: AgentSettings.managedSetupKey)
        XCTAssertNotNil(settings.managedSetupError, "orphaned forced keys never become unmanaged")
    }

    func testConfigChangeRevokesPendingStartBeforeAwaitAndPreservesPause() async throws {
        let (settings, _) = settings()
        settings.setupLocalOnly = true
        settings.continuousCapture = true
        let root = try root()
        let setup = CaptureSetup(settings: settings, root: root, durability: durability,
            enrollment: { self.local }, permissions: { _ in true })
        let intent = CaptureStartIntent(root: root, continuous: true, durability: durability)
        intent.completeRecovery(succeeded: true)
        let environment = CaptureSourceEnvironment(consoleSession: { true })
        environment.onRevocation = { _ = intent.beginShutdown() }
        setup.readiness.onRevocation = { environment.revoke() }
        setup.observe()
        XCTAssertTrue(setup.readiness.acknowledge())
        XCTAssertTrue(setup.readiness.admit()) // requestStart's actual pre-claim readiness seam
        XCTAssertTrue(environment.acknowledgeCurrentUser())
        let token = try XCTUnwrap(intent.requestStart(explicit: true))
        let gate = Gate()
        var enabled = false
        var aborted = false
        let task = Task {
            await intent.runStart(token, recovery: { true }, prepare: { await gate.wait(); return true }, enable: {
                guard setup.readiness.permitsAdmission(), environment.permitsCapture else { return false }
                enabled = true
                return true
            }, abort: { aborted = true })
        }
        while !(await gate.waiting) { await Task.yield() }
        settings.userEmail = "changed@example.invalid"
        XCTAssertFalse(intent.permitsStart(token), "synchronous mutation observer, before releasing prepare")
        XCTAssertFalse(environment.permitsCapture)
        XCTAssertFalse(intent.userPaused, "setup change is not invented Pause")
        await gate.release()
        let started = await task.value
        XCTAssertFalse(started)
        XCTAssertFalse(enabled)
        XCTAssertTrue(aborted)
        intent.pause()
        XCTAssertTrue(setup.readiness.acknowledge())
        XCTAssertTrue(intent.userPaused)
        XCTAssertNil(intent.requestStart(explicit: false))
        XCTAssertTrue(CaptureStartIntent(root: root, continuous: true, durability: durability).userPaused)
    }

    func testPostAwaitTrustAndManagedRefreshRejectsEvenWithoutPreferenceNotification() async throws {
        let (settings, _) = settings()
        var enrollment = CaptureSetupEnrollment(route: nil, profile: "accepted test evidence", present: true, usable: true)
        let setup = CaptureSetup(settings: settings, root: try root(), durability: durability,
            enrollment: { enrollment }, permissions: { _ in true })
        let intent = CaptureStartIntent(root: try root(), continuous: false, durability: durability)
        intent.completeRecovery(succeeded: true)
        setup.readiness.onRevocation = { _ = intent.beginShutdown() }
        XCTAssertTrue(setup.readiness.acknowledge())
        XCTAssertTrue(setup.readiness.admit())
        let token = try XCTUnwrap(intent.requestStart(explicit: true))
        var enabled = false
        var aborted = false
        let started = await intent.runStart(token, recovery: { true }, prepare: {
            await Task.yield()
            enrollment.usable = false
            enrollment.profile = "expired"
            return true
        }, enable: {
            guard setup.readiness.permitsAdmission() else { return false }
            enabled = true
            return true
        }, abort: { aborted = true })
        XCTAssertFalse(started)
        XCTAssertFalse(enabled)
        XCTAssertTrue(aborted)
    }

    func testSameAuthorityCredentialRenewalPreservesAdmissionAndNotice() throws {
        let (settings, _) = settings()
        let (envelope, accepted, trust) = try signed()
        let old = envelope.enrollmentRouting
        settings.kbcProjectId = old.projectId
        settings.kbcStackURL = old.stackURL
        settings.archiveEnrollmentRouting = old
        let enrollment = CaptureSetupEnrollment.resolve(pending: false, envelope: envelope,
            accepted: accepted, trust: trust, projectedRoute: settings.archiveUploadRouteBinding,
            routingPresent: true, mvpCredentialPresent: false, mvpExpiry: nil, now: now)
        let setup = CaptureSetup(settings: settings, root: try root(), durability: durability,
            enrollment: { enrollment }, permissions: { _ in true })
        setup.observe()
        XCTAssertTrue(setup.readiness.acknowledge())
        XCTAssertTrue(setup.readiness.admit())
        let receipt = setup.readiness.status().acknowledgedAt
        var revoked = 0
        setup.readiness.onRevocation = { revoked += 1 }
        // This is DeviceTokenRenewer's existing settings projection write after atomic renewal.
        settings.archiveEnrollmentRouting = JazzArchiveEnrollmentRouting(projectId: old.projectId,
            stackURL: old.stackURL, scope: old.scope, archiveIngestURL: old.archiveIngestURL,
            tokenId: "synthetic-renewed-id", expiresAt: Timestamps.iso8601(now.addingTimeInterval(3600)),
            signedAuthority: old.signedAuthority, authorizationProfile: old.authorizationProfile)
        XCTAssertTrue(setup.readiness.permitsAdmission())
        XCTAssertEqual(setup.readiness.status().acknowledgedAt, receipt)
        XCTAssertEqual(revoked, 0)
    }

    func testEnrollmentTransitionBlocksAdmissionWithoutClearingReceiptOrPause() throws {
        let (settings, _) = settings()
        settings.setupLocalOnly = true
        let setup = CaptureSetup(settings: settings, root: try root(), durability: durability,
            enrollment: { self.local }, permissions: { _ in true })
        setup.observe()
        XCTAssertTrue(setup.readiness.acknowledge())
        XCTAssertTrue(setup.readiness.admit())
        settings.beginEnrollmentTransition()
        XCTAssertFalse(setup.readiness.admit())
        XCTAssertFalse(setup.readiness.permitsAdmission())
        settings.endEnrollmentTransition()
        XCTAssertTrue(setup.readiness.status().ready, "failed attempted enrollment did not change actual identity")
        XCTAssertFalse(setup.readiness.permitsAdmission(), "return from connection work is not new Start")
    }
}
