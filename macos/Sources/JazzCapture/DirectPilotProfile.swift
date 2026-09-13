import AppKit
import CryptoKit
import IOKit
import JazzCaptureCore
import JazzEnrollmentSecurity

/// Selected before any legacy owner is constructed. No environment flag can repurpose the installed app.
enum DirectPilotProfile {
    static let bundleID = "dev.jazz.capture.direct-pilot"
    static var enabled: Bool { Bundle.main.bundleIdentifier == bundleID }
    static let credentialAccount = "direct-pilot-signed-bundle-v1"
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jazz-direct-pilot")
    }
    static func hostDigest() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { return nil }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func check() throws -> (device: String, source: String, apps: Set<String>) {
        let info = Bundle.main.infoDictionary ?? [:]
        guard enabled, let host = hostDigest(), info["JazzPilotHostSHA256"] as? String == host,
            let device = info["JazzPilotDeviceID"] as? String, device.hasPrefix("jazz-qual-"),
            let source = info["JazzPilotSourceID"] as? String, source.hasPrefix("jazz-qual-"),
            let apps = info["JazzPilotAllowedApps"] as? [String], !apps.isEmpty, apps.count <= 8,
            apps.allSatisfy({ !$0.isEmpty && !$0.contains("*") }),
            EnrollmentTrustBootstrap.load() != nil
        else { throw JazzBestEffortContract.Failure.authority }
        if FileManager.default.fileExists(atPath: root.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else {
                throw JazzBestEffortContract.Failure.authority
            }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        return (device, source, Set(apps))
    }
}
