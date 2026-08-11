import AppKit
import CoreGraphics
import Foundation
import JazzCaptureCore

/// A listen-only CGEventTap. Captures meaningful interaction milestones — clicks, right
/// clicks, scrolls, clipboard shortcuts (⌘C/⌘X/⌘V), and key presses. Raw keys are forwarded as a
/// neutral payload; the CaptureController classifies them into semantic typed text + shortcuts and
/// NEVER buffers input from secure/sensitive fields (the "semantic text + shortcuts" model).
/// Requires Accessibility permission.
final class EventTap {
    enum RawKind: Equatable, Sendable {
        case click, rightClick, scroll, drag, copy, cut, paste, key
    }

    struct ReArmEvent {
        var count: Int
        var reason: JazzCaptureCapabilityReason
        var rearmed: Bool
    }

    /// Raw payload of a key press, classified downstream by ``KeyClassifier``.
    struct KeyInfo {
        var keycode: Int64
        var characters: String?  // the unicode the key produced (nil for non-printable)
        var flags: CGEventFlags
    }

    struct RawEvent {
        var kind: RawKind
        var location: CGPoint
        var key: KeyInfo?
        /// OS click state for a click/drag: 1 = single, 2 = double, 3 = triple.
        var clickCount: Int
        /// For a ``.drag`` event: the release point (``location`` is the press/start point).
        var dragEnd: CGPoint?
        /// Stable correlation for one completed logical pointer gesture.
        var gestureId: String?
        /// Physical completion time, retained when click publication waits for coalescing.
        var occurredAt: Date

        init(
            kind: RawKind, location: CGPoint, key: KeyInfo? = nil, clickCount: Int = 1,
            dragEnd: CGPoint? = nil, gestureId: String? = nil, occurredAt: Date = Date()
        ) {
            self.kind = kind
            self.location = location
            self.key = key
            self.clickCount = clickCount
            self.dragEnd = dragEnd
            self.gestureId = gestureId
            self.occurredAt = occurredAt
        }
    }

    /// One physical left-button completion. Consumers begin provisional enrichment immediately,
    /// but this sample is not itself permission to append a canonical observation.
    struct PointerSample: Equatable, Sendable {
        var kind: RawKind
        var location: CGPoint
        var clickCount: Int
        var dragEnd: CGPoint?
        /// Changes for every physical press, including click 1 → 2 → 3.
        var sampleId: String
        /// Root identity retained across the whole coalesced logical gesture.
        var gestureId: String
        var occurredAt: Date
    }

    /// Coalescer decision selecting exactly one already-enriched physical sample.
    struct PointerResolution: Equatable, Sendable {
        var kind: RawKind
        var location: CGPoint
        var clickCount: Int
        var dragEnd: CGPoint?
        var sampleId: String
        var gestureId: String
        var occurredAt: Date
    }

    /// Pure state machine emits exactly one observation per completed logical left-pointer
    /// gesture. The executable owns the run-loop timer that drains a bounded single click.
    private var pointer: PointerGestureTracker
    private var pointerTimer: Timer?
    private var pointerTimerGeneration = 0
    private let pointerClock: () -> TimeInterval

    /// US keycodes for clipboard shortcuts.
    private enum KeyCode {
        static let c: Int64 = 8
        static let x: Int64 = 7
        static let v: Int64 = 9
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onPointerSample: ((PointerSample) -> Void)?
    var onPointerResolution: ((PointerResolution) -> Void)?
    var onEvent: ((RawEvent) -> Void)?
    /// Times the OS disabled this tap (slow callback or user input) and we re-enabled it.
    /// A rising counter means the callback is too slow — surfaced via ``onReArm``.
    private(set) var reArmCount = 0
    var onReArm: ((ReArmEvent) -> Void)?

    init(
        doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval,
        pointerClock: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        pointer = PointerGestureTracker(doubleClickInterval: doubleClickInterval)
        self.pointerClock = pointerClock
    }

