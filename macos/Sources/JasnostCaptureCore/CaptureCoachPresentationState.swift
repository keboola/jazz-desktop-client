import Foundation

/// Exact UI-admission token minted by the desktop controller for one open label generation.
///
/// `captureId` and `labelId` protect against cross-capture and cross-label callbacks. `generation`
/// additionally protects against a delayed callback when a label identity is ever replayed by a
/// deterministic test harness or recovered controller.
public struct CaptureCoachPresentationContext: Equatable, Sendable {
    public var captureId: String
    public var labelId: String
    public var generation: UInt64

    public init(captureId: String, labelId: String, generation: UInt64) {
        self.captureId = captureId
        self.labelId = labelId
        self.generation = generation
    }
}

/// Foundation-only projection guard for the controller's published Capture Coach surface.
///
/// Async coordinator actions, live prompt polls, and artifact-gated spoken answers may all finish
/// after the user closes a label. They may still append their canonical audit evidence, but only a
/// callback carrying the exact current context may change the visible prompt.
public struct CaptureCoachPresentationState: Equatable, Sendable {
    public private(set) var captureId: String?
    public private(set) var activeLabelId: String?
    public private(set) var generation: UInt64 = 0
    public private(set) var prompt: CaptureCoachPrompt?
    public private(set) var mutedUntil: String?

    public init() {}

    public var currentContext: CaptureCoachPresentationContext? {
        guard let captureId, let activeLabelId else { return nil }
        return CaptureCoachPresentationContext(
            captureId: captureId,
            labelId: activeLabelId,
            generation: generation)
    }

    public mutating func beginCapture(captureId: String) {
        generation &+= 1
        self.captureId = captureId
        activeLabelId = nil
        prompt = nil
        mutedUntil = nil
    }

    public mutating func endCapture(captureId expectedCaptureId: String) {
        guard captureId == expectedCaptureId else { return }
        generation &+= 1
        captureId = nil
        activeLabelId = nil
        prompt = nil
        mutedUntil = nil
    }

    @discardableResult
    public mutating func openLabel(
        captureId expectedCaptureId: String,
        labelId: String
    ) -> CaptureCoachPresentationContext? {
        guard captureId == expectedCaptureId else { return nil }
        generation &+= 1
        activeLabelId = labelId
        prompt = nil
        mutedUntil = nil
        return currentContext
    }

    /// Closes only the exact active label and synchronously retracts its published presentation.
    @discardableResult
    public mutating func closeLabel(
        captureId expectedCaptureId: String,
        labelId expectedLabelId: String
    ) -> Bool {
        guard captureId == expectedCaptureId, activeLabelId == expectedLabelId else {
            return false
        }
        generation &+= 1
        activeLabelId = nil
        prompt = nil
        mutedUntil = nil
        return true
    }

    public func admits(
        _ prompt: CaptureCoachPrompt,
        in context: CaptureCoachPresentationContext
    ) -> Bool {
        currentContext == context
            && prompt.inputWatermark.captureId == context.captureId
            && prompt.labelId == context.labelId
    }

    /// Applies the real live UI callback only while its exact label generation is still active.
    @discardableResult
    public mutating func present(
        _ prompt: CaptureCoachPrompt,
        in context: CaptureCoachPresentationContext
    ) -> Bool {
        guard admits(prompt, in: context) else { return false }
        self.prompt = prompt
        mutedUntil = nil
        return true
    }

    /// Applies a coordinator projection only to the label generation that admitted the action.
    ///
    /// A nil outstanding prompt may clear the current presentation. A non-nil prompt must also carry
    /// exact capture and label lineage; a stale artifact-gated completion therefore cannot replace or
    /// clear a newer label's prompt.
    @discardableResult
    public mutating func apply(
        _ snapshot: CaptureCoachCoordinatorSnapshot,
        in context: CaptureCoachPresentationContext
    ) -> Bool {
        guard currentContext == context else { return false }
        if let outstandingPrompt = snapshot.outstandingPrompt {
            guard admits(outstandingPrompt, in: context) else { return false }
        }
        prompt = snapshot.outstandingPrompt
        mutedUntil = snapshot.mutedUntil
        return true
    }
}
