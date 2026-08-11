import Foundation

/// Orders downstream liveCompatibility writes by the canonical per-stream sequence, even when
/// capture producers finish out of order. Canonical persistence remains authoritative: a failed
/// projection stays pending for retry and never rolls an observation back or blocks CaptureCommit.
public actor CaptureJournalOrderedProjection {
    public typealias Projection =
        @Sendable (
            JazzArchiveRecord,
            [JazzArchiveArtifact],
            ActivityEvent?
        ) async throws -> Void

    private struct Coordinate: Hashable, Sendable {
        var streamId: String
        var streamSequence: Int
    }

    private enum Resolution: Sendable {
        case observation(
            record: JazzArchiveRecord,
            artifacts: [JazzArchiveArtifact],
            event: ActivityEvent?)
        case gap

        var identity: String {
            switch self {
            case .observation(let record, _, _):
                return record.observationId
            case .gap:
                return "gap"
            }
        }
    }

    private let projection: Projection
    private var nextSequenceByStream: [String: Int] = [:]
    private var pending: [Coordinate: Resolution] = [:]
    private var completed: [Coordinate: String] = [:]
    private var draining = false
    private var projectionFailures: [String] = []

    public init(projection: @escaping Projection) {
        self.projection = projection
    }

    /// Returns false only for a conflicting duplicate coordinate or when the current contiguous
    /// head could not be projected. A later admission or explicit retry attempts the same bytes.
    @discardableResult
    public func resolveObservation(
        _ record: JazzArchiveRecord,
        artifacts: [JazzArchiveArtifact] = [],
        event: ActivityEvent? = nil
    ) async -> Bool {
        let coordinate = Coordinate(
            streamId: record.streamId,
            streamSequence: record.streamSequence)
        let resolution = Resolution.observation(
            record: record,
            artifacts: artifacts,
            event: event)
        guard admit(resolution, at: coordinate) else { return false }
        return await drain()
    }

    @discardableResult
    public func resolveGap(
        streamId: String,
        streamSequence: Int
    ) async -> Bool {
        let coordinate = Coordinate(
            streamId: streamId,
            streamSequence: streamSequence)
        guard admit(.gap, at: coordinate) else { return false }
        return await drain()
    }

    @discardableResult
    public func retryPending() async -> Bool {
        await drain()
    }

    public func pendingResolutionCount() -> Int {
        pending.count
    }

    public func recordedProjectionFailures() -> [String] {
        projectionFailures
    }

    private func admit(
        _ resolution: Resolution,
        at coordinate: Coordinate
    ) -> Bool {
        guard coordinate.streamSequence >= 0 else { return false }
        if let identity = completed[coordinate] {
            return identity == resolution.identity
        }
        if let existing = pending[coordinate] {
            return existing.identity == resolution.identity
        }
        let next = nextSequenceByStream[coordinate.streamId, default: 0]
        guard coordinate.streamSequence >= next else { return false }
        pending[coordinate] = resolution
        return true
    }

    private func drain() async -> Bool {
        guard !draining else { return true }
        draining = true
        defer { draining = false }
        var allProjected = true

        while true {
            let ready = nextReadyCoordinate()
            guard let ready, let resolution = pending[ready] else { break }
            switch resolution {
            case .gap:
                complete(resolution, at: ready)
            case .observation(let record, let artifacts, let event):
                do {
                    try await projection(record, artifacts, event)
                    complete(resolution, at: ready)
                } catch {
                    projectionFailures.append(record.observationId)
                    allProjected = false
                    return allProjected
                }
            }
        }
        return allProjected
    }

    private func nextReadyCoordinate() -> Coordinate? {
        pending.keys
            .filter {
                $0.streamSequence
                    == nextSequenceByStream[$0.streamId, default: 0]
            }
            .sorted {
                ($0.streamId, $0.streamSequence)
                    < ($1.streamId, $1.streamSequence)
            }
            .first
    }

    private func complete(
        _ resolution: Resolution,
        at coordinate: Coordinate
    ) {
        pending.removeValue(forKey: coordinate)
        completed[coordinate] = resolution.identity
        nextSequenceByStream[coordinate.streamId] =
            coordinate.streamSequence + 1
    }
}