    @discardableResult
    func start() -> Bool {
        reArmCount = 0  // per-session counter (a fresh tap starts healthy)
        cancelPointerTimer()
        pointer.reset()
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                tap.handle(type: type, event: event)
            }
            // Listen-only: always pass the event through unchanged.
            return Unmanaged.passUnretained(event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        cancelPointerTimer()
        publish(pointer.finish())
    }

    /// Flushes a completed click before a label/session boundary without stopping the tap.
    func flushPendingPointerGesture() {
        cancelPointerTimer()
        publish(pointer.flushPendingClick())
    }

    /// Internal for executable-target tests; production calls it only from the listen-only tap.
    func handle(type: CGEventType, event: CGEvent) {
        let location = event.location
        switch type {
        case .leftMouseDown:
            // Delay publication until mouse-up. We can then emit exactly one completed gesture:
            // either click or drag, and AX sees the selection produced by a double-click/drag.
            cancelPointerTimer()
            let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
            publish(
                pointer.mouseDown(
                    at: PointerPoint(x: location.x, y: location.y),
                    clickCount: clickCount,
                    sampleId: Self.newPointerSampleId(),
                    gestureId: Identifiers.newGestureId(), timestamp: pointerClock()))
        case .leftMouseDragged:
            pointer.mouseDragged()
        case .leftMouseUp:
            if let update = pointer.mouseUp(
                at: PointerPoint(x: location.x, y: location.y),
                timestamp: pointerClock(),
                completedAt: Date())
            {
                publish(update.sample)
                publish(update.resolutions)
            }
            schedulePointerTimerIfNeeded()
        case .rightMouseDown:
            flushPointerBeforeIndependentEvent()
            onEvent?(
                RawEvent(
                    kind: .rightClick,
                    location: location,
                    gestureId: Identifiers.newGestureId()))
        case .scrollWheel:
            flushPointerBeforeIndependentEvent()
            onEvent?(RawEvent(kind: .scroll, location: location))
        case .keyDown:
            flushPointerBeforeIndependentEvent()
            handleKeyDown(event, location: location)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            flushPointerBeforeIndependentEvent()
            // The OS reports timeout and user-input disablement as distinct neutral conditions.
            // Neither callback proves that Secure Event Input is active.
            // Without this re-enable, capture silently stops — the historical "it just
            // stopped recording" failure. Re-arm, log, and surface the count.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            reArmCount += 1
            let reason: JazzCaptureCapabilityReason =
                type == .tapDisabledByTimeout
                ? .eventTapTimeout : .eventTapUserInput
            let rearmed = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
            NSLog(
                "jazz: event tap disabled by the OS (%@), re-armed (count %d)",
                type == .tapDisabledByTimeout ? "timeout" : "user input", reArmCount)
            onReArm?(
                ReArmEvent(
                    count: reArmCount,
                    reason: reason,
                    rearmed: rearmed))
        default:
            return
        }
    }

    private func publish(_ completed: [CompletedPointerGesture]) {
        for gesture in completed {
            onPointerResolution?(
                PointerResolution(
                    kind: gesture.kind == .drag ? .drag : .click,
                    location: CGPoint(x: gesture.start.x, y: gesture.start.y),
                    clickCount: gesture.clickCount,
                    dragEnd: gesture.end.map { CGPoint(x: $0.x, y: $0.y) },
                    sampleId: gesture.sampleId,
                    gestureId: gesture.gestureId,
                    occurredAt: gesture.completedAt))
        }
    }

    private func publish(_ sample: PointerGestureSample) {
        onPointerSample?(
            PointerSample(
                kind: sample.kind == .drag ? .drag : .click,
                location: CGPoint(x: sample.start.x, y: sample.start.y),
                clickCount: sample.clickCount,
                dragEnd: sample.end.map { CGPoint(x: $0.x, y: $0.y) },
                sampleId: sample.sampleId,
                gestureId: sample.gestureId,
                occurredAt: sample.completedAt))
    }

    private func flushPointerBeforeIndependentEvent() {
        flushPendingPointerGesture()
    }

