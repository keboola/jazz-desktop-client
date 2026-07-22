import Foundation

/// Codable response models for the three Keboola HTTPS APIs the agent calls directly
/// (no local services on the capture path). Field shapes verified against the live stack
/// 2026-06-13 (`connection.europe-west3.gcp`) and against kbagent's live-tested Stream
/// client (`keboola_agent_cli/stream_client.py` + its fixtures); see also
/// `keboola/kbagent-stream-requirements.md` for the endpoint conventions.
///
/// Decode-only and deliberately lenient: every field the agent does not branch on is
/// optional, so an API adding fields (or a stack variant omitting one) never breaks setup.
public enum KeboolaAPI {
    // MARK: - GET {stack}/v2/storage/tokens/verify  (header: X-StorageApi-Token)

    /// Token verification — the one call that auto-detects the stack, project, and user.
    public struct TokenVerify: Decodable, Equatable, Sendable {
        public let id: String
        /// The token's own description; for admin (master) tokens this is the user's email.
        public let description: String?
        public let isMasterToken: Bool?
        public let owner: Owner
        public let creatorToken: CreatorToken?
        /// Present only on admin (master) tokens — its presence is a master signal too.
        public let admin: Admin?

        public struct Owner: Decodable, Equatable, Sendable {
            public let id: Int
            public let name: String
            public let region: String?
            /// "gcp" / "aws" / "azure" — decides the Files upload leg (GCS PUT vs S3).
            public let fileStorageProvider: String?
        }

        public struct CreatorToken: Decodable, Equatable, Sendable {
            public let id: Int?
            /// The creating admin's email on tokens created from the UI.
            public let description: String?
        }

        public struct Admin: Decodable, Equatable, Sendable {
            public let id: Int?
            public let name: String?
            public let role: String?
        }

        /// Master = explicit flag OR the `admin` key (some responses carry only the latter).
        /// Branches the onboarding: master → Stream API find-or-create; else manual URL field.
        public var isMaster: Bool { (isMasterToken ?? false) || admin != nil }

        /// Best-effort user email for `enduser.id` prefill: the creator token's description
        /// (UI-created tokens) or the token's own description (admin tokens) — whichever
        /// looks like an email. nil → the Settings userEmail override stays required.
        public var userEmail: String? {
            if let d = creatorToken?.description, d.contains("@") { return d }
            if let d = description, d.contains("@") { return d }
            return nil
        }
    }

    // MARK: - POST {stack}/v2/storage/files/prepare  (json: name, tags, federationToken:true)

    /// File-upload slot. On GCP stacks `gcsUploadParams` carries federation credentials for
    /// a plain `PUT` to GCS (`Authorization: Bearer access_token`). The AWS/Azure legs are
    /// not modeled — current stack is GCP (check `provider` before assuming GCS).
    public struct FilesPrepare: Decodable, Equatable, Sendable {
        /// Numeric file id — events reference it as `screenshot_id` (stringified).
        public let id: Int
        public let name: String?
        public let provider: String?
        public let region: String?
        /// Default 15 unless `isPermanent` was requested.
        public let maxAgeDays: Int?
        public let isPermanent: Bool?
        public let gcsUploadParams: GCSUploadParams?

