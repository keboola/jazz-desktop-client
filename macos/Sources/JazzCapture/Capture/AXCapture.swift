import Foundation

/// One capture/label generation. Never reopened. A queued old block cannot acquire a new lease;
/// an admitted traversal keeps ownership until its utility work AND main-thread fallback return.
/// No lock is held across blocking AX IPC: an admitted call may finish after revoke, but every
/// subsequent attribute/traversal boundary and the adapter result are fenced.
final class CaptureAXAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting: Bool
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(accepting: Bool = false) { self.accepting = accepting }

    var permitsReads: Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting
    }

    var isClosedAndQuiescent: Bool {
        lock.lock(); defer { lock.unlock() }
        return !accepting && active == 0
    }

    func revoke() {
        lock.lock()
        accepting = false
        lock.unlock()
    }

    fileprivate func admit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return false }
        active += 1
        return true
    }

    /// Each foreign attribute/hit-test has its own atomic admission, not just the initial queue
    /// block. Revocation does not wait for an already-admitted blocking call, but rejects its value.
    func read<Value>(_ native: () -> Value?) -> Value? {
        guard admit() else { return nil }
        defer { complete() }
        let value = native()
        return permitsReads ? value : nil
    }

    fileprivate func complete() {
        lock.lock()
        active -= 1
        let pending = active == 0 ? waiters : []
        if active == 0 { waiters.removeAll() }
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func waitForQuiescence() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            precondition(!accepting)
            if active == 0 { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}

/// The production queued AX adapter. Tests defer the same utility/fallback native boundaries,
/// without sending AX messages to any application. Only previously admitted raw input survives a
/// revoked enrichment; neither late semantic context nor a fallback read may cross the boundary.
enum AXCapture {
    private static let queue = DispatchQueue(label: "dev.jazz.capture.ax", qos: .utility)
    struct ForeignResult { let hasWindow: Bool; let info: AXTargetInfo? }
    struct NativeOperations {
        let foreign: @Sendable (CaptureAXAdmission) -> ForeignResult
        let fallback: @MainActor (CaptureAXAdmission) -> AXTargetInfo?
    }

    static func enrichedTarget(
        admission: CaptureAXAdmission?, kind: EventTap.RawKind, location: CGPoint,
        excluding ownPID: pid_t, queue: DispatchQueue? = nil, native: NativeOperations? = nil
    ) async -> AXTargetInfo? {
        guard let admission else { return nil }
        let usesFocus = kind == .copy || kind == .cut || kind == .paste
        let native = native ?? NativeOperations(foreign: { admission in
            let pid = usesFocus ? nil : Accessibility.foreignWindowPID(
                at: location, excluding: ownPID, admission: admission)
            let info = pid.flatMap {
                Accessibility.target(inApp: $0, atScreenPoint: location, admission: admission)
            }
            return ForeignResult(hasWindow: pid != nil, info: info)
        }, fallback: { admission in
            usesFocus ? Accessibility.focusedInfo(admission: admission)
                : Accessibility.target(atScreenPoint: location, admission: admission)
        })
        return await withCheckedContinuation { continuation in
            (queue ?? Self.queue).async {
                guard admission.admit() else { continuation.resume(returning: nil); return }
                let foreign = native.foreign(admission)
                DispatchQueue.main.async {
                    defer { admission.complete() }
                    guard admission.permitsReads else { continuation.resume(returning: nil); return }
                    let info = foreign.hasWindow ? foreign.info : native.fallback(admission)
                    continuation.resume(returning: admission.permitsReads ? info : nil)
                }
            }
        }
    }
}
