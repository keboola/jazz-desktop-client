import Foundation

/// Label-scoped progression through the version-pinned local Capture Coach baseline. Closing a
/// label never spends another label's questions; reopening the same label resumes its own cursor.
public struct CaptureCoachBaselineCursor: Equatable, Sendable {
    private var nextIndexByLabelId: [String: Int] = [:]

    public init() {}

    public mutating func resetCapture() {
        nextIndexByLabelId.removeAll(keepingCapacity: false)
    }

    public func nextIndex(
        for labelId: String,
        templateCount: Int
    ) -> Int? {
        guard !labelId.isEmpty, templateCount > 0 else { return nil }
        let index = nextIndexByLabelId[labelId, default: 0]
        return index < templateCount ? index : nil
    }

    /// Advances only the exact slot that was issued. This prevents a delayed task from spending
    /// another prompt after label close/reopen or duplicate scheduling.
    @discardableResult
    public mutating func advance(
        labelId: String,
        issuedIndex: Int,
        templateCount: Int
    ) -> Bool {
        guard nextIndex(for: labelId, templateCount: templateCount) == issuedIndex else {
            return nextIndex(for: labelId, templateCount: templateCount) == nil
        }
        nextIndexByLabelId[labelId] = issuedIndex + 1
        return issuedIndex + 1 >= templateCount
    }

    /// Spends a baseline slot only after the coordinator has durably confirmed `shown` and the UI
    /// still owns the exact capture/label generation that admitted the prompt. A delayed callback
    /// for a closed or replacement label returns nil and leaves the cursor untouched.
    public mutating func advanceAfterConfirmedPresentation(
        labelId: String,
        issuedIndex: Int,
        templateCount: Int,
        disposition: CaptureCoachPromptDisposition,
        expectedContext: CaptureCoachPresentationContext,
        presentedContext: CaptureCoachPresentationContext?
    ) -> Bool? {
        guard disposition == .shown, presentedContext == expectedContext else {
            return nil
        }
        return advance(
            labelId: labelId,
            issuedIndex: issuedIndex,
            templateCount: templateCount)
    }
}
