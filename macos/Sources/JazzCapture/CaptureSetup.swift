import Foundation
import JazzCaptureCore
import JazzEnrollmentSecurity

/// Non-secret projection of EXISTING enrollment acceptance. This never calls a network endpoint
/// or authenticates a preference tuple. Device-bound activation provenance is not in older vaults.
struct CaptureSetupEnrollment {
    var route: JazzArchiveUploadRouteBinding?
    var profile: String
    var present: Bool
    var usable: Bool
    var evidenceUnavailable = false

    static func resolve(pending: Bool, envelope: JazzSignedDeviceCredentialEnvelope?,
        accepted: EnrollmentAcceptanceRecord?, trust: EnrollmentTrustPolicy?,
        projectedRoute: JazzArchiveUploadRouteBinding?, routingPresent: Bool,
        mvpCredentialPresent: Bool, mvpExpiry: Date?, now: Date) -> Self
    {
        if pending { return .init(route: nil, profile: "Pending device enrollment — resume import", present: true, usable: false) }
        if let envelope {
            let route = envelope.routeBinding
            guard let authority = route.signedAuthority, let accepted,
                accepted.deviceId == route.scope.deviceId,
                accepted.bundleId == authority.bundleId, accepted.generation == authority.generation,
                accepted.envelopeDigest == authority.envelopeDigest,
                trust?.issuer == authority.issuer, trust?.audience == authority.audience
            else { return .init(route: route, profile: "Unverified signed enrollment — restore trust/acceptance evidence and reconnect", present: true, usable: false) }
            guard let expiry = Timestamps.parse(envelope.expiresAt), expiry > now else {
                return .init(route: route, profile: "Expired signed enrollment — renew or re-enroll", present: true, usable: false)
            }
            guard let projectedRoute, route.hasSameDeliveryAuthority(as: projectedRoute) else {
                return .init(route: route, profile: "Enrollment/settings route mismatch — reconnect to repair projections", present: true, usable: false)
            }
            return .init(route: route,
                profile: "Signed enrollment accepted; production device-bound activation provenance not recorded",
                present: true, usable: true)
        }
        if let route = projectedRoute, route.hasMVPAdminHandoffAuthority, mvpCredentialPresent {
            let valid = mvpExpiry.map { $0 > now } == true
            return .init(route: route,
                profile: valid ? "MVP administrator handoff; credential stored — NOT cryptographically verified or production device-bound"
                    : "Expired/invalid MVP credential — import a new administrator handoff",
                present: true, usable: valid)
        }
        return .init(route: projectedRoute, profile: routingPresent ? "Unverified enrollment preferences — import enrollment" : "Unassigned — no enrollment",
            present: routingPresent, usable: false)
    }

    var identity: String { route.map(Self.identity) ?? "" }

    static func identity(_ route: JazzArchiveUploadRouteBinding) -> String {
        // Token/bundle renewal under identical authority is not a new modality/destination notice.
        return [route.signedAuthority?.issuer ?? "", route.signedAuthority?.audience ?? "",
            route.stackURL, route.projectId, route.scope.companyId, route.scope.areaId,
            route.scope.deviceId, route.ingestEndpoint].joined(separator: "\n")
    }

    @MainActor static func current(settings: AgentSettings,
        readPending: () throws -> Bool = { try Keychain.exists(account: Keychain.Account.pendingDeviceEnrollment) },
        readEnvelope: () throws -> JazzSignedDeviceCredentialEnvelope? = { try SignedDeviceCredentialKeychain.vault.envelope() },
        readAcceptance: (String) throws -> EnrollmentAcceptanceRecord? = { deviceID in
            guard let store = FileEnrollmentAcceptanceStore.production() else { throw CocoaError(.fileReadUnknown) }
            return try store.records()[deviceID]
        },
        loadTrust: () -> EnrollmentTrustPolicy? = { EnrollmentTrustBootstrap.load() },
        readMVPCredential: () throws -> Bool = { try Keychain.exists(account: Keychain.Account.kbcToken) },
        hasDeviceBoundActivation: ((String) -> Bool)? = nil) -> Self
    {
        // Read failure is unknown, not observed enrollment. Keep positive observations made
        // before a later failure; the readiness store separately retains historical requirements.
        var present = settings.hasStoredEnrollmentRouting
        do {
            let pending = try readPending()
            if pending { return resolve(pending: true, envelope: nil, accepted: nil, trust: nil,
                projectedRoute: nil, routingPresent: true, mvpCredentialPresent: false, mvpExpiry: nil, now: Date()) }
            let envelope = try readEnvelope()
            present = present || envelope != nil
            let accepted: EnrollmentAcceptanceRecord?
            if let envelope {
                accepted = try readAcceptance(envelope.routeBinding.scope.deviceId)
            } else { accepted = nil }
            var result = resolve(pending: false, envelope: envelope, accepted: accepted,
                trust: loadTrust(), projectedRoute: settings.archiveUploadRouteBinding,
                routingPresent: settings.hasStoredEnrollmentRouting,
                mvpCredentialPresent: try envelope == nil && readMVPCredential(),
                mvpExpiry: settings.archiveEnrollmentRouting?.expiresAtDate, now: Date())
            if envelope != nil, result.usable,
                (hasDeviceBoundActivation?(result.identity)
                    ?? CaptureSetup.shared.readiness.hasDeviceBoundActivation(identity: result.identity)) {
                result.profile = "Production device-bound redemption recorded locally; signed enrollment acceptance matched (not native qualification)"
            }
            return result
        } catch {
            return .init(route: nil, profile: "Enrollment evidence unavailable/corrupt — restore access and retry", present: present,
                usable: false, evidenceUnavailable: true)
        }
    }
}

