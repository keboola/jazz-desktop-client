import Foundation

/// Admission headroom, not an OS reservation or a production-qualified operating threshold.
/// Close/recovery must still attempt durability and report ENOSPC; this policy never deletes data.
public struct CaptureDiskReserve: Sendable {
    public static let initialReserveBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let maximumSampleAge: TimeInterval = 3
    public let bytes: Int64

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidReserve, invalidWriteSize, unknownCapacity, invalidCapacity, staleCapacity
        case insufficient(available: Int64, required: Int64)

        public var description: String {
            switch self {
            case .invalidReserve: return "Invalid local disk reserve; enter positive whole bytes in Settings"
            case .invalidWriteSize: return "Invalid or overflowing immediate disk write size"
            case .unknownCapacity: return "Local volume available capacity is unavailable"
            case .invalidCapacity: return "Local volume returned invalid available capacity"
            case .staleCapacity: return "Local volume capacity sample is stale or invalid"
            case .insufficient(let available, let required):
                return "Low local disk capacity: \(available) bytes available; \(required) bytes required including reserve"
            }
        }
    }

    /// Strict decimal text is also the UserDefaults/UI trust boundary. Never coerce malformed
    /// values (including zero, signs, floating-point or overflow) into a smaller reserve/default.
    public init(setting: String) throws {
        guard !setting.isEmpty, setting.utf8.allSatisfy({ (48...57).contains($0) }),
            let bytes = Int64(setting), bytes > 0 else { throw Failure.invalidReserve }
        self.bytes = bytes
    }

    public struct Sample: Sendable {
        public let availableBytes: Int64?
        public let sampledAtUptime: TimeInterval
        public init(availableBytes: Int64?, sampledAtUptime: TimeInterval) {
            self.availableBytes = availableBytes
            self.sampledAtUptime = sampledAtUptime
        }
    }

    public func validate(_ sample: Sample, nowUptime: TimeInterval, immediateWriteBytes: Int64 = 0) throws {
        guard immediateWriteBytes >= 0 else { throw Failure.invalidWriteSize }
        let (required, overflow) = bytes.addingReportingOverflow(immediateWriteBytes)
        guard !overflow else { throw Failure.invalidWriteSize }
        guard let available = sample.availableBytes else { throw Failure.unknownCapacity }
        guard available >= 0 else { throw Failure.invalidCapacity }
        let age = nowUptime - sample.sampledAtUptime
        guard nowUptime.isFinite, sample.sampledAtUptime.isFinite, sample.sampledAtUptime >= 0,
            age.isFinite, age >= 0, age <= Self.maximumSampleAge else { throw Failure.staleCapacity }
        guard available >= required else { throw Failure.insufficient(available: available, required: required) }
    }
}
