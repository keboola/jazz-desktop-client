import Foundation

/// Local setup evidence only. This is neither company authority nor archive confirmation.
public struct CaptureSetupSnapshot: Codable, Equatable, Sendable {
    public var noticeVersion = 1
    public var user: String
    public var machine: String
    public var company: String
    public var area: String
    public var destination: String
    public var enrollmentIdentity: String
    public var enrollmentProfile: String
    public var continuous: Bool
    public var screenshots: Bool
    public var narration: Bool
    public var coachLive: Bool
    public var delivery: JazzCaptureDeliveryPolicy
    public var localOnly: Bool
    public var exclusions: [String]
    public var managedConfiguration: String

    public init(user: String, machine: String, company: String, area: String,
        destination: String, enrollmentIdentity: String, enrollmentProfile: String,
        continuous: Bool, screenshots: Bool, narration: Bool, coachLive: Bool,
        delivery: JazzCaptureDeliveryPolicy, localOnly: Bool, exclusions: [String],
        managedConfiguration: String)
    {
        self.user = user; self.machine = machine; self.company = company; self.area = area
        self.destination = destination; self.enrollmentIdentity = enrollmentIdentity
        self.enrollmentProfile = enrollmentProfile; self.continuous = continuous
        self.screenshots = screenshots; self.narration = narration; self.coachLive = coachLive
        self.delivery = delivery; self.localOnly = localOnly; self.exclusions = exclusions.sorted()
        self.managedConfiguration = managedConfiguration
    }
}

public struct CaptureSetupInput: Sendable {
    public var snapshot: CaptureSetupSnapshot
    public var managedPresent: Bool
    public var enrollmentPresent: Bool
    public var enrollmentUsable: Bool
    public var blockers: [String]
    public var accessibilityGranted: Bool
    public var screenGranted: Bool
    public var microphoneGranted: Bool

    public init(snapshot: CaptureSetupSnapshot, managedPresent: Bool = false,
        enrollmentPresent: Bool = false, enrollmentUsable: Bool = false,
        blockers: [String] = [], accessibilityGranted: Bool, screenGranted: Bool,
        microphoneGranted: Bool)
    {
        self.snapshot = snapshot; self.managedPresent = managedPresent
        self.enrollmentPresent = enrollmentPresent; self.enrollmentUsable = enrollmentUsable
        self.blockers = blockers; self.accessibilityGranted = accessibilityGranted
        self.screenGranted = screenGranted; self.microphoneGranted = microphoneGranted
    }
}

public struct CaptureSetupStatus: Sendable {
    public let snapshot: CaptureSetupSnapshot
    public let blockers: [String]
    public let acknowledgedAt: Date?
    public var canAcknowledge: Bool { blockers.isEmpty }
    public var ready: Bool { canAcknowledge && acknowledgedAt != nil }
    public var summary: String {
        blockers.first ?? (ready
            ? "Setup acknowledged — review required; Start/Resume still required"
            : "Review the recording notice and acknowledge this setup in Settings")
    }
}

/// Same synchronous check is used before requestStart and after preparation, then at physical
/// admission. It owns no capture lifecycle: callers revoke their existing intent/source owner.
@MainActor
public final class CaptureSetupReadiness {
    private struct Receipt: Codable {
        let snapshot: CaptureSetupSnapshot
        let acknowledgedAt: Date
    }
    private struct Document: Codable {
        var version = 1
        var managedSeen = false
        var enrollmentSeen = false
        var receipts: [Receipt] = []
        var invalidated = false
        var deviceBoundActivations: [String] = []
        var snapshot: CaptureSetupSnapshot? { receipts.last?.snapshot }
        var acknowledgedAt: Date? { invalidated ? nil : receipts.last?.acknowledgedAt }
    }
    private var document = Document()
    private var storageFailed = false
    private let write: (Data) throws -> Void
    private let input: () -> CaptureSetupInput
    private let now: () -> Date
    public var onRevocation: (() -> Void)?
    private var admitted: CaptureSetupSnapshot?

    public init(input: @escaping () -> CaptureSetupInput, read: @escaping () throws -> Data?,
        write: @escaping (Data) throws -> Void, now: @escaping () -> Date = Date.init)
    {
        self.input = input; self.write = write; self.now = now
        do {
            if let bytes = try read() {
                document = try JSONDecoder().decode(Document.self, from: bytes)
                guard document.version == 1,
                    document.receipts.allSatisfy({ $0.acknowledgedAt.timeIntervalSinceReferenceDate.isFinite })
                else { throw CocoaError(.fileReadCorruptFile) }
            }
        } catch { storageFailed = true }
    }

    public convenience init(root: URL, durability: JazzArchiveFilesystemDurability,
        input: @escaping () -> CaptureSetupInput)
    {
        let file = root.appendingPathComponent("capture-setup.json")
        let pending = root.appendingPathComponent("capture-setup-write-pending")
        self.init(input: input, read: {
            if FileManager.default.fileExists(atPath: pending.path) { throw CocoaError(.fileReadCorruptFile) }
            do { return try Data(contentsOf: file) }
            catch CocoaError.fileReadNoSuchFile { return nil }
        }, write: { bytes in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("setup write in progress".utf8).write(to: pending, options: .atomic)
            try durability.synchronizeRegularFile(pending, permissions: 0o600)
            try durability.synchronizeDirectory(root)
            try bytes.write(to: file, options: .atomic)
            try durability.synchronizeRegularFile(file, permissions: 0o600)
            try durability.synchronizeDirectory(root)
            try durability.synchronizeDirectory(root.deletingLastPathComponent())
            do {
                try FileManager.default.removeItem(at: pending)
                try durability.synchronizeDirectory(root)
            } catch {
                // A cleanup error must not turn an uncertain write into acknowledged readiness.
                try? Data("setup write failed".utf8).write(to: pending, options: .atomic)
                throw error
            }
        })
    }

