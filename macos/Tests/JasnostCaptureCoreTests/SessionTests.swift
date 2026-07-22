import XCTest

@testable import JasnostCaptureCore

/// Tests for decoding the sessions list the native sidebar renders. Fixture mirrors the backend
/// `GET /api/sessions` shape.
final class SessionTests: XCTestCase {
    func testParseTimestampToleratesFractionalSeconds() {
        XCTAssertNil(JasnostSession.parseTimestamp(nil))
        XCTAssertNil(JasnostSession.parseTimestamp(""))
        XCTAssertNil(JasnostSession.parseTimestamp("not-a-date"))
        XCTAssertNotNil(JasnostSession.parseTimestamp("2026-06-09T13:45:16Z"))
        // Keboola timestamps carry fractional seconds, which the default ISO8601DateFormatter rejects.
        XCTAssertNotNil(JasnostSession.parseTimestamp("2026-06-09T13:45:16.74865Z"))
    }

    func testDecodesSessionsEnvelope() {
        let json = """
            {"sessions":[
              {"session_id":"s1","user":"petr@keboola.com","events":42,"clicks":12,
               "has_narration":true,"started":"2026-06-06T10:00:00Z","ended":"2026-06-06T10:05:00Z",
               "processed":true},
              {"session_id":"s2","user":null,"events":3,"clicks":0,"has_narration":false,
               "started":null,"ended":null,"processed":false}
            ]}
            """
        let sessions = SessionList.decode(Data(json.utf8))
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].sessionId, "s1")
        XCTAssertEqual(sessions[0].id, "s1")  // Identifiable
        XCTAssertEqual(sessions[0].user, "petr@keboola.com")
        XCTAssertEqual(sessions[0].events, 42)
        XCTAssertTrue(sessions[0].hasNarration)
        XCTAssertTrue(sessions[0].processed)
        XCTAssertNil(sessions[1].user)
        XCTAssertFalse(sessions[1].processed)
    }

    func testTolerantToMissingOptionalFields() {
        // Only session_id is required; missing counts/flags default rather than dropping the row.
        let json = #"{"sessions":[{"session_id":"s9"}]}"#
        let sessions = SessionList.decode(Data(json.utf8))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionId, "s9")
        XCTAssertEqual(sessions[0].events, 0)
        XCTAssertFalse(sessions[0].hasNarration)
    }

    func testGarbageYieldsEmptyList() {
        XCTAssertTrue(SessionList.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(SessionList.decode(Data(#"{"unexpected":1}"#.utf8)).isEmpty)
    }

    func testDeduplicatesBySessionIdKeepingRichest() {
        // The API can return the same session_id several times with different event counts; the
        // sidebar must show one row per id (the richest), or a click highlights every duplicate.
        let json = """
            {"sessions":[
              {"session_id":"s1","events":1,"clicks":0},
              {"session_id":"s2","events":5,"clicks":2},
              {"session_id":"s1","events":262,"clicks":41},
              {"session_id":"s1","events":1,"clicks":0}
            ]}
            """
        let sessions = SessionList.decode(Data(json.utf8))
        XCTAssertEqual(sessions.count, 2)  // s1 + s2, deduped
        XCTAssertEqual(sessions.map(\.sessionId), ["s1", "s2"])  // first-seen order preserved
        XCTAssertEqual(sessions[0].events, 262)  // richest s1 kept
    }
}
