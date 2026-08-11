import Foundation

/// An exclusive, cross-process lease for the capture identity registry.
///
/// Core owns only this narrow coordination contract. Platform locking primitives stay in the
/// executable target, while tests can inject a deterministic in-memory implementation.
public protocol CaptureIdentityStoreLease: Sendable {
    func release()
}

public protocol CaptureIdentityStoreLeaseProvider: Sendable {
    func acquire(
        root: URL,
        fileManager: FileManager
    ) throws -> any CaptureIdentityStoreLease
}

public enum CaptureIdentityStoreLeaseError: Error, Equatable {
    case acquisitionFailed
}
