import XCTest

@testable import JasnostCaptureCore

/// Tests the timeline -> replay-steps mapping that lets the sessions overview replay any past
/// session. Fixture mirrors the backend `GET /api/sessions/{id}/timeline` shape.
final class ReplayBuilderTests: XCTestCase {
    private let timeline = """
        {"session_id":"s1","events":[
          {"event_type":"session_start","url":"app://session"},
          {"event_type":"navigate","url":"app://com.apple.calculator","system":"Calculator"},
          {"event_type":"click","url":"app://com.apple.calculator","target_role":"AXButton",
           "target_name":"7"},
          {"event_type":"scroll","url":"app://com.apple.calculator"},
          {"event_type":"click","url":"app://com.apple.calculator","target_role":"AXButton",
           "target_name":"="},
          {"event_type":"session_end","url":"app://session"}
        ]}
        """

    func testKeepsOnlyClicksAndNavigations() {
        let steps = ReplayBuilder.steps(from: ReplayBuilder.events(fromTimeline: Data(timeline.utf8)))
        // navigate + 2 clicks; session_start/end + scroll are dropped.
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps.map(\.kind), [.navigate, .click, .click])
    }

    func testClickStepCarriesBundleRoleAndName() {
        let steps = ReplayBuilder.steps(from: ReplayBuilder.events(fromTimeline: Data(timeline.utf8)))
        let firstClick = steps[1]
        XCTAssertEqual(firstClick.kind, .click)
        XCTAssertEqual(firstClick.bundleID, "com.apple.calculator")
        XCTAssertEqual(firstClick.role, "AXButton")
        XCTAssertEqual(firstClick.name, "7")
        // Timeline carries no coordinates, so re-find is the only path.
        XCTAssertNil(firstClick.boundingBox)
        XCTAssertEqual(firstClick.label, "Click 7")
    }

    func testNavigateStepLabelsTheApp() {
        let steps = ReplayBuilder.steps(from: ReplayBuilder.events(fromTimeline: Data(timeline.utf8)))
        let nav = steps[0]
        XCTAssertEqual(nav.kind, .navigate)
        XCTAssertEqual(nav.bundleID, "com.apple.calculator")
        XCTAssertEqual(nav.label, "Switch to com.apple.calculator")
    }

    func testBundleIDExtraction() {
        XCTAssertEqual(ReplayBuilder.bundleID(from: "app://com.apple.calculator"), "com.apple.calculator")
        XCTAssertNil(ReplayBuilder.bundleID(from: "app://"))
        XCTAssertNil(ReplayBuilder.bundleID(from: "https://example.com"))
        XCTAssertNil(ReplayBuilder.bundleID(from: nil))
    }

    func testClickFallsBackToRoleWhenNameMissing() {
        let json = """
            {"events":[{"event_type":"click","url":"app://com.foo","target_role":"AXButton"}]}
            """
        let steps = ReplayBuilder.steps(from: ReplayBuilder.events(fromTimeline: Data(json.utf8)))
        XCTAssertEqual(steps.first?.label, "Click AXButton")
    }

    func testEmptyOnGarbage() {
        XCTAssertTrue(ReplayBuilder.events(fromTimeline: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(ReplayBuilder.steps(from: []).isEmpty)
    }

    func testInputEventBecomesTypeStep() {
        let json = """
            {"events":[{"event_type":"input","url":"app://com.apple.Safari",
              "target_role":"AXTextField","target_name":"Search","value":"San Francisco"}]}
            """
        let steps = ReplayBuilder.steps(from: ReplayBuilder.events(fromTimeline: Data(json.utf8)))
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].kind, .type)
        XCTAssertEqual(steps[0].text, "San Francisco")
        XCTAssertEqual(steps[0].bundleID, "com.apple.Safari")
        XCTAssertEqual(steps[0].name, "Search")
        XCTAssertEqual(steps[0].label, "Type “San Francisco”")
    }

    func testKeydownShortcutVsSpecial() {
        let json = """
            {"events":[
              {"event_type":"keydown","url":"app://com.foo","value":"Cmd+S"},
              {"event_type":"keydown","url":"app://com.foo","value":"Enter"}
            ]}
            """
        let steps = ReplayBuilder.steps(from: ReplayBuilder.events(fromTimeline: Data(json.utf8)))
        XCTAssertEqual(steps.map(\.kind), [.shortcut, .key])
        XCTAssertEqual(steps[0].name, "Cmd+S")
        XCTAssertEqual(steps[1].label, "Press Enter")
    }

    func testEmptyValueEventsDropped() {
        let json = """
            {"events":[
              {"event_type":"input","url":"app://com.foo","value":""},
              {"event_type":"keydown","url":"app://com.foo"}
            ]}
            """
        let steps = ReplayBuilder.steps(from: ReplayBuilder.events(fromTimeline: Data(json.utf8)))
        XCTAssertTrue(steps.isEmpty)
    }

    func testActivityEventMappingCarriesBoundingBoxAndDropsMarkers() {
        func ev(_ type: String, url: String = "app://com.foo", value: String? = nil,
                target: EventTarget? = nil) -> ActivityEvent {
            ActivityEvent(
                sessionId: "s-1", eventId: "s-1-0", sequence: 0,
                timestamp: "2026-06-13T10:00:00.000Z", eventType: type, url: url,
                target: target, value: value)
        }
        let events = [
            ev("session_start", url: "app://session"),
            ev("navigate"),
            ev("click", target: EventTarget(
                role: "AXButton", accessibleName: "Save",
                boundingBox: BoundingBox(x: 10, y: 20, width: 30, height: 40))),
            ev("annotation", url: "app://session", value: "Invoice approval"),
            ev("input", value: "hello", target: EventTarget(role: "AXTextField")),
            ev("keydown", value: "Cmd+S"),
            ev("session_end", url: "app://session"),
        ]
        let steps = ReplayBuilder.steps(fromActivityEvents: events)
        XCTAssertEqual(steps.map(\.kind), [.navigate, .click, .type, .shortcut])
        // The locally captured bounding box survives as the click's coordinate fallback.
        XCTAssertEqual(steps[1].boundingBox, CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(steps[1].name, "Save")
        XCTAssertEqual(steps[2].text, "hello")
        XCTAssertEqual(steps[3].name, "Cmd+S")
    }
}
