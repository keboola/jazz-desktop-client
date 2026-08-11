import Foundation

/// Privacy-preserving normalization for document context observed through AX/UIA/browser APIs.
/// Application identity is carried separately and callers must not derive a business system or
/// business-object identity from this value alone.
public enum ObservedDocumentURL {
    public static func sanitize(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed),
            let rawScheme = components.scheme
        else { return nil }
        let scheme = rawScheme.lowercased()
        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.isEmpty else { return nil }
            components.host = host.lowercased()
            return components.string
        case "file":
            // A local path often embeds a login name and machine-specific folders. The basename is
            // useful review context; the local hierarchy is neither portable nor necessary.
            guard let url = components.url else { return nil }
            let name = url.lastPathComponent
            guard !name.isEmpty else { return nil }
            var safe = URLComponents()
            safe.scheme = "file"
            safe.path = "/<local>/\(name)"
            return safe.string
        default:
            return nil
        }
    }

    public static func isClickableHTTP(_ value: String?) -> Bool {
        guard let value, let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            components.host?.isEmpty == false
        else { return false }
        return true
    }
}
