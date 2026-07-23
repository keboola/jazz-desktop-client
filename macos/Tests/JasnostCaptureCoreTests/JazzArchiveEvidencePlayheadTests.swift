import Foundation
import XCTest

@testable import JasnostCaptureCore

final class JazzArchiveEvidencePlayheadTests: XCTestCase {
    func testOneClockSelectsEveryEvidenceLaneAndKeepsIntervalsActive() throws {
        let snapshot = makeSnapshot(entries: [
            entry("event", offset: 0, kind: .event),
            entry("label", offset: 500, end: 5_000, kind: .label),
            entry("screenshot", offset: 1_000, kind: .screenshot),
            entry("narration", offset: 1_500, end: 4_500, kind: .narration),
            entry("transcript", offset: 2_000, end: 3_000, kind: .transcript),
            entry("coach", offset: 3_500, kind: .coachInteraction),
            gap("gap", offset: 5_500),
        ], duration: 6_000)
        var playhead = try JazzArchiveEvidencePlayhead(snapshot: snapshot)

        XCTAssertEqual(playhead.state.positionMillis, 0)
        XCTAssertEqual(playhead.state.selectedEntryId, "event")
        XCTAssertEqual(playhead.state.activeEntryIds, ["event"])

        playhead.play()
        try playhead.advance(byMillis: 2_250)
        XCTAssertEqual(playhead.state.selectedEntryId, "transcript")
        XCTAssertEqual(
            playhead.state.activeEntryIds,
            ["label", "narration", "transcript"])

        try playhead.advance(byMillis: 1_500)
        XCTAssertEqual(playhead.state.selectedEntryId, "coach")
        XCTAssertEqual(playhead.state.activeEntryIds, ["label", "narration"])

        try playhead.advance(byMillis: 1_750)
        XCTAssertEqual(playhead.state.selectedEntryId, "gap")
        XCTAssertEqual(playhead.state.activeEntryIds, ["gap"])
        XCTAssertEqual(playhead.state.mode, .playing)
    }

    func testSelectIsGlobalSeekAndRequestedItemWinsEqualTimestampTie() throws {
        let snapshot = makeSnapshot(entries: [
            entry("a-event", offset: 1_000, kind: .event),
            entry("b-screenshot", offset: 1_000, kind: .screenshot),
            entry("c-transcript", offset: 1_000, kind: .transcript),
        ], duration: 2_000)
        var playhead = try JazzArchiveEvidencePlayhead(snapshot: snapshot)

        try playhead.select(entryId: "a-event")
        XCTAssertEqual(playhead.state.positionMillis, 1_000)
        XCTAssertEqual(playhead.state.selectedEntryId, "a-event")
        XCTAssertEqual(
            playhead.state.activeEntryIds,
            ["a-event", "b-screenshot", "c-transcript"])

        playhead.seek(toMillis: 1_000)
        XCTAssertEqual(playhead.state.selectedEntryId, "c-transcript")
    }

    func testPauseSeekEndAndReplayAreDeterministic() throws {
        let snapshot = makeSnapshot(entries: [
            entry("event", offset: 500, kind: .event),
        ], duration: 2_000)
        var playhead = try JazzArchiveEvidencePlayhead(snapshot: snapshot)

        playhead.play()
        try playhead.advance(byMillis: 750)
        playhead.pause()
        try playhead.advance(byMillis: 500)
        XCTAssertEqual(playhead.state.positionMillis, 750)
        XCTAssertEqual(playhead.state.mode, .paused)

        playhead.seek(toMillis: 20_000)
        XCTAssertEqual(playhead.state.positionMillis, 2_000)
        XCTAssertEqual(playhead.state.mode, .ended)

        playhead.play()
        XCTAssertEqual(playhead.state.positionMillis, 0)
        XCTAssertEqual(playhead.state.mode, .playing)
        XCTAssertNil(playhead.state.selectedEntryId)

        XCTAssertThrowsError(try playhead.advance(byMillis: -1)) {
            XCTAssertEqual(
                $0 as? JazzArchiveEvidencePlayheadError,
                .negativeElapsed)
        }
        XCTAssertThrowsError(try playhead.select(entryId: "missing")) {
            XCTAssertEqual(
                $0 as? JazzArchiveEvidencePlayheadError,
                .unknownEntry("missing"))
        }
    }

    func testRejectsInvalidRangesAndImplicitGaps() {
        let invalidRange = makeSnapshot(entries: [
            entry("bad", offset: 1_000, end: 500, kind: .narration),
        ], duration: 2_000)
        XCTAssertThrowsError(try JazzArchiveEvidencePlayhead(snapshot: invalidRange)) {
            XCTAssertEqual(
                $0 as? JazzArchiveEvidencePlayheadError,
                .invalidTimeline)
        }

        let implicitGap = JazzArchiveEvidencePlaybackSnapshot(
            archiveId: "archive",
            captureId: "capture",
            startedAt: "2026-07-23T10:00:00Z",
            durationMillis: 1_000,
            entries: [JazzArchiveEvidencePlaybackEntry(
                item: EvidencePlaybackItem(
                    playbackId: "gap",
                    offsetMillis: 500,
                    kind: .gap,
                    evidenceRef: nil,
                    gapReason: nil,
                    label: "Gap"),
                endOffsetMillis: nil,
                occurredAt: nil,
                title: "Gap",
                detail: nil,
                artifact: nil)])
        XCTAssertThrowsError(try JazzArchiveEvidencePlayhead(snapshot: implicitGap))
    }

    private func makeSnapshot(
        entries: [JazzArchiveEvidencePlaybackEntry],
        duration: Int64
    ) -> JazzArchiveEvidencePlaybackSnapshot {
        JazzArchiveEvidencePlaybackSnapshot(
            archiveId: "archive",
            captureId: "capture",
            startedAt: "2026-07-23T10:00:00Z",
            durationMillis: duration,
            entries: entries)
    }

    private func entry(
        _ id: String,
        offset: Int64,
        end: Int64? = nil,
        kind: EvidencePlaybackKind
    ) -> JazzArchiveEvidencePlaybackEntry {
        JazzArchiveEvidencePlaybackEntry(
            item: EvidencePlaybackItem(
                playbackId: id,
                offsetMillis: offset,
                kind: kind,
                evidenceRef: "\(kind.rawValue):\(id)",
                gapReason: nil,
                label: id),
            endOffsetMillis: end,
            occurredAt: nil,
            title: id,
            detail: nil,
            artifact: nil)
    }

    private func gap(_ id: String, offset: Int64) -> JazzArchiveEvidencePlaybackEntry {
        JazzArchiveEvidencePlaybackEntry(
            item: EvidencePlaybackItem(
                playbackId: id,
                offsetMillis: offset,
                kind: .gap,
                evidenceRef: nil,
                gapReason: "capture_loss",
                label: "Gap"),
            endOffsetMillis: nil,
            occurredAt: nil,
            title: "Gap",
            detail: "capture_loss",
            artifact: nil)
    }
}
