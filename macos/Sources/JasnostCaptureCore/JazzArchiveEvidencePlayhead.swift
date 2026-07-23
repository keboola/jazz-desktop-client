import Foundation

public enum JazzArchiveEvidencePlaybackMode: String, Equatable, Sendable {
    case paused
    case playing
    case ended
}

/// Complete transport state for one capture-wide evidence clock. Every evidence lane observes this
/// same position; media players are views of the clock and never own an independent transport.
public struct JazzArchiveEvidencePlayheadState: Equatable, Sendable {
    public let positionMillis: Int64
    public let durationMillis: Int64
    public let mode: JazzArchiveEvidencePlaybackMode
    public let selectedEntryId: String?
    public let activeEntryIds: [String]

    public var isPlaying: Bool { mode == .playing }
}

public enum JazzArchiveEvidencePlayheadError: Error, Equatable {
    case invalidTimeline
    case unknownEntry(String)
    case negativeElapsed
}

/// Pure deterministic state machine for read-only evidence playback. The caller supplies elapsed
/// monotonic time; this type owns no timer, wall clock, media framework, capture API, or network.
public struct JazzArchiveEvidencePlayhead: Equatable, Sendable {
    private let entries: [JazzArchiveEvidencePlaybackEntry]
    public private(set) var state: JazzArchiveEvidencePlayheadState

    public init(snapshot: JazzArchiveEvidencePlaybackSnapshot) throws {
        guard snapshot.durationMillis >= 0 else {
            throw JazzArchiveEvidencePlayheadError.invalidTimeline
        }
        try EvidencePlaybackValidator.validate(snapshot.entries.map(\.item))
        var previous: (Int64, String)?
        for entry in snapshot.entries {
            let key = (entry.item.offsetMillis, entry.id)
            if let previous,
                key.0 < previous.0 || (key.0 == previous.0 && key.1 <= previous.1)
            {
                throw JazzArchiveEvidencePlayheadError.invalidTimeline
            }
            guard entry.item.offsetMillis <= snapshot.durationMillis,
                entry.endOffsetMillis == nil
                    || (entry.endOffsetMillis! >= entry.item.offsetMillis
                        && entry.endOffsetMillis! <= snapshot.durationMillis)
            else {
                throw JazzArchiveEvidencePlayheadError.invalidTimeline
            }
            previous = key
        }
        self.entries = snapshot.entries
        self.state = JazzArchiveEvidencePlayheadState(
            positionMillis: 0,
            durationMillis: snapshot.durationMillis,
            mode: .paused,
            selectedEntryId: nil,
            activeEntryIds: [])
        refreshSelection()
    }

    public mutating func play() {
        guard state.durationMillis > 0 else {
            replace(mode: .ended)
            return
        }
        if state.positionMillis >= state.durationMillis {
            replace(positionMillis: 0, mode: .playing)
            refreshSelection()
        } else {
            replace(mode: .playing)
        }
    }

    public mutating func pause() {
        guard state.mode == .playing else { return }
        replace(mode: .paused)
    }

    public mutating func togglePlayback() {
        if state.mode == .playing {
            pause()
        } else {
            play()
        }
    }

    public mutating func seek(toMillis requested: Int64) {
        let position = min(max(0, requested), state.durationMillis)
        let mode: JazzArchiveEvidencePlaybackMode
        if position == state.durationMillis, state.durationMillis > 0 {
            mode = .ended
        } else if state.mode == .ended {
            mode = .paused
        } else {
            mode = state.mode
        }
        replace(positionMillis: position, mode: mode)
        refreshSelection()
    }

    /// Selecting any lane item is a seek on the same global playhead. A requested item wins ties
    /// at an identical timestamp until the next clock movement.
    public mutating func select(entryId: String) throws {
        guard let entry = entries.first(where: { $0.id == entryId }) else {
            throw JazzArchiveEvidencePlayheadError.unknownEntry(entryId)
        }
        let mode: JazzArchiveEvidencePlaybackMode =
            state.mode == .ended ? .paused : state.mode
        replace(positionMillis: entry.item.offsetMillis, mode: mode)
        refreshSelection(preferredEntryId: entryId)
    }

    public mutating func advance(byMillis elapsed: Int64) throws {
        guard elapsed >= 0 else {
            throw JazzArchiveEvidencePlayheadError.negativeElapsed
        }
        guard state.mode == .playing, elapsed > 0 else { return }
        let (sum, overflow) = state.positionMillis.addingReportingOverflow(elapsed)
        let position = overflow ? state.durationMillis : min(sum, state.durationMillis)
        replace(
            positionMillis: position,
            mode: position >= state.durationMillis ? .ended : .playing)
        refreshSelection()
    }

    private mutating func refreshSelection(preferredEntryId: String? = nil) {
        let position = state.positionMillis
        let selected = preferredEntryId ?? entries.last {
            $0.item.offsetMillis <= position
        }?.id
        let active = entries.compactMap { entry -> String? in
            let start = entry.item.offsetMillis
            guard let end = entry.endOffsetMillis else {
                return start == position ? entry.id : nil
            }
            if end == start {
                return position == start ? entry.id : nil
            }
            return position >= start && position < end ? entry.id : nil
        }
        state = JazzArchiveEvidencePlayheadState(
            positionMillis: position,
            durationMillis: state.durationMillis,
            mode: state.mode,
            selectedEntryId: selected,
            activeEntryIds: active)
    }

    private mutating func replace(
        positionMillis: Int64? = nil,
        mode: JazzArchiveEvidencePlaybackMode? = nil
    ) {
        state = JazzArchiveEvidencePlayheadState(
            positionMillis: positionMillis ?? state.positionMillis,
            durationMillis: state.durationMillis,
            mode: mode ?? state.mode,
            selectedEntryId: state.selectedEntryId,
            activeEntryIds: state.activeEntryIds)
    }
}
