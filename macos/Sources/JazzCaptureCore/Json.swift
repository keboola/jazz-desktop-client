import Foundation

/// Small JSON encoding helper shared across the core. `.withoutEscapingSlashes` keeps `url`
/// fields like `app://com.apple.finder` readable on the wire (no `\/` mangling), which the
/// OTLP attribute values and the activity-event contract rely on.
public enum JSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