/// Single Settings/first-run/admission adapter. Tests supply settings, trust, permissions and
/// storage; construction does not open recording sources or register OS observers.
@MainActor
final class CaptureSetup {
    static let shared = CaptureSetup(settings: .shared,
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jazz/spool"),
        durability: JazzArchiveFilesystemPlatform.durability,
        enrollment: { CaptureSetupEnrollment.current(settings: .shared) },
        permissions: { permission in Permissions.status(permission) == .granted })

    let readiness: CaptureSetupReadiness
    private var observers: [NSObjectProtocol] = []

    init(settings: AgentSettings, root: URL, durability: JazzArchiveFilesystemDurability,
        enrollment: @escaping () -> CaptureSetupEnrollment,
        permissions: @escaping (Permission) -> Bool)
    {
        readiness = CaptureSetupReadiness(root: root, durability: durability, input: {
            Self.input(settings: settings, enrollment: enrollment(), permissions: permissions)
        })
    }

    static func input(settings: AgentSettings, enrollment: CaptureSetupEnrollment,
        permissions: (Permission) -> Bool) -> CaptureSetupInput
    {
        let route = enrollment.route
        let area = JazzArchiveCaptureBinding(uploadScope: settings.archiveUploadScope,
            selectedAreaId: settings.lastAreaId, selectedAreaName: settings.lastAreaName)
        let snapshot = CaptureSetupSnapshot(user: settings.userEmail, machine: settings.instanceName,
            company: enrollment.evidenceUnavailable ? "Unknown — enrollment evidence unavailable"
                : route?.scope.companyId ?? "Unassigned",
            area: area.area.map { "\($0.areaId) (\($0.nameSnapshot))" }
                ?? route?.scope.areaId ?? "General (local)",
            destination: enrollment.evidenceUnavailable ? "Unknown — restore enrollment evidence access"
                : route?.ingestEndpoint ?? "Local Jazz Archive only — no company destination",
            enrollmentIdentity: enrollment.identity, enrollmentProfile: enrollment.profile,
            continuous: settings.continuousCapture, screenshots: settings.captureScreenshots,
            narration: settings.captureNarration, coachLive: settings.captureCoachLive,
            delivery: settings.deliveryPolicy, localOnly: settings.setupLocalOnly,
            exclusions: Array(settings.denylist), managedConfiguration: settings.managedSetupFingerprint)
        var blockers = settings.managedSetupError.map { [$0] } ?? []
        if enrollment.evidenceUnavailable { blockers.append(enrollment.profile) }
        if settings.enrollmentTransitions > 0 {
            blockers.append("Enrollment/connection change in progress — wait for it to finish")
        }
        if settings.managedSetupPresent && settings.setupLocalOnly {
            blockers.append("Managed setup requires enrollment; local-only fallback is unavailable")
        }
        return CaptureSetupInput(snapshot: snapshot, managedPresent: settings.managedSetupPresent,
            enrollmentPresent: enrollment.present, enrollmentUsable: enrollment.usable, blockers: blockers,
            accessibilityGranted: permissions(.accessibility), screenGranted: permissions(.screenRecording),
            microphoneGranted: permissions(.microphone))
    }

    func observe() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.captureSetupWillChange, .captureSetupDidChange, UserDefaults.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == .captureSetupWillChange { self.readiness.revoke() }
                    else { _ = self.readiness.status() }
                }
            })
        }
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
