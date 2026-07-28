import AppKit
import ApplicationServices
import CoreGraphics
import JasnostCaptureCore

/// Semantic info about the UI element under the cursor, read from the Accessibility tree —
/// the desktop equivalent of the browser's DOM selector + accessible name.
struct AXTargetInfo {
    var role: String?
    var subrole: String?
    var label: String?
    var value: String?
    /// kAXSelectedText — the text currently selected in/at this element (a double-clicked word, a
    /// drag-selected range). Distinct from `value` (the element's full content).
    var selectedText: String?
    var windowTitle: String?
    /// kAXDocument — the real document/page URL for apps that expose it (browsers, Preview), so a
    /// browser event can carry the actual web URL instead of the synthetic `app://<bundle>`.
    var documentURL: String?
    var frame: CGRect?
    /// kAXIdentifier — a stable, developer-assigned id (when present), the best re-find key.
    var identifier: String?
    /// Position among same-role siblings, to disambiguate duplicate accessible names.
    var index: Int?
    /// Ancestor chain as "role:name" from the window down to this element (a readable trail).
    var path: [String]?
    /// The app that actually OWNS this element (derived from its AX pid), which can differ from the
    /// Workspace "frontmost app" — menu-bar extras and Spotlight overlays don't change frontmost.
    /// Used to attribute events to the right app and to ignore jasnost's own UI.
    var ownerPID: pid_t?
    var ownerBundleID: String?
    var ownerName: String?
    var ownerVersion: String?
}

/// Result of a read-only semantic Accessibility lookup for guided execution. The element is
/// returned only when the locator resolves exactly once after any explicit index disambiguation.
/// This type has no action API.
struct AXSemanticResolution {
    var element: AXUIElement?
    var matchCount: Int
}

enum Accessibility {
    /// How long any single AX call may block (seconds). Setting the timeout on the
    /// system-wide element makes it the default for ALL AX messaging from this process, so
    /// a hung target app stalls enrichment for at most ~0.3s instead of the multi-second
    /// system default that used to get our event tap disabled.
    private static let messagingTimeout: Float = 0.3

