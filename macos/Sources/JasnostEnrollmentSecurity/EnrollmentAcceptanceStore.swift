import Darwin
import Foundation
import JasnostCaptureCore

public enum EnrollmentAcceptanceDecision: String, Codable, Equatable, Sendable {
    /// Used only between signature verification and durable replay admission.
    case pending
    case first
    case advanced
    case idempotent
}

public struct EnrollmentAcceptanceRecord: Codable, Equatable, Sendable {
    public let deviceId: String
    public let generation: Int
    public let bundleId: String
    public let envelopeDigest: String
    public let acceptedAt: String
}

public protocol EnrollmentAcceptanceStoring: Sendable {
    func authorizeAndRecord(
        deviceId: String,
        generation: Int,
        bundleId: String,
        envelopeDigest: String,
        acceptedAt: Date
    ) throws -> EnrollmentAcceptanceDecision
}

/// One atomically replaced, non-secret ledger keyed by enrolled device id.
///
/// Admission is intentionally persisted before the token-bearing closure runs. If the network is
/// offline or the app crashes afterwards, the byte-identical envelope remains idempotently
/// retryable; a different envelope at the same/lower generation cannot exploit that failure window.
public final class FileEnrollmentAcceptanceStore: EnrollmentAcceptanceStoring, @unchecked Sendable {
    private struct BundleIdentityRecord: Codable, Equatable {
        let deviceId: String
        let generation: Int
        let envelopeDigest: String
    }

    private struct Ledger: Codable, Equatable {
        let schemaVersion: Int
        var devices: [String: EnrollmentAcceptanceRecord]
        var bundles: [String: BundleIdentityRecord]

        static let empty = Ledger(schemaVersion: 2, devices: [:], bundles: [:])
    }

    private static let maximumGeneration = 9_007_199_254_740_991
    private static let deviceIDPattern = try! NSRegularExpression(
        pattern: "^[a-z0-9][a-z0-9-]{0,63}$")
    private static let bundleIDPattern = try! NSRegularExpression(
        pattern: "^jdb_[a-f0-9]{32}$")
    private static let digestPattern = try! NSRegularExpression(
        pattern: "^[a-f0-9]{64}$")

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// A separate, stable inode is required because persisting the ledger atomically replaces
    /// ``fileURL``. Every process that uses the same ledger therefore coordinates on this sidecar.
    static func lockFileURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("lock")
    }

    public static func production() -> FileEnrollmentAcceptanceStore? {
        guard
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }
        return FileEnrollmentAcceptanceStore(
            fileURL: applicationSupport
                .appendingPathComponent("Jazz Capture", isDirectory: true)
                .appendingPathComponent("Security", isDirectory: true)
                .appendingPathComponent("signed-enrollment-acceptance-v2.json"))
    }

    public func authorizeAndRecord(
        deviceId: String,
        generation: Int,
        bundleId: String,
        envelopeDigest: String,
        acceptedAt: Date
    ) throws -> EnrollmentAcceptanceDecision {
        lock.lock()
        defer { lock.unlock() }

        guard
            Self.matches(deviceId, pattern: Self.deviceIDPattern),
            (1...Self.maximumGeneration).contains(generation),
            Self.matches(bundleId, pattern: Self.bundleIDPattern),
            Self.matches(envelopeDigest, pattern: Self.digestPattern),
            acceptedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw SignedEnrollmentError.invalidPayload
        }

        return try withExclusiveFileLock {
            var ledger = try load()
            let prior = ledger.devices[deviceId]
            let priorIdentity = ledger.bundles[bundleId]

            if let priorIdentity {
                guard
                    priorIdentity.deviceId == deviceId,
                    priorIdentity.generation == generation,
                    priorIdentity.envelopeDigest == envelopeDigest
                else {
                    throw SignedEnrollmentError.collision
                }
            }

            if let prior {
                if generation < prior.generation {
                    throw SignedEnrollmentError.rollback
                }
                if generation == prior.generation {
                    guard
                        bundleId == prior.bundleId,
                        envelopeDigest == prior.envelopeDigest
                    else {
                        throw SignedEnrollmentError.collision
                    }
                    return .idempotent
                }
                if priorIdentity != nil {
                    throw SignedEnrollmentError.collision
                }
            } else if priorIdentity != nil {
                // A globally known bundle can never become the first enrollment of another device,
                // nor can a ledger lose its owning device's latest record and continue permissively.
                throw SignedEnrollmentError.collision
            }

            let decision: EnrollmentAcceptanceDecision = prior == nil ? .first : .advanced
            ledger.devices[deviceId] = EnrollmentAcceptanceRecord(
                deviceId: deviceId,
                generation: generation,
                bundleId: bundleId,
                envelopeDigest: envelopeDigest,
                acceptedAt: Timestamps.iso8601(acceptedAt))
            ledger.bundles[bundleId] = BundleIdentityRecord(
                deviceId: deviceId,
                generation: generation,
                envelopeDigest: envelopeDigest)
            try persist(ledger)
            return decision
        }
    }

    public func records() throws -> [String: EnrollmentAcceptanceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return try withExclusiveFileLock {
            try load().devices
        }
    }

    private func withExclusiveFileLock<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        guard fileURL.isFileURL else {
            throw SignedEnrollmentError.acceptanceStateUnavailable
        }

        let lockURL = Self.lockFileURL(for: fileURL)
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            throw SignedEnrollmentError.acceptanceStateUnavailable
        }

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SignedEnrollmentError.acceptanceStateUnavailable
        }
        guard Self.changeFileLock(descriptor, operation: LOCK_EX) else {
            _ = Darwin.close(descriptor)
            throw SignedEnrollmentError.acceptanceStateUnavailable
        }

        let result: Swift.Result<Result, Error>
        do {
            result = .success(try operation())
        } catch {
            result = .failure(error)
        }

        let didUnlock = Self.changeFileLock(descriptor, operation: LOCK_UN)
        let didClose = Darwin.close(descriptor) == 0
        guard didUnlock, didClose else {
            // The operation may already have committed. Returning an availability error is still
            // fail-closed; a retry will observe the committed record as idempotent.
            throw SignedEnrollmentError.acceptanceStateUnavailable
        }
        return try result.get()
    }

    private static func changeFileLock(
        _ descriptor: Int32,
        operation: Int32
    ) -> Bool {
        // Darwin also imports `struct flock`; the explicit function type disambiguates flock(2).
        let apply: (Int32, Int32) -> Int32 = flock
        while apply(descriptor, operation) != 0 {
            guard errno == EINTR else {
                return false
            }
        }
        return true
    }

    private func load() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard StrictJSON.hasUniqueObjectKeys(data) else {
                throw SignedEnrollmentError.acceptanceStateUnavailable
            }
            let ledger = try JSONDecoder().decode(Ledger.self, from: data)
            guard
                ledger.schemaVersion == 2,
                ledger.devices.allSatisfy({
                    Self.isValidDeviceEntry($0.key, $0.value)
                }),
                ledger.bundles.allSatisfy({
                    Self.isValidBundleEntry($0.key, $0.value)
                }),
                ledger.devices.allSatisfy({ _, record in
                    ledger.bundles[record.bundleId]
                        == BundleIdentityRecord(
                            deviceId: record.deviceId,
                            generation: record.generation,
                            envelopeDigest: record.envelopeDigest)
                }),
                ledger.bundles.allSatisfy({ bundleID, identity in
                    guard let latest = ledger.devices[identity.deviceId] else {
                        return false
                    }
                    return identity.generation < latest.generation
                        || (
                            identity.generation == latest.generation
                                && latest.bundleId == bundleID
                                && latest.envelopeDigest == identity.envelopeDigest
                        )
                })
            else {
                throw SignedEnrollmentError.acceptanceStateUnavailable
            }
            return ledger
        } catch let error as SignedEnrollmentError {
            throw error
        } catch {
            throw SignedEnrollmentError.acceptanceStateUnavailable
        }
    }

    private static func isValidDeviceEntry(
        _ deviceID: String,
        _ record: EnrollmentAcceptanceRecord
    ) -> Bool {
        deviceID == record.deviceId
            && matches(deviceID, pattern: deviceIDPattern)
            && (1...maximumGeneration).contains(record.generation)
            && matches(record.bundleId, pattern: bundleIDPattern)
            && matches(record.envelopeDigest, pattern: digestPattern)
            && Timestamps.parse(record.acceptedAt) != nil
    }

    private static func isValidBundleEntry(
        _ bundleID: String,
        _ record: BundleIdentityRecord
    ) -> Bool {
        matches(bundleID, pattern: bundleIDPattern)
            && matches(record.deviceId, pattern: deviceIDPattern)
            && (1...maximumGeneration).contains(record.generation)
            && matches(record.envelopeDigest, pattern: digestPattern)
    }

    private static func matches(_ value: String, pattern: NSRegularExpression) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return pattern.firstMatch(in: value, range: range)?.range == range
    }

    private func persist(_ ledger: Ledger) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(ledger)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw SignedEnrollmentError.acceptanceStateUnavailable
        }
    }
}

