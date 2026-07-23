import Foundation

/// Capture-all policy with a privacy denylist: the whole desktop is captured during a
/// session (process discovery spans many apps you can't predict), EXCEPT apps the user
/// excludes (password managers, banking, …). Secure fields are always masked on top of this.
/// Consent is at the session level — the user explicitly starts/stops capture.
public struct RedactionPolicy: Sendable {
    public var denylist: Set<String>

    public init(denylist: Set<String> = []) {
        self.denylist = denylist
    }

    /// Capture every app except those on the denylist. A nil bundle id can't be attributed,
    /// so it is skipped.
    public func isCaptureAllowed(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return !denylist.contains(bundleID)
    }

    /// Re-evaluate after Accessibility resolves the real owner. The actual owner always wins over
    /// an earlier Workspace/frontmost hint, closing focused-field and overlay attribution leaks.
    public func isCaptureAllowed(
        preliminaryBundleID: String?,
        actualOwnerBundleID: String?
    ) -> Bool {
        isCaptureAllowed(bundleID: actualOwnerBundleID ?? preliminaryBundleID)
    }
}

public enum Sensitivity {
    /// AX subroles that are always sensitive (password / secure entry).
    static let secureSubroles: Set<String> = ["AXSecureTextField"]
    private static let sensitiveLabelTokens = [
        "password", "passcode", "secret", "token", "api key", "apikey",
        "card number", "cvv", "ssn", "pin", "credential",
    ]

    /// A field is sensitive if it's a secure text field, or its label looks like a secret.
    public static func isSensitiveField(role: String?, subrole: String?, label: String?) -> Bool {
        if let subrole, secureSubroles.contains(subrole) {
            return true
        }
        let haystack = (label ?? "").lowercased()
        return !haystack.isEmpty && sensitiveLabelTokens.contains { haystack.contains($0) }
    }

    /// Trim + cap a captured string so a stray huge AX value never bloats an event.
    public static func sanitize(_ value: String?, maxLength: Int = 200) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) + "…" : trimmed
    }

    /// Redact a string the user TYPED before it is stored: mask e-mail addresses and long digit
    /// runs (card / SSN / phone / PIN-like), then trim + cap. Secure/sensitive fields are dropped
    /// entirely upstream (the typing is never buffered); this is the second line of defence for
    /// ordinary fields. Raw secrets are never stored or exported. Guided execution consumes only
    /// an approved RunbookVersion and never treats captured text as an instruction to type.
    public static func redactTyped(_ value: String?, maxLength: Int = 200) -> String? {
        guard let value else { return nil }
        let noEmail = value.replacingOccurrences(
            of: #"[\w.+-]+@[\w.-]+\.\w+"#, with: "•••@•••", options: .regularExpression
        )
        return sanitize(maskDigitRuns(noEmail, minRun: 7), maxLength: maxLength)
    }

    /// Replace runs of >= ``minRun`` ASCII digits with same-length bullets, leaving short numbers
    /// (years, quantities, small calculator input) intact.
    static func maskDigitRuns(_ string: String, minRun: Int) -> String {
        var out = ""
        var run = ""
        func flush() {
            out += run.count >= minRun ? String(repeating: "•", count: run.count) : run
            run = ""
        }
        for ch in string {
            if ch.isASCII, ch.isNumber {
                run.append(ch)
            } else {
                flush()
                out.append(ch)
            }
        }
        flush()
        return out
    }
}
