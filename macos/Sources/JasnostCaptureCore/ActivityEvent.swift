import Foundation

/// Bounding box of a UI element, in screen points.
public struct BoundingBox: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A point in screen coordinates — the release point of a drag (``ActivityEvent.dragEnd``).
public struct DragPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The semantic target of an action — the desktop equivalent of a DOM element. Built from
/// the Accessibility (AX) element hit-tested under the cursor. Optional fields are omitted
/// from JSON when nil (Swift synthesises `encodeIfPresent` for optionals).
public struct EventTarget: Codable, Sendable, Equatable {
    public var tag: String?
    public var role: String?
    public var accessibleName: String?
    public var text: String?
    public var boundingBox: BoundingBox?

    public init(
        tag: String? = nil,
        role: String? = nil,
        accessibleName: String? = nil,
        text: String? = nil,
        boundingBox: BoundingBox? = nil
    ) {
        self.tag = tag
        self.role = role
        self.accessibleName = accessibleName
        self.text = text
        self.boundingBox = boundingBox
    }
}

/// One captured activity event, matching `contract/schema/activity-event.schema.json`
/// (the same contract the Chrome extension emits). The schema is
/// `additionalProperties: false`, so only these fields may appear; nil optionals are
/// omitted. `sessionId`, `eventId`, `timestamp`, `eventType`, `url` are required.
public struct ActivityEvent: Codable, Sendable, Equatable {
    public var sessionId: String
    public var eventId: String
    public var sequence: Int?
    public var timestamp: String
    public var eventType: String
    public var url: String
    public var pageTitle: String?
    public var system: String?
    public var target: EventTarget?
    public var value: String?
    /// Text the user had selected at the interaction (AX kAXSelectedText) — e.g. a word
    /// double-clicked or a range drag-selected. The SELECTION, distinct from `target.text` (the
    /// element's full value). Masked when the field is sensitive.
    public var selectedText: String?
    /// Clipboard payload moved by a copy/cut/paste event (pasteboard text at that moment). Links a
    /// copy to its paste for data-flow reconstruction. Masked/omitted for secrets, length-capped.
    public var clipboardText: String?
    /// OS click state for a click/contextmenu/drag: 1 = single, 2 = double, 3 = triple.
    public var clickCount: Int?
    /// For a `drag` event: the point where the mouse button was released (start = the event location).
    public var dragEnd: DragPoint?
    public var inputMasked: Bool?
    public var isSensitive: Bool?
    public var screenshotId: String?
    public var audioFileId: String?
    /// Stable id of the active label (bracketed segment), minted at label start. Stamped onto
    /// every event captured while a label is open; nil when no label is active. Set on
    /// `label_start`/`label_end` events, which are the segment boundaries themselves.
    public var labelId: String?
    /// Human-readable name of the active label; nil when no label is active.
    public var label: String?
    /// Stable id of the Process (from the Area's inventory) this bracketed segment demonstrates —
    /// stamped per label, like `labelId` (the capture-side wiring lands with the Guided picker, a
    /// later phase; this carrier just defines the field). nil when the segment isn't process-anchored.
    /// Segment-scoped; the session's Area rides the OTLP attribute `area.id`, not an event field. ADR 0002.
    public var processId: String?
    /// Human-readable Process name (e.g. "Invoicing"); nil when the segment isn't process-anchored.
    public var process: String?
    /// Local-only: an inline `data:image/...;base64,…` screenshot. The agent uploads the image
    /// to Keboola Files and replaces it with `screenshotId` before emitting the event, so this
    /// field never goes on the wire; raw image bytes never reach OTLP — only the `screenshotId`
    /// reference does.
    public var screenshotDataUrl: String?

    public init(
        sessionId: String,
        eventId: String,
        sequence: Int? = nil,
        timestamp: String,
        eventType: String,
        url: String,
        pageTitle: String? = nil,
        system: String? = nil,
        target: EventTarget? = nil,
        value: String? = nil,
        selectedText: String? = nil,
        clipboardText: String? = nil,
        clickCount: Int? = nil,
        dragEnd: DragPoint? = nil,
        inputMasked: Bool? = nil,
        isSensitive: Bool? = nil,
        screenshotId: String? = nil,
        audioFileId: String? = nil,
        labelId: String? = nil,
        label: String? = nil,
        processId: String? = nil,
        process: String? = nil,
        screenshotDataUrl: String? = nil
    ) {
        self.sessionId = sessionId
        self.eventId = eventId
        self.sequence = sequence
        self.timestamp = timestamp
        self.eventType = eventType
        self.url = url
        self.pageTitle = pageTitle
        self.system = system
        self.target = target
        self.value = value
        self.selectedText = selectedText
        self.clipboardText = clipboardText
        self.clickCount = clickCount
        self.dragEnd = dragEnd
        self.inputMasked = inputMasked
        self.isSensitive = isSensitive
        self.screenshotId = screenshotId
        self.audioFileId = audioFileId
        self.labelId = labelId
        self.label = label
        self.processId = processId
        self.process = process
        self.screenshotDataUrl = screenshotDataUrl
    }
}

/// Event types the agent emits (subset of the schema enum relevant to desktop capture).
public enum EventType: String, Sendable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case navigate  // app/window switch
    case click
    case contextmenu
    case input
    case change
    case copy
    case cut
    case paste
    case scroll
    case drag  // mouse drag (drag-select / drag-and-drop): start = location, end = dragEnd
    case keydown
    case focus
    case screenshot
    case narration
    case annotation  // user-declared task label (live labeling) — opens a labeled segment
    case labelStart = "label_start"  // opens a bracketed label segment
    case labelEnd = "label_end"  // closes the open bracketed label segment
}