/// Production gate: signature/time/scope verification and durable replay admission happen before
/// ``operation`` can observe the token-bearing bundle.
public struct SignedEnrollmentImporter: Sendable {
    private let verifier: SignedEnrollmentVerifier?
    private let acceptanceStore: (any EnrollmentAcceptanceStoring)?

    public init(
        trustPolicy: EnrollmentTrustPolicy?,
        acceptanceStore: (any EnrollmentAcceptanceStoring)?
    ) {
        verifier = trustPolicy.map(SignedEnrollmentVerifier.init(trustPolicy:))
        self.acceptanceStore = acceptanceStore
    }

    public static func production() -> SignedEnrollmentImporter {
        SignedEnrollmentImporter(
            trustPolicy: EnrollmentTrustBootstrap.load(),
            acceptanceStore: FileEnrollmentAcceptanceStore.production())
    }

    public func authorize(
        _ text: String,
        now: Date = Date()
    ) throws -> AuthorizedSignedDeviceBundle {
        guard let verifier else {
            throw SignedEnrollmentError.trustUnavailable
        }
        guard let acceptanceStore else {
            throw SignedEnrollmentError.acceptanceStateUnavailable
        }
        let verified = try verifier.verify(text, now: now)
        let decision = try acceptanceStore.authorizeAndRecord(
            deviceId: verified.payload.deviceId,
            generation: verified.payload.generation,
            bundleId: verified.payload.bundleId,
            envelopeDigest: verified.envelopeDigest,
            acceptedAt: now)
        return AuthorizedSignedDeviceBundle(
            payload: verified.payload,
            envelopeDigest: verified.envelopeDigest,
            acceptance: decision)
    }

    public func authorizeThen<Result>(
        _ text: String,
        now: Date = Date(),
        operation: (AuthorizedSignedDeviceBundle) async throws -> Result
    ) async throws -> (AuthorizedSignedDeviceBundle, Result) {
        let authorized = try authorize(text, now: now)
        let result = try await operation(authorized)
        return (authorized, result)
    }
}
