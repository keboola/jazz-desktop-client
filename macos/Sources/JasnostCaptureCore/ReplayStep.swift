import CoreGraphics
import Foundation

/// A single replayable step distilled from a captured interaction. A pure model so the
/// timeline -> steps mapping is unit-testable; the executable's ReplayController acts on these.
public struct ReplayStep: Identifiable, Sendable {
    public enum Kind: Sendable {
        case navigate  // bring an app to the front
        case click  // press a UI element
        case type  // type text into the focused field
        case shortcut  // send a modifier chord (Cmd+S)
        case key  // press a named special key (Enter, Tab, …)
    }

    public let id = UUID()
    public let kind: Kind
    public let bundleID: String?
    public let role: String?
    public let name: String?  // captured accessibleName, used to re-find the element
    /// AX identifier (kAXIdentifier) — the most stable re-find key when the app provides one.
    public let identifier: String?
    /// Position among same-role siblings, to disambiguate duplicate accessible names.
    public let index: Int?
    public let boundingBox: CGRect?  // fallback coordinates (only from in-memory capture)
    public let text: String?  // redacted typed text, for `.type` steps
    public let label: String  // short human label for the menu/status

    public init(
        kind: Kind, bundleID: String?, role: String?, name: String?, boundingBox: CGRect?,
        label: String, identifier: String? = nil, index: Int? = nil, text: String? = nil
    ) {
        self.kind = kind
        self.bundleID = bundleID
        self.role = role
        self.name = name
        self.identifier = identifier
        self.index = index
        self.boundingBox = boundingBox
        self.text = text
        self.label = label
    }
}

/// One row of `GET /api/sessions/{id}/timeline` — only the fields replay needs.
public struct JasnostTimelineEvent: Decodable, Sendable {
    public let eventType: String?
    public let url: String?
    public let targetRole: String?
    public let targetName: String?
    public let value: String?  // typed text (input) or shortcut/special-key name (keydown)

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case url
        case targetRole = "target_role"
        case targetName = "target_name"
        case value
    }
}

/// Builds replay steps from a session's persisted timeline, so any past session in the overview can
/// be replayed (not just the last in-memory capture). Timeline rows carry no bounding box, so click
/// steps replay by Accessibility re-find (role + name); typing and shortcuts replay from `value`.
public enum ReplayBuilder {
    /// Decode the `{ "events": [...] }` envelope from the timeline endpoint.
    public static func events(fromTimeline data: Data) -> [JasnostTimelineEvent] {
        struct Envelope: Decodable { let events: [JasnostTimelineEvent] }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.events ?? []
    }

    /// Map timeline events to replay steps: clicks, app switches, typed text, and shortcuts/special
    /// keys. Scrolls / clipboard markers / session markers are skipped.
    public static func steps(from events: [JasnostTimelineEvent]) -> [ReplayStep] {
        events.compactMap(step(from:))
    }

    private static func step(from event: JasnostTimelineEvent) -> ReplayStep? {
        let bundle = bundleID(from: event.url)
        switch event.eventType {
        case "click", "contextmenu":
            return ReplayStep(
                kind: .click, bundleID: bundle, role: event.targetRole, name: event.targetName,
                boundingBox: nil, label: "Click \(event.targetName ?? event.targetRole ?? "element")"
            )
        case "navigate":
            return ReplayStep(
                kind: .navigate, bundleID: bundle, role: nil, name: nil, boundingBox: nil,
                label: "Switch to \(bundle ?? "app")"
            )
        case "input", "change":
            guard let text = event.value, !text.isEmpty else { return nil }
            return ReplayStep(
                kind: .type, bundleID: bundle, role: event.targetRole, name: event.targetName,
                boundingBox: nil, label: "Type “\(text.prefix(30))”", text: text
            )
        case "keydown":
            guard let name = event.value, !name.isEmpty else { return nil }
            let isShortcut = name.contains("+")
            return ReplayStep(
                kind: isShortcut ? .shortcut : .key, bundleID: bundle, role: nil, name: name,
                boundingBox: nil, label: isShortcut ? name : "Press \(name)"
            )
        default:
            return nil
        }
    }

    /// `app://com.apple.calculator` -> `com.apple.calculator`.
    public static func bundleID(from url: String?) -> String? {
        guard let url, url.hasPrefix("app://") else { return nil }
        let bundle = String(url.dropFirst("app://".count))
        return bundle.isEmpty ? nil : bundle
    }

    // MARK: - Local journal path

    /// Map locally-spooled ActivityEvents (``EventSpool/sessionEvents(sessionId:)``) to
    /// replay steps — the offline path that replaces the old timeline fetch. Richer than
    /// the timeline mapping: the captured target bounding box survives, so a click whose
    /// element can't be re-found still has fallback coordinates.
    public static func steps(fromActivityEvents events: [ActivityEvent]) -> [ReplayStep] {
        events.compactMap(step(fromActivityEvent:))
    }

    private static func step(fromActivityEvent event: ActivityEvent) -> ReplayStep? {
        let bundle = bundleID(from: event.url)
        switch event.eventType {
        case "click", "contextmenu":
            var box: CGRect?
            if let b = event.target?.boundingBox {
                box = CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
            }
            let name = event.target?.accessibleName
            return ReplayStep(
                kind: .click, bundleID: bundle, role: event.target?.role, name: name,
                boundingBox: box,
                label: "Click \(name ?? event.target?.role ?? "element")"
            )
        case "navigate":
            // App-switch events carry the destination app in the url; the session markers
            // (url "app://session") have no bundle and are dropped by the guard below.
            guard let bundle else { return nil }
            return ReplayStep(
                kind: .navigate, bundleID: bundle, role: nil, name: nil, boundingBox: nil,
                label: "Switch to \(bundle)"
            )
        case "input", "change":
            guard let text = event.value, !text.isEmpty else { return nil }
            return ReplayStep(
                kind: .type, bundleID: bundle, role: event.target?.role,
                name: event.target?.accessibleName, boundingBox: nil,
                label: "Type “\(text.prefix(30))”", text: text
            )
        case "keydown":
            guard let name = event.value, !name.isEmpty else { return nil }
            let isShortcut = name.contains("+")
            return ReplayStep(
                kind: isShortcut ? .shortcut : .key, bundleID: bundle, role: nil, name: name,
                boundingBox: nil, label: isShortcut ? name : "Press \(name)"
            )
        default:
            // session markers, scrolls, clipboard markers, annotations, narration — not replayable.
            return nil
        }
    }
}