    /// Shared system-wide AX element (hit-tests + focus queries), created once with the
    /// bounded messaging timeout applied.
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }()

    /// Is this process a trusted Accessibility client? Pass `prompt: true` to surface the
    /// system "grant Accessibility access" dialog on first run.
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func copyAttr(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success
            ? value : nil
    }

    private static func stringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        copyAttr(element, attr) as? String
    }

    /// The element's accessible name, with the same priority capture and re-find both use:
    /// title -> description -> value -> placeholder.
    private static func label(of element: AXUIElement) -> String? {
        stringAttr(element, kAXTitleAttribute as String)
            ?? stringAttr(element, kAXDescriptionAttribute as String)
            ?? stringAttr(element, kAXValueAttribute as String)
            ?? stringAttr(element, kAXPlaceholderValueAttribute as String)
    }

    /// Read an element's semantic identity: role / subrole / label / value / identifier / window
    /// title. With ``includeHierarchy`` it also walks the tree for the sibling index + ancestor path
    /// (used for clicks); the keystroke hot path passes `false` to stay cheap per key press.
    private static func describe(_ element: AXUIElement, includeHierarchy: Bool = true) -> AXTargetInfo
    {
        var info = AXTargetInfo()
        info.role = stringAttr(element, kAXRoleAttribute as String)
        info.subrole = stringAttr(element, kAXSubroleAttribute as String)
        info.label =
            stringAttr(element, kAXTitleAttribute as String)
            ?? stringAttr(element, kAXDescriptionAttribute as String)
            ?? stringAttr(element, kAXPlaceholderValueAttribute as String)
        info.value = stringAttr(element, kAXValueAttribute as String)
        // The selection (kAXSelectedText): a double-clicked word / drag-selected range. Empty string
        // means "nothing selected" — normalise that to nil so it's omitted from the event.
        let selected = stringAttr(element, kAXSelectedTextAttribute as String)
        info.selectedText = (selected?.isEmpty == false) ? selected : nil
        // The real document/page URL when the app exposes it (browsers, Preview); from the element,
        // else its window. Lets a browser event carry the web URL instead of app://<bundle>.
        info.documentURL = stringAttr(element, kAXDocumentAttribute as String)
        info.identifier = stringAttr(element, kAXIdentifierAttribute as String)
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid > 0 {
            info.ownerPID = pid
            if let app = NSRunningApplication(processIdentifier: pid) {
                info.ownerBundleID = app.bundleIdentifier
                info.ownerName = app.localizedName
                info.ownerVersion = app.bundleURL.flatMap(Bundle.init(url:))?
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            }
        }
        if let windowRef = copyAttr(element, kAXWindowAttribute as String) {
            let window = windowRef as! AXUIElement
            info.windowTitle = stringAttr(window, kAXTitleAttribute as String)
            if info.documentURL == nil {
                info.documentURL = stringAttr(window, kAXDocumentAttribute as String)
            }
        }
        if includeHierarchy {
            info.index = siblingIndex(of: element, role: info.role)
            info.path = ancestorPath(of: element)
        }
        return info
    }

    /// Hit-test against a SPECIFIC application's element (cross-process / IPC), so it is safe to
    /// call OFF the main thread — the AX enrichment queue. This is the common click/scroll path:
    /// the caller first finds the topmost FOREIGN window under the point (``foreignWindowPID``) and
    /// resolves only that app, so the message never reaches our own in-process UI.
    static func target(inApp pid: pid_t, atScreenPoint point: CGPoint) -> AXTargetInfo? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)  // bound a hung target app
        var element: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &element)
                == .success,
            let element
        else { return nil }
        var info = describe(element)
        info.frame = frame(of: element)
        guard WindowHitTest.targetFrameIsPlausible(
            info.frame.map {
                CaptureRectangle(
                    x: Double($0.minX),
                    y: Double($0.minY),
                    width: Double($0.width),
                    height: Double($0.height))
            },
            at: CapturePoint(x: Double(point.x), y: Double(point.y)))
        else { return nil }

        // Canvas-heavy web apps (notably Google Sheets) often hit-test to one anonymous AXGroup,
        // while their focused accessibility element carries the cell editor or screen-reader name.
        // Prefer that focused element only when it is semantically richer; ownership remains pinned
        // to the same application and no action is performed through AX.
        if let focused = focusedInfo(inApp: pid),
            shouldPreferFocusedTarget(focused, over: info, atScreenPoint: point)
        {
            return focused
        }
        return info
    }

    /// A richer focused element may repair canvas-style hit testing only when it still covers the
    /// physical click. Chromium can retain focus in a text field while the user clicks elsewhere;
    /// semantic richness alone would then silently move the click to the wrong control.
    static func shouldPreferFocusedTarget(
        _ focused: AXTargetInfo,
        over hitTested: AXTargetInfo,
        atScreenPoint point: CGPoint
    ) -> Bool {
        guard
            semanticScore(focused) >= 2,
            semanticScore(focused) > semanticScore(hitTested)
        else { return false }
        return WindowHitTest.targetFrameIsPlausible(
            focused.frame.map {
                CaptureRectangle(
                    x: Double($0.minX),
                    y: Double($0.minY),
                    width: Double($0.width),
                    height: Double($0.height))
            },
            at: CapturePoint(x: Double(point.x), y: Double(point.y)))
    }

    /// Hit-test the topmost element under a screen point via the SYSTEM-WIDE element.
    ///
    /// **Must run on the main thread.** A system-wide hit can land on one of *our own* windows
    /// (above all the full-screen click-through highlight overlay, which AX hit-testing sees even
    /// though `ignoresMouseEvents` hides it from the cursor); macOS then resolves it IN-PROCESS
    /// through AppKit's `NSAccessibility`, which is main-thread-only and crashes when driven off the
    /// main thread (a data race → `objc_msgSend` on a freed object — #ax-crash). Used only as the
    /// fallback when no foreign window could be identified off-main (the click is on our own UI, or
    /// `CGWindowList` is restricted to our own process without Screen Recording on macOS 15+); the
    /// common path goes through ``target(inApp:atScreenPoint:)`` off the main thread.
    @MainActor
    static func target(atScreenPoint point: CGPoint) -> AXTargetInfo? {
        var element: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
                == .success,
            let element
        else { return nil }
        var info = describe(element)
        info.frame = frame(of: element)
        return info
    }

    /// Owner PID of the topmost on-screen window under `point` that is not ours, read from the
    /// window-server snapshot (thread-safe, AX-free — callable from the AX enrichment queue).
    ///
    /// `nil` when only our own windows lie under the point — OR when `CGWindowList` is restricted to
    /// our own process (no Screen Recording, macOS 15+). Both cases route the caller to the
    /// main-thread ``target(atScreenPoint:)`` fallback, so AX enrichment is never silently lost.
    static func foreignWindowPID(at point: CGPoint, excluding ownPID: pid_t) -> pid_t? {
        guard
            let raw = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return nil }
        let windows: [WindowDescriptor] = raw.compactMap { info in
            guard
                let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return WindowDescriptor(
                ownerPID: pid,
                bounds: CaptureRectangle(
                    x: Double(bounds.minX),
                    y: Double(bounds.minY),
                    width: Double(bounds.width),
                    height: Double(bounds.height)),
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
        return WindowHitTest.topmostForeignOwner(
            windows: windows,
            at: CapturePoint(x: Double(point.x), y: Double(point.y)),
            excluding: ownPID)
    }

    /// The system-wide focused UI element's identity — drives keystroke capture (which field is being
    /// typed into, and whether it is a secure/sensitive field).
    static func focusedInfo() -> AXTargetInfo? {
        guard let focused = copyAttr(systemWide, kAXFocusedUIElementAttribute as String) else {
            return nil
        }
        return describe(focused as! AXUIElement, includeHierarchy: false)
    }

    /// Cross-process focused-element query used by pointer enrichment. Unlike the system-wide
    /// fallback, this can safely run on the AX utility queue because it cannot resolve our AppKit
    /// accessibility implementation in-process.
    static func focusedInfo(inApp pid: pid_t) -> AXTargetInfo? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let focused = copyAttr(appElement, kAXFocusedUIElementAttribute as String) else {
            return nil
        }
        let element = focused as! AXUIElement
        var info = describe(element)
        info.frame = frame(of: element)
        return info
    }

    private static func semanticScore(_ info: AXTargetInfo) -> Int {
        WindowHitTest.semanticScore(
            role: info.role,
            label: info.label,
            value: info.value,
            selectedText: info.selectedText,
            identifier: info.identifier)
    }

    /// 0-based index of ``element`` among its parent's children that share its ``role``.
    private static func siblingIndex(of element: AXUIElement, role: String?) -> Int? {
        guard
            let role,
            let parentRef = copyAttr(element, kAXParentAttribute as String),
            let siblings = copyAttr(parentRef as! AXUIElement, kAXChildrenAttribute as String)
                as? [AXUIElement]
        else { return nil }
        let sameRole = siblings.filter { stringAttr($0, kAXRoleAttribute as String) == role }
        return sameRole.firstIndex { CFEqual($0, element) }
    }

    /// "role:name" trail from the window down to ``element`` (bounded), for a human-readable label.
    private static func ancestorPath(of element: AXUIElement) -> [String]? {
        var trail: [String] = []
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 12 {
            let role = stringAttr(node, kAXRoleAttribute as String) ?? "?"
            let name = label(of: node)
            trail.append(name.map { "\(role):\($0)" } ?? role)
            if role == kAXWindowRole as String { break }
            current = copyAttr(node, kAXParentAttribute as String).map { $0 as! AXUIElement }
            depth += 1
        }
        return trail.isEmpty ? nil : Array(trail.reversed())
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let posRef = copyAttr(element, kAXPositionAttribute as String),
            let sizeRef = copyAttr(element, kAXSizeAttribute as String)
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: replay — re-find an element by its semantic identity (#replay)

    /// Find an element in ``bundleID``'s live UI by SEMANTICS, not fragile screen coordinates.
    /// Priority: the stable ``identifier`` (kAXIdentifier) first, then ``role`` + the captured
    /// ``name`` (accessibleName), disambiguated by ``index`` among same-role/name matches.
    static func find(
        bundleID: String, role: String?, name: String?, identifier: String? = nil, index: Int? = nil
    ) -> AXUIElement? {
        guard
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if let identifier, !identifier.isEmpty,
            let byId = search(appElement, depth: 0, { stringAttr($0, kAXIdentifierAttribute as String) == identifier })
        {
            return byId
        }
        // Collect all role+name matches; pick the recorded position when there are duplicates.
        var matches: [AXUIElement] = []
        collect(appElement, depth: 0, into: &matches) { self.matches($0, role: role, name: name) }
        if let index, index >= 0, index < matches.count { return matches[index] }
        return matches.first
    }

    /// Resolve an execution locator without pressing, focusing, typing into, or otherwise mutating
    /// the target. Ambiguity is preserved as `matchCount > 1`; there is no first-match fallback.
    static func resolveSemanticTarget(
        bundleID: String,
        role: String?,
        name: String?,
        identifier: String? = nil,
        index: Int? = nil
    ) -> AXSemanticResolution {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).filter { !$0.isTerminated }
        guard applications.count == 1, let application = applications.first else {
            return AXSemanticResolution(element: nil, matchCount: applications.count)
        }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, messagingTimeout)
        var matches: [AXUIElement] = []
        collect(root, depth: 0, into: &matches) { element in
            if let identifier, !identifier.isEmpty {
                guard stringAttr(element, kAXIdentifierAttribute as String) == identifier else {
                    return false
                }
            }
            return self.matches(element, role: role, name: name)
        }
        if let index {
            guard index >= 0, index < matches.count else {
                return AXSemanticResolution(element: nil, matchCount: 0)
            }
            return AXSemanticResolution(element: matches[index], matchCount: 1)
        }
        return AXSemanticResolution(
            element: matches.count == 1 ? matches[0] : nil,
            matchCount: matches.count)
    }

    /// The current screen frame of an element (top-left origin) — for the replay highlight.
    static func currentFrame(of element: AXUIElement) -> CGRect? { frame(of: element) }

    /// Read-only readiness checks used immediately before presenting a manual action.
    static func isGuidanceTargetAvailable(_ element: AXUIElement) -> Bool {
        let enabled = (copyAttr(element, kAXEnabledAttribute as String) as? Bool) ?? true
        let hidden = (copyAttr(element, kAXHiddenAttribute as String) as? Bool) ?? false
        return enabled && !hidden && frame(of: element).map {
            $0.width > 1 && $0.height > 1
        } == true
    }

    /// Perform the element's default press (a button click), independent of its position.
    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Give an element keyboard focus (so replayed typing lands in the right field).
    @discardableResult
    static func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            == .success
    }

    /// First element in the subtree (DFS, bounded) satisfying ``predicate``.
    private static func search(
        _ element: AXUIElement, depth: Int, _ predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if depth > 80 { return nil }  // bound the walk
        if predicate(element) { return element }
        guard let children = copyAttr(element, kAXChildrenAttribute as String) as? [AXUIElement]
        else { return nil }
        for child in children {
            if let found = search(child, depth: depth + 1, predicate) { return found }
        }
        return nil
    }

    /// All elements in the subtree (DFS, bounded) satisfying ``predicate``, in tree order.
    private static func collect(
        _ element: AXUIElement, depth: Int, into out: inout [AXUIElement],
        _ predicate: (AXUIElement) -> Bool
    ) {
        if depth > 80 { return }
        if predicate(element) { out.append(element) }
        guard let children = copyAttr(element, kAXChildrenAttribute as String) as? [AXUIElement]
        else { return }
        for child in children { collect(child, depth: depth + 1, into: &out, predicate) }
    }

    /// Same label priority as capture (title -> description -> value -> placeholder), so a step
    /// re-finds the element it recorded.
    private static func matches(_ element: AXUIElement, role: String?, name: String?) -> Bool {
        if let role, !role.isEmpty, stringAttr(element, kAXRoleAttribute as String) != role {
            return false
        }
        guard let name, !name.isEmpty else { return role != nil }
        return label(of: element) == name
    }
}
