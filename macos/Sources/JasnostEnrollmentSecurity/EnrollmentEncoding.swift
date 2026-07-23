import Foundation

enum EnrollmentEncoding {
    private static let base64URLCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private static let keyIDPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9._-]{1,128}$")

    static func isValidKeyID(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return keyIDPattern.firstMatch(in: value, range: range)?.range == range
    }

    static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ value: String, maximumBytes: Int) -> Data? {
        guard
            !value.isEmpty,
            value.unicodeScalars.allSatisfy({ base64URLCharacters.contains($0) }),
            value.utf8.count <= (maximumBytes * 4 + 2) / 3
        else {
            return nil
        }
        var standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard
            let decoded = Data(base64Encoded: standard),
            decoded.count <= maximumBytes,
            encodeBase64URL(decoded) == value
        else {
            return nil
        }
        return decoded
    }

    static func canonicalJSONObject(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