    public func hasDeviceBoundActivation(identity: String) -> Bool {
        !storageFailed && !identity.isEmpty && document.deviceBoundActivations.contains(identity)
    }

    /// Local provenance from the existing successful sealed-redemption + signed-import path.
    /// It does not replace signed credential/acceptance checks and is never company authority.
    public func recordDeviceBoundActivation(identity: String) {
        revoke()
        guard !identity.isEmpty, !document.deviceBoundActivations.contains(identity) else { return }
        document.deviceBoundActivations.append(identity)
        document.enrollmentSeen = true
        persist()
    }

    public var requiresEnrollment: Bool { document.managedSeen || document.enrollmentSeen }

    public func status() -> CaptureSetupStatus {
        let current = input()
        if !storageFailed && ((current.managedPresent && !document.managedSeen)
            || (current.enrollmentPresent && !document.enrollmentSeen))
        {
            document.managedSeen = document.managedSeen || current.managedPresent
            document.enrollmentSeen = document.enrollmentSeen || current.enrollmentPresent
            persist()
        }
        var blockers = current.blockers
        if storageFailed {
            blockers.insert("Setup storage unavailable/corrupt — repair storage and reopen; evidence retained", at: 0)
        }
        if document.managedSeen && !current.managedPresent {
            blockers.append("Managed configuration removed — ask your administrator to restore it")
        }
        let snapshot = current.snapshot
        if snapshot.localOnly {
            if document.managedSeen || document.enrollmentSeen || current.enrollmentPresent {
                blockers.append("Previously managed/enrolled installation cannot switch to unmanaged local-only setup")
            }
            if snapshot.delivery != .confirmedArchive || snapshot.coachLive {
                blockers.append("Local-only setup requires confirmed archives and Capture Coach off")
            }
        } else if !current.enrollmentUsable {
            blockers.append("Enrollment not ready — import or resume a valid enrollment in Settings; no network health result establishes trust")
        }
        if snapshot.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || snapshot.machine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        { blockers.append("Set your recording identity and machine name") }
        if !current.accessibilityGranted { blockers.append("Grant Accessibility in Permissions, then Quit & Reopen") }
        if snapshot.screenshots && !current.screenGranted { blockers.append("Grant Screen Recording or disable screenshots, then Quit & Reopen") }
        if snapshot.narration && !current.microphoneGranted { blockers.append("Grant Microphone or disable narration") }
        if let previous = document.snapshot, previous != snapshot, !document.invalidated {
            document.invalidated = true
            persist() // Reverting a material change cannot resurrect an old notice receipt.
            if storageFailed { blockers.append("Setup invalidation could not be persisted — repair storage and reopen") }
        }
        let acknowledgedAt = snapshot == document.snapshot ? document.acknowledgedAt : nil
        let status = CaptureSetupStatus(snapshot: snapshot, blockers: blockers, acknowledgedAt: acknowledgedAt)
        if let admitted, !status.ready || admitted != snapshot {
            self.admitted = nil // Revoke once, before the caller begins any awaited close.
            onRevocation?()
        }
        return status
    }

    @discardableResult
    public func acknowledge(expected: CaptureSetupSnapshot? = nil) -> Bool {
        let current = status()
        guard current.canAcknowledge, expected == nil || expected == current.snapshot else { return false }
        if current.ready { return true }
        document.receipts.append(Receipt(snapshot: current.snapshot, acknowledgedAt: now()))
        document.invalidated = false
        persist()
        return status().ready
    }

    /// Workshop admission cannot expand the modalities acknowledged in Settings.
    public func admit(workshop: Bool = false) -> Bool {
        let current = status()
        guard current.ready, !workshop || (current.snapshot.screenshots && current.snapshot.narration)
        else { return false }
        admitted = current.snapshot
        return true
    }

    public func permitsAdmission(workshop: Bool = false) -> Bool {
        let current = status()
        return current.ready && admitted == current.snapshot
            && (!workshop || (current.snapshot.screenshots && current.snapshot.narration))
    }

    /// Used for configuration/credential transitions BEFORE their first await or mutation.
    /// Does not change Pause or the receipt, and never releases delivery backlog.
    public func revoke() {
        admitted = nil
        onRevocation?()
    }

    private func persist() {
        guard !storageFailed else { return }
        do { try write(JSONEncoder().encode(document)) }
        catch { storageFailed = true }
    }
}

/// Deployment restrictions only. No key here grants a modality, company identity or upload
/// authority. Unknown fields/types are blocking, not ignored future policy versions.
public struct CaptureManagedRestrictions: Codable, Equatable, Sendable {
    public let version: Int
    public let requireEnrollment: Bool
    public let requireReview: Bool
    public let continuous: Bool?
    public let screenshots: Bool?
    public let narration: Bool?
    public let coachLive: Bool?

    public static func decode(_ data: Data) throws -> Self {
        let allowed: Set<String> = ["version", "requireEnrollment", "requireReview", "continuous", "screenshots", "narration", "coachLive"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: allowed)
        else { throw CocoaError(.fileReadCorruptFile) }
        for key in ["continuous", "screenshots", "narration", "coachLive"] {
            if object[key] is NSNull { throw CocoaError(.fileReadCorruptFile) }
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.requireEnrollment, value.requireReview,
            value.continuous != true, value.screenshots != true,
            value.narration != true, value.coachLive != true
        else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}
