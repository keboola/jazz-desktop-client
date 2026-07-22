import Foundation

/// Hand-written OTLP/JSON wire models for the two export requests the agent sends to a
/// Keboola Data Stream: `ExportLogsServiceRequest` (one log record per ActivityEvent) and
/// `ExportTraceServiceRequest` (one `capture-session` span per session). Live-verified
/// 2026-06-13: Keboola accepts OTLP/JSON (`Content-Type: application/json`) on
/// `{streamEndpoint}/v1/logs` and `/v1/traces`, so no protobuf codegen is needed.
///
/// Only the fields the agent emits are modeled — these are encode-first types (decode
/// support exists for tests/fixtures, not for consuming arbitrary OTLP).
public enum Otlp {
    /// OTLP `AnyValue`, restricted to the four primitive encodings the contract uses:
    /// `{"stringValue": s}` | `{"boolValue": b}` | `{"intValue": "123"}` | `{"doubleValue": 1.5}`.
    /// Note the proto3 JSON mapping renders int64 as a STRING — Keboola requires exactly that
    /// (`{"intValue": 123}` as a bare number is tolerated on decode, never emitted).
    public enum AnyValue: Codable, Equatable, Sendable {
        case string(String)
        case bool(Bool)
        case int(Int64)
        case double(Double)

        private enum CodingKeys: String, CodingKey {
            case stringValue, boolValue, intValue, doubleValue
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .string(let s): try c.encode(s, forKey: .stringValue)
            case .bool(let b): try c.encode(b, forKey: .boolValue)
            // proto3 JSON: int64 serializes as a decimal string.
            case .int(let i): try c.encode(String(i), forKey: .intValue)
            case .double(let d): try c.encode(d, forKey: .doubleValue)
            }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if c.contains(.stringValue) {
                self = .string(try c.decode(String.self, forKey: .stringValue))
            } else if c.contains(.boolValue) {
                self = .bool(try c.decode(Bool.self, forKey: .boolValue))
            } else if c.contains(.intValue) {
                // Spec encoding is a string; accept a bare number too (lenient readers MUST).
                if let s = try? c.decode(String.self, forKey: .intValue), let i = Int64(s) {
                    self = .int(i)
                } else {
                    self = .int(try c.decode(Int64.self, forKey: .intValue))
                }
            } else if c.contains(.doubleValue) {
                self = .double(try c.decode(Double.self, forKey: .doubleValue))
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription:
                            "AnyValue: none of stringValue/boolValue/intValue/doubleValue present"
                    ))
            }
        }
    }

    /// One `{key, value}` attribute pair (OTLP attributes are arrays, not objects).
    public struct KeyValue: Codable, Equatable, Sendable {
        public var key: String
        public var value: AnyValue

        public init(key: String, value: AnyValue) {
            self.key = key
            self.value = value
        }
    }

    public struct Resource: Codable, Equatable, Sendable {
        public var attributes: [KeyValue]

        public init(attributes: [KeyValue]) {
            self.attributes = attributes
        }
    }

    /// Instrumentation scope; only the name is meaningful for this pipeline.
    public struct Scope: Codable, Equatable, Sendable {
        public var name: String

        public init(name: String) {
            self.name = name
        }
    }

    // MARK: - Logs (`POST {endpoint}/v1/logs`)

    public struct LogRecord: Codable, Equatable, Sendable {
        /// Unix nanos as a decimal string (proto3 JSON renders fixed64 as string).
        public var timeUnixNano: String
        public var observedTimeUnixNano: String
        public var severityText: String
        public var severityNumber: Int
        /// 32 lowercase hex chars — the session's trace; what lets logs JOIN traces.
        public var traceId: String
        /// 16 lowercase hex chars — the capture-session span id.
        public var spanId: String
        public var body: AnyValue
        public var attributes: [KeyValue]

        public init(
            timeUnixNano: String,
            observedTimeUnixNano: String,
            severityText: String,
            severityNumber: Int,
            traceId: String,
            spanId: String,
            body: AnyValue,
            attributes: [KeyValue]
        ) {
            self.timeUnixNano = timeUnixNano
            self.observedTimeUnixNano = observedTimeUnixNano
            self.severityText = severityText
            self.severityNumber = severityNumber
            self.traceId = traceId
            self.spanId = spanId
            self.body = body
            self.attributes = attributes
        }
    }

    public struct ScopeLogs: Codable, Equatable, Sendable {
        public var scope: Scope
        public var logRecords: [LogRecord]

        public init(scope: Scope, logRecords: [LogRecord]) {
            self.scope = scope
            self.logRecords = logRecords
        }
    }

    public struct ResourceLogs: Codable, Equatable, Sendable {
        public var resource: Resource
        public var scopeLogs: [ScopeLogs]

        public init(resource: Resource, scopeLogs: [ScopeLogs]) {
            self.resource = resource
            self.scopeLogs = scopeLogs
        }
    }

    public struct ExportLogsServiceRequest: Codable, Equatable, Sendable {
        public var resourceLogs: [ResourceLogs]

        public init(resourceLogs: [ResourceLogs]) {
            self.resourceLogs = resourceLogs
        }
    }

    // MARK: - Traces (`POST {endpoint}/v1/traces`)

    public struct Span: Codable, Equatable, Sendable {
        public var traceId: String
        public var spanId: String
        public var name: String
        /// proto enum `SpanKind`; the agent always emits 1 = SPAN_KIND_INTERNAL.
        public var kind: Int
        public var startTimeUnixNano: String
        public var endTimeUnixNano: String
        public var attributes: [KeyValue]

        public init(
            traceId: String,
            spanId: String,
            name: String,
            kind: Int,
            startTimeUnixNano: String,
            endTimeUnixNano: String,
            attributes: [KeyValue]
        ) {
            self.traceId = traceId
            self.spanId = spanId
            self.name = name
            self.kind = kind
            self.startTimeUnixNano = startTimeUnixNano
            self.endTimeUnixNano = endTimeUnixNano
            self.attributes = attributes
        }
    }

    public struct ScopeSpans: Codable, Equatable, Sendable {
        public var scope: Scope
        public var spans: [Span]

        public init(scope: Scope, spans: [Span]) {
            self.scope = scope
            self.spans = spans
        }
    }

    public struct ResourceSpans: Codable, Equatable, Sendable {
        public var resource: Resource
        public var scopeSpans: [ScopeSpans]

        public init(resource: Resource, scopeSpans: [ScopeSpans]) {
            self.resource = resource
            self.scopeSpans = scopeSpans
        }
    }

    public struct ExportTraceServiceRequest: Codable, Equatable, Sendable {
        public var resourceSpans: [ResourceSpans]

        public init(resourceSpans: [ResourceSpans]) {
            self.resourceSpans = resourceSpans
        }
    }
}