        public struct GCSUploadParams: Decodable, Equatable, Sendable {
            /// Short-lived GCS federation token — SECRET: never log, never persist.
            public let accessToken: String
            public let bucket: String
            public let key: String
            public let tokenType: String?
            public let expiresIn: Int?
            public let projectId: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case bucket, key
                case tokenType = "token_type"
                case expiresIn = "expires_in"
                case projectId
            }
        }
    }

    // MARK: - GET {stack}/v2/storage/files?tags[]=…  (header: X-StorageApi-Token)

    /// One item from the file list — used to find an already-uploaded clip for a label
    /// (narration dedup) so a retry/restart never re-uploads or duplicates it. `url` is a
    /// short-lived signed GCS read URL: a HEAD against it returns 200 when the object exists
    /// (a COMPLETE upload) or 404 when it does not (a DANGLING prepare-only record — the file
    /// id was minted but the GCS PUT never landed). `sizeBytes` is unreliable here (the agent
    /// doesn't send it to prepare, so Keboola leaves it null), hence the HEAD probe.
    public struct FileListItem: Decodable, Equatable, Sendable {
        public let id: Int
        public let name: String?
        public let url: String?
        public let tags: [String]?
        public let created: String?
    }

    /// Keep only files carrying EVERY one of ``requiredTags``. The Storage Files API filters
    /// multiple ``tags[]`` with **OR** (a file matches if it has ANY of them), so a query for
    /// ``["narration", "label:<id>"]`` comes back as ALL ``narration`` files — the caller MUST
    /// AND-filter to isolate the file actually tagged with that specific label. Regression this
    /// guards: narration dedup matched on the shared ``narration`` tag, "found" an unrelated old
    /// clip, reused it, and discarded the fresh recording — so every workshop was processed from
    /// stale audio.
    public static func filesMatchingAllTags(
        _ files: [FileListItem], _ requiredTags: [String]
    ) -> [FileListItem] {
        files.filter { file in
            let present = Set(file.tags ?? [])
            return requiredTags.allSatisfy(present.contains)
        }
    }

    // MARK: - Stream API  https://stream.{host}/v1/...  (header: X-StorageApi-Token, MASTER)

    /// One Data Stream source. For `type == "otlp"` the full ingest endpoint (incl. the
    /// path-embedded secret) is `otlp.url`; `otlp.baseUrl` is the same URL without the
    /// secret. SECRET-HANDLING: the full URL goes to the Keychain only — never logs/defaults.
    public struct StreamSource: Decodable, Equatable, Sendable {
        public let sourceId: String
        public let name: String?
        public let type: String?
        public let description: String?
        public let otlp: OtlpSettings?
        public let http: HttpSettings?

        public struct OtlpSettings: Decodable, Equatable, Sendable {
            public let url: String?
            public let baseUrl: String?
            public let secret: String?
        }

        public struct HttpSettings: Decodable, Equatable, Sendable {
            public let url: String?
        }

        /// The endpoint the OTLP exporter should POST under (`<endpoint>/v1/logs|traces`).
        public var otlpEndpoint: String? { otlp?.url ?? http?.url }
    }

    /// `GET /v1/branches/{branchId}/sources` envelope.
    public struct StreamSourceList: Decodable, Equatable, Sendable {
        public let sources: [StreamSource]
    }

    /// Async task returned by source create/delete (HTTP 202) and by `GET /v1/tasks/{id}`.
    /// `error` is decoded leniently (string or object) — the API does not pin its shape.
    public struct StreamTask: Decodable, Equatable, Sendable {
        public let taskId: String?
        public let isFinished: Bool?
        public let status: String?
        /// Canonical poll URL; fall back to `/v1/tasks/{taskId}` when absent.
        public let url: String?
        public let error: String?
        public let outputs: Outputs?

        public struct Outputs: Decodable, Equatable, Sendable {
            public let sourceId: String?
            public let url: String?
        }

        public var finished: Bool { isFinished ?? false }
        public var failed: Bool { error != nil || status == "error" }

        enum CodingKeys: String, CodingKey {
            case taskId, isFinished, status, url, error, outputs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
            isFinished = try c.decodeIfPresent(Bool.self, forKey: .isFinished)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            outputs = try c.decodeIfPresent(Outputs.self, forKey: .outputs)
            if let message = try? c.decodeIfPresent(String.self, forKey: .error) {
                error = message
            } else if let nested = try? c.decodeIfPresent(ErrorObject.self, forKey: .error) {
                error = nested.message ?? nested.error
            } else {
                error = nil
            }
        }

        /// Nested `error` object variant (mirrors the standalone API error envelope).
        private struct ErrorObject: Decodable {
            let message: String?
            let error: String?
        }
    }

    /// Error envelope shared by the Storage and Stream APIs. Live-verified Stream example:
    /// `{"statusCode": 401, "error": "stream.api.masterTokenRequired", "message": "..."}`.
    public struct APIError: Decodable, Equatable, Sendable {
        public let statusCode: Int?
        public let error: String?
        public let message: String?

        /// The Stream API's "you need a master token" code — onboarding switches from
        /// find-or-create to the manual stream-URL field on exactly this.
        public var isMasterTokenRequired: Bool { error == "stream.api.masterTokenRequired" }
    }
}

/// Hygiene for the user-pasted OTLP ingest URL (the manual, non-master-token onboarding
/// path). Pure string handling, unit-tested — the pasted URL embeds the stream secret, so
/// the caller stores the normalized form in the Keychain and never logs it.
public enum StreamEndpoint {
    /// Trim whitespace, strip a trailing per-signal path (`/v1/logs` or `/v1/traces` —
    /// people copy the full signal URL from curl examples), and drop trailing slashes.
    /// Returns nil unless the result parses as an http(s) URL with a host — the cheap
    /// local check before the network validation POST.
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/v1/logs", "/v1/traces"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard
            let url = URL(string: s),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host?.isEmpty == false
        else { return nil }
        return s
    }
}
