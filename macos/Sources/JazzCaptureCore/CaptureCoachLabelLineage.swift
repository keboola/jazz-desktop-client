import Foundation

public struct CaptureCoachLabelLineageBinding: Codable, Equatable, Sendable {
    /// Stable baseline identity for one logical label inside a capture. It is the first segment's
    /// labelId, not a second mutable identity.
    public let baselineId: String
    /// Immediately preceding immutable segment in this lineage, when this segment resumes one.
    public let resumesLabelId: String?

    public init(baselineId: String, resumesLabelId: String? = nil) {
        self.baselineId = baselineId
        self.resumesLabelId = resumesLabelId
    }
}

/// Per-capture lineage reducer for bracketed label segments.
///
/// A reopened activity always receives a new immutable labelId/interval. Exact semantic identity
/// merely links it to the first segment's Coach baseline and to the immediately preceding segment,
/// preventing both interval merging and question-cursor reset.
public struct CaptureCoachLabelLineage: Equatable, Sendable {
    private struct Head: Equatable, Sendable {
        var baselineId: String
        var latestLabelId: String
    }

    private var headsBySemanticKey: [String: Head] = [:]

    public init() {}

    public mutating func resetCapture() {
        headsBySemanticKey.removeAll(keepingCapacity: false)
    }

    public mutating func open(
        labelId: String,
        semanticKey: String
    ) -> CaptureCoachLabelLineageBinding {
        precondition(!labelId.isEmpty)
        precondition(!semanticKey.isEmpty)
        if let head = headsBySemanticKey[semanticKey] {
            headsBySemanticKey[semanticKey] = Head(
                baselineId: head.baselineId,
                latestLabelId: labelId)
            return CaptureCoachLabelLineageBinding(
                baselineId: head.baselineId,
                resumesLabelId: head.latestLabelId)
        }
        headsBySemanticKey[semanticKey] = Head(
            baselineId: labelId,
            latestLabelId: labelId)
        return CaptureCoachLabelLineageBinding(baselineId: labelId)
    }

    public static func semanticKey(
        processId: String?,
        declaredText: String
    ) -> String? {
        if let processId = canonicalComponent(processId) {
            return "process:\(processId)"
        }
        guard
            let text = canonicalComponent(
                declaredText.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")))
        else { return nil }
        return "declaration:\(text)"
    }

    private static func canonicalComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed =
            value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return collapsed.isEmpty ? nil : collapsed
    }
}
