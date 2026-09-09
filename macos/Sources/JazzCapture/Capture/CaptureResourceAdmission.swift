import Foundation
import JazzCaptureCore

/// The controller's resource admission/suspension seam. Every check probes afresh (no cached
/// success). Failure is latched until an explicit Start/Resume retries; capacity recovery alone
/// never clears the OS acknowledgment gate or persisted user Pause.
@MainActor
final class CaptureResourceAdmission {
    typealias CapacityProvider = (URL) throws -> CaptureDiskReserve.Sample
    private let reserveSetting: () -> String
    private let capacity: CapacityProvider
    private let uptime: () -> TimeInterval
    private let environment: CaptureSourceEnvironment
    private(set) var failure: String?
    var onFailure: ((String) -> Void)?

    init(
        environment: CaptureSourceEnvironment,
        reserveSetting: @escaping () -> String,
        capacity: @escaping CapacityProvider = CaptureVolumeCapacity.sample,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.environment = environment
        self.reserveSetting = reserveSetting
        self.capacity = capacity
        self.uptime = uptime
    }

    static func storagePaths(
        archiveRoot: URL, spoolRoot: URL,
        deliveryPolicy: JazzCaptureDeliveryPolicy, captureCoachLive: Bool
    ) -> [URL] {
        var paths = [archiveRoot, spoolRoot]
        if deliveryPolicy.usesLiveCompatibilityProjection {
            paths += ["journal", "shots", "narration", "archive-artifact-delivery"].map {
                spoolRoot.appendingPathComponent($0, isDirectory: true)
            }
        }
        if captureCoachLive {
            paths.append(spoolRoot.appendingPathComponent("capture-coach-live", isDirectory: true))
        }
        return paths
    }

    /// Producers already own these bytes/claims. Pressure fences NEW capture, not local drain:
    /// pass the original outcome to the journal so its durability/gap/recovery rules still run.
    /// Claimed media already consumes capacity; ingestion needs one additional file copy.
    func preservingAdmittedOutcome(
        _ outcome: CaptureJournalActivityOutcome, paths: [URL]
    ) -> CaptureJournalActivityOutcome {
        if case .observation(let observation) = outcome, let artifact = observation.artifact {
            let size: Int64
            switch artifact.payload {
            case .bytes(let data): size = Int64(data.count)
            case .claimedFile(let claim): size = claim.byteLength
            }
            check(paths: paths, immediateWriteBytes: size)
        }
        return outcome
    }

    @discardableResult
    func check(paths: [URL], immediateWriteBytes: Int64 = 0, explicitRetry: Bool = false) -> Bool {
        if failure != nil && !explicitRetry { return false }
        do {
            let reserve = try CaptureDiskReserve(setting: reserveSetting())
            guard !paths.isEmpty else { throw CaptureDiskReserve.Failure.unknownCapacity }
            // Check all destinations, including symlinked archive/spool roots. No inventory,
            // digest scan, purgeable-space credit or summing free bytes across volumes.
            let samples = try paths.map { try capacity($0) }
            let now = uptime()
            for sample in samples {
                try reserve.validate(sample, nowUptime: now, immediateWriteBytes: immediateWriteBytes)
            }
            failure = nil
            return true
        } catch {
            failure = "Disk safety: \(error)"
            onFailure?(failure!)
            environment.revoke() // Same synchronous physical fences and bounded local close as OS loss.
            return false
        }
    }
}

/// Executable-only native volume API. Ask for currently available bytes, not the larger
/// "important usage" estimate that can include space the OS might purge later.
enum CaptureVolumeCapacity {
    static func sample(at destination: URL) throws -> CaptureDiskReserve.Sample {
        guard destination.isFileURL else { throw CaptureDiskReserve.Failure.unknownCapacity }
        let started = ProcessInfo.processInfo.systemUptime
        var existing = destination.standardizedFileURL
        // A not-yet-created archive uses its nearest existing parent on the actual destination
        // volume. Permission/I/O errors and dangling links are not "missing parent" fallbacks.
        while true {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: existing.path)
                break
            } catch let error as NSError {
                guard error.domain == NSCocoaErrorDomain,
                    [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code),
                    existing.path != "/" else { throw error }
                existing.deleteLastPathComponent()
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: existing.path, isDirectory: &isDirectory),
            isDirectory.boolValue else { throw CaptureDiskReserve.Failure.unknownCapacity }
        // Probe the TARGET volume of symlinked roots, not the volume storing the link itself.
        // A fresh URL plus explicit cache removal prevents Foundation resource-value reuse.
        var url = URL(fileURLWithPath: existing.resolvingSymlinksInPath().path)
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return CaptureDiskReserve.Sample(
            availableBytes: values.volumeAvailableCapacity.flatMap { Int64(exactly: $0) },
            sampledAtUptime: started)
    }
}