    private func cancelPointerTimer() {
        pointerTimerGeneration += 1
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    private func schedulePointerTimerIfNeeded() {
        cancelPointerTimer()
        guard let deadline = pointer.nextClickDeadline else { return }

        let delay = max(0, deadline - pointerClock())
        let generation = pointerTimerGeneration
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.pointerTimerGeneration == generation else { return }
            self.pointerTimer = nil
            self.publish(self.pointer.flushExpired(at: self.pointerClock()))
            // A timer may fire a fraction early; retain the same deadline instead of losing the
            // completed click.
            self.schedulePointerTimerIfNeeded()
        }
        pointerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleKeyDown(_ event: CGEvent, location: CGPoint) {
        let flags = event.flags
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        // Clipboard shortcuts stay first-class semantic events (copy/cut/paste).
        if flags.contains(.maskCommand) {
            switch keycode {
            case KeyCode.c:
                onEvent?(RawEvent(kind: .copy, location: location))
                return
            case KeyCode.x:
                onEvent?(RawEvent(kind: .cut, location: location))
                return
            case KeyCode.v:
                onEvent?(RawEvent(kind: .paste, location: location))
                return
            default: break  // other ⌘ chord -> a .key event, classified as a shortcut downstream
            }
        }
        let key = KeyInfo(keycode: keycode, characters: Self.unicode(from: event), flags: flags)
        onEvent?(RawEvent(kind: .key, location: location, key: key))
    }

    /// The unicode string a key event produced (nil when empty — e.g. a pure modifier/dead key).
    /// For secure text fields the system enables Secure Event Input, so the tap receives no
    /// characters here — a defence-in-depth backstop on top of the field-sensitivity check.
    static func unicode(from event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(
            maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }

    private static func newPointerSampleId() -> String {
        "sample-\(Identifiers.newUUIDv7().uuidString.lowercased())"
    }
}

private actor PointerSelectionGate<Value: Sendable> {
    private var value: Value?
    private var continuation: CheckedContinuation<Value, Never>?
    private var resolved = false

    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ value: Value) {
        guard !resolved else { return }
        resolved = true
        if let continuation {
            continuation.resume(returning: value)
            self.continuation = nil
        } else {
            self.value = value
        }
    }
}

private enum PointerEnrichmentSelection<
    Root: Sendable, Context: Sendable, Enrichment: Sendable
>: Sendable {
    case sample(
        EventTap.PointerResolution,
        Root,
        Context,
        Task<Enrichment, Never>
    )
    case missing(EventTap.PointerResolution, Root)
}

/// Starts the asynchronous screen request and AX request before awaiting either one. Keeping this
/// primitive closure-driven makes the ordering and cancellation contract testable without TCC.
/// Cancellation stops child tasks and guarantees their values cannot reach canonical finalization;
/// an AX IPC already executing on its bounded DispatchQueue may still finish before being discarded.
@MainActor
enum PointerParallelEnrichment {
    static func begin<Screen: Sendable, AX: Sendable, Output: Sendable>(
        beginScreen: @MainActor @Sendable () -> Task<Screen, Never>,
        beginAX: @MainActor @Sendable () -> Task<AX, Never>,
        combine: @escaping @MainActor @Sendable (Screen, AX) async -> Output
    ) -> Task<Output, Never> {
        // Invocation order is part of the capture contract. In particular, do not move
        // `beginScreen` behind an await of AX: a slow target app must not shift the frame by the
        // full AX timeout (or by NSEvent.doubleClickInterval).
        let screen = beginScreen()
        let ax = beginAX()
        return Task { @MainActor in
            await withTaskCancellationHandler {
                let screenValue = await screen.value
                let axValue = await ax.value
                return await combine(screenValue, axValue)
            } onCancel: {
                screen.cancel()
                ax.cancel()
            }
        }
    }
}

/// Bridges EventTap's two phases without making provisional evidence durable. The first physical
/// sample reserves one root producer; every sample starts its own snapshot synchronously; the
/// coalescer later selects exactly one snapshot for that producer. This type is intentionally
/// closure-driven so its timing and A → B replacement behaviour can be tested without TCC.
@MainActor
final class PointerEnrichmentCoordinator<
    Root: Sendable, Context: Sendable, Enrichment: Sendable, Outcome: Sendable
> {
    typealias MakeRoot =
        @MainActor @Sendable (EventTap.PointerSample, Context) -> Root?
    typealias BeginEnrichment =
        @MainActor @Sendable (EventTap.PointerSample, Context) -> Task<Enrichment, Never>
    typealias Admit =
        @MainActor @Sendable (@escaping @Sendable () async -> Outcome) -> Void
    typealias Finalize =
        @MainActor @Sendable (
            EventTap.PointerResolution, Root, Context, Enrichment
        ) async -> Outcome
    typealias Missing =
        @MainActor @Sendable (EventTap.PointerResolution, Root) async -> Outcome

    private struct SampleWork {
        var context: Context
        var enrichment: Task<Enrichment, Never>
    }

    private struct RootState {
        var root: Root
        var gate:
            PointerSelectionGate<
                PointerEnrichmentSelection<Root, Context, Enrichment>
            >
        var samples: [String: SampleWork]
    }

    private let makeRoot: MakeRoot
    private let beginEnrichment: BeginEnrichment
    private let admit: Admit
    private let finalize: Finalize
    private let missing: Missing
    private var roots: [String: RootState] = [:]
    private var ignoredRoots = Set<String>()

    init(
        makeRoot: @escaping MakeRoot,
        beginEnrichment: @escaping BeginEnrichment,
        admit: @escaping Admit,
        finalize: @escaping Finalize,
        missing: @escaping Missing
    ) {
        self.makeRoot = makeRoot
        self.beginEnrichment = beginEnrichment
        self.admit = admit
        self.finalize = finalize
        self.missing = missing
    }

    /// Must be called directly from `onPointerSample`: `beginEnrichment` is invoked before this
    /// method returns, so front-app/label state can be frozen and OS snapshot work launched without
    /// waiting for the double-click timer.
    func receive(_ sample: EventTap.PointerSample, context: Context) {
        guard !ignoredRoots.contains(sample.gestureId) else { return }

        if roots[sample.gestureId] == nil {
            guard let root = makeRoot(sample, context) else {
                ignoredRoots.insert(sample.gestureId)
                return
            }
            let gate =
                PointerSelectionGate<
                    PointerEnrichmentSelection<Root, Context, Enrichment>
                >()
            roots[sample.gestureId] = RootState(
                root: root,
                gate: gate,
                samples: [:])
            let finalize = self.finalize
            let missing = self.missing
            admit {
                switch await gate.wait() {
                case .sample(let resolution, let root, let context, let enrichment):
                    return await finalize(
                        resolution, root, context, enrichment.value)
                case .missing(let resolution, let root):
                    return await missing(resolution, root)
                }
            }
        }

        guard var state = roots[sample.gestureId] else { return }
        // The closure is called synchronously. It may capture a UI snapshot and then return an
        // async Task for the bounded AX/ScreenCaptureKit work.
        let enrichment = beginEnrichment(sample, context)
        // A newer physical sample in the same logical gesture supersedes every earlier sample,
        // not merely a duplicate with the same sample id. Keeping A alive while B is enriched
        // races two ScreenCaptureKit requests through a single-flight slot and can make the
        // selected final sample lose its visual evidence.
        for work in state.samples.values {
            work.enrichment.cancel()
        }
        state.samples.removeAll(keepingCapacity: true)
        state.samples[sample.sampleId] = SampleWork(
            context: context,
            enrichment: enrichment)
        roots[sample.gestureId] = state
    }

    func resolve(_ resolution: EventTap.PointerResolution) {
        if ignoredRoots.remove(resolution.gestureId) != nil { return }
        guard let state = roots.removeValue(forKey: resolution.gestureId) else { return }
        if let selected = state.samples[resolution.sampleId] {
            for (sampleId, work) in state.samples where sampleId != resolution.sampleId {
                work.enrichment.cancel()
            }
            Task {
                await state.gate.resolve(
                    .sample(
                        resolution,
                        state.root,
                        selected.context,
                        selected.enrichment))
            }
        } else {
            for work in state.samples.values {
                work.enrichment.cancel()
            }
            Task {
                await state.gate.resolve(.missing(resolution, state.root))
            }
        }
    }
}
