import Foundation
import JasnostCaptureCore

/// Direct HTTPS client for the three Keboola APIs the agent calls with no local
/// services on the capture path:
///
///   1. Storage `tokens/verify` — auto-detects the stack/project/user from one pasted token.
///   2. Files `prepare` + a plain GCS PUT — screenshots and narration audio.
///   3. Stream API source find-or-create — the master-token onboarding path that resolves
///      the OTLP ingest endpoint.
///
/// Secret handling: the Storage token is read from the Keychain at request time and sent
/// ONLY as the `X-StorageApi-Token` header — never argv, never logs. GCS federation
/// credentials stay in memory for the duration of one upload (they expire anyway).
/// Every request carries a timeout — a hung network call must never wedge capture.
struct KeboolaClient {
    enum ClientError: Error, CustomStringConvertible {
        case noToken
        case timeout
        case http(Int, String)
        case transport(String)
        case badResponse(String)
        /// The Stream API refused with `stream.api.masterTokenRequired` — onboarding falls
        /// back to a manual stream-URL field on exactly this.
        case masterTokenRequired

        var description: String {
            switch self {
            case .noToken: return "No Keboola token stored (connect in Settings)"
            case .timeout: return "Keboola request timed out"
            case let .http(code, body): return "Keboola HTTP \(code): \(body.prefix(200))"
            case let .transport(msg): return "Keboola transport error: \(msg)"
            case let .badResponse(msg): return "Unexpected Keboola response: \(msg)"
            case .masterTokenRequired:
                return "This token is not a master token — paste the stream URL manually"
            }
        }
    }

    /// Operational timeouts (seconds): small JSON exchanges get a tight budget; the blob
    /// PUT gets its own larger one. Values per DESIGN (10s connect / 30s resource / 60s upload).
    private enum Timeouts {
        static let request: TimeInterval = 10
        static let resource: TimeInterval = 30
        static let upload: TimeInterval = 60
        /// Narration clips can be large (an hour of audio ≈ tens of MB) and ship over a weak
        /// network. They use an IDLE-based budget: `timeoutIntervalForRequest` is the gap
        /// BETWEEN bytes (the timer resets on every chunk received), so a slow-but-steady
        /// upload never trips it — only a genuinely stalled connection does. The resource cap
        /// is generous so a big clip can finish within the ~1h federation-token window.
        static let narrationIdle: TimeInterval = 30
        static let narrationResource: TimeInterval = 3600
    }

    /// How long to poll the Stream API's async create task before giving up.
    private static let taskPollBudget: TimeInterval = 30
    private static let taskPollInterval: TimeInterval = 1

    /// Shared session for JSON exchanges (ephemeral: no cookie/cache persistence of
    /// anything token-adjacent).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Timeouts.request
        config.timeoutIntervalForResource = Timeouts.resource
        return URLSession(configuration: config)
    }()

    /// Separate session for blob uploads (larger whole-call budget). Used for screenshots.
    private static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Timeouts.request
        config.timeoutIntervalForResource = Timeouts.upload
        return URLSession(configuration: config)
    }()

    /// Upload session for narration blobs: an idle-based request timeout (resets on every
    /// byte received) plus a generous resource cap, so a large clip on a slow link uploads
    /// instead of dying at the 60s screenshot budget. See ``Timeouts/narrationIdle``.
    private static let narrationUploadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Timeouts.narrationIdle
        config.timeoutIntervalForResource = Timeouts.narrationResource
        return URLSession(configuration: config)
    }()

    /// Session for the GCS HEAD completeness probe (narration dedup): a tight budget — a HEAD
    /// is a metadata round-trip, not a transfer.
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Timeouts.request
        config.timeoutIntervalForResource = Timeouts.resource
        return URLSession(configuration: config)
    }()

    /// Storage API base URL of the project's stack (e.g. `connection.europe-west3.gcp...`).
    var stackURL: String
    /// Token source — injectable for tests; defaults to the Keychain (never argv/logs).
    var token: () -> String? = { (try? Keychain.get(account: Keychain.Account.kbcToken)) ?? nil }

    init(stackURL: String) {
        self.stackURL = stackURL.hasSuffix("/") ? String(stackURL.dropLast()) : stackURL
    }

    // MARK: - Token verify (stack auto-detection)

    /// Try `GET {stack}/v2/storage/tokens/verify` across the known stacks; the first 200
    /// wins — this turns one pasted token into stack + project + user identity. Returns nil
    /// when no stack accepts the token (wrong token, or a stack we don't know).
    static func verifyToken(
        token: String, stacks: [String] = AgentSettings.knownStacks.map(\.url)
    ) async -> (stackURL: String, verify: KeboolaAPI.TokenVerify)? {
        for stack in stacks {
            let base = stack.hasSuffix("/") ? String(stack.dropLast()) : stack
            guard let url = URL(string: base + "/v2/storage/tokens/verify") else { continue }
            var req = URLRequest(url: url, timeoutInterval: Timeouts.request)
            req.setValue(token, forHTTPHeaderField: "X-StorageApi-Token")
            guard
                let (data, response) = try? await session.data(for: req),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let verify = try? JSONDecoder().decode(KeboolaAPI.TokenVerify.self, from: data)
            else { continue }  // wrong stack / bad token: try the next stack
            return (base, verify)
        }
        return nil
    }

    // MARK: - Files (prepare + GCS upload)

    /// `POST /v2/storage/files/prepare` — returns the file id (the event's `screenshot_id`)
    /// plus short-lived GCS federation credentials for a direct upload.
    func prepareFile(
        name: String, tags: [String], isPermanent: Bool
    ) async throws -> KeboolaAPI.FilesPrepare {
        var req = try request(path: "/v2/storage/files/prepare", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // federationToken:true is what makes the response carry direct-upload credentials.
        let body: [String: Any] = [
            "name": name,
            "tags": tags,
            "isPermanent": isPermanent,
            "federationToken": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await Self.send(req, session: Self.session)
        return try Self.decode(KeboolaAPI.FilesPrepare.self, from: data)
    }

    /// Plain PUT to GCS with the federation bearer token (screenshots). Single-shot — the
    /// federation token grants only an XML-API object PUT, not a resumable session. The
    /// AWS/Azure legs are unbuilt (current stack is GCP; `prepareFile().provider` says which).
    static func uploadToGCS(
        data: Data, params: KeboolaAPI.FilesPrepare.GCSUploadParams, contentType: String
    ) async throws {
        try await uploadToGCS(
            data: data, params: params, contentType: contentType, session: uploadSession)
    }

    /// Plain PUT to GCS for a large narration clip — same single-shot upload but on the
    /// idle-based ``narrationUploadSession`` so a big clip over a slow link isn't killed by the
    /// 60s screenshot budget. On a hard connection drop this throws and the caller re-uploads
    /// from scratch (the durable spool keeps the audio); there is no resumable session because
    /// the federation token can't drive one.
    static func uploadLargeBlobToGCS(
        data: Data, params: KeboolaAPI.FilesPrepare.GCSUploadParams, contentType: String
    ) async throws {
        try await uploadToGCS(
            data: data, params: params, contentType: contentType,
            session: narrationUploadSession)
    }

    private static func uploadToGCS(
        data: Data, params: KeboolaAPI.FilesPrepare.GCSUploadParams, contentType: String,
        session: URLSession
    ) async throws {
        // The key contains `/` path separators that must survive; everything else escapes.
        let key =
            params.key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? params.key
        guard let url = URL(string: "https://storage.googleapis.com/\(params.bucket)/\(key)")
        else { throw ClientError.transport("bad GCS object URL") }
        var req = URLRequest(url: url)  // session config owns the timeout (idle vs whole-call)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(params.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await session.upload(for: req, from: data)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ClientError.http(code, String(decoding: body.prefix(200), as: UTF8.self))
        }
    }

    /// `GET /v2/storage/files?tags[]=…` — list files matching ALL given tags. Used for
    /// narration dedup: find any already-prepared clip for a `label:<id>` so a retry/restart
    /// never blindly re-prepares (the bug that left duplicate dangling records). Returns [] on
    /// a transport/decopde failure rather than throwing — dedup is best-effort.
    func listFiles(tags: [String]) async -> [KeboolaAPI.FileListItem] {
        guard var comps = URLComponents(string: stackURL + "/v2/storage/files") else { return [] }
        comps.queryItems =
            tags.map { URLQueryItem(name: "tags[]", value: $0) }
            + [URLQueryItem(name: "limit", value: "100")]
        guard let urlString = comps.string,
            let req = try? absoluteRequest(urlString, method: "GET"),
            let data = try? await Self.send(req, session: Self.session),
            let items = try? JSONDecoder().decode([KeboolaAPI.FileListItem].self, from: data)
        else { return [] }
        // The API treats multiple `tags[]` as OR, so `["narration", "label:<id>"]` returns every
        // `narration` file. AND-filter to the files carrying ALL requested tags — without this the
        // narration dedup matched any old clip via the shared `narration` tag and reused it.
        return KeboolaAPI.filesMatchingAllTags(items, tags)
    }

    /// HEAD the signed GCS read URL from a file listing: `true` when the object exists (a
    /// COMPLETE upload), `false` on 404 (a DANGLING prepare-only record — no bytes). nil when
    /// the answer is uncertain (network error / other status) so the caller doesn't act on a
    /// guess. The signed URL is self-contained — no Authorization header needed.
    static func gcsObjectExists(signedURL: String) async -> Bool? {
        guard let url = URL(string: signedURL) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        guard let (_, response) = try? await probeSession.data(for: req),
            let code = (response as? HTTPURLResponse)?.statusCode
        else { return nil }
        switch code {
        case 200..<300: return true
        case 404: return false
        default: return nil  // 403/5xx/etc — don't infer presence either way
        }
    }

    /// `DELETE /v2/storage/files/{id}` — remove a Storage file record. Used to clean up a
    /// dangling record after a failed narration PUT so retries never accumulate empty files
    /// (the project token may delete its own files). Throws on a non-2xx so the caller can
    /// log-and-continue (a failed cleanup is non-fatal — the dedup sweep catches it later).
    func deleteFile(id: Int) async throws {
        let req = try request(path: "/v2/storage/files/\(id)", method: "DELETE")
        _ = try await Self.send(req, session: Self.session)
    }

    // (The old combined prepare+PUT `uploadFile` was removed: narration now splits prepare and
    // PUT so a failed PUT can delete its dangling file id, and screenshots already split them.)

    // MARK: - Stream endpoint validation (manual onboarding path)

    /// Validate a pasted OTLP ingest URL by POSTing an empty-but-well-formed OTLP/JSON
    /// payload to `<endpoint>/v1/logs`. A 2xx proves the URL (incl. its path-embedded
    /// secret) without shipping any data. Returns nil when accepted, else a short error —
    /// never echoing the URL itself (it embeds the stream secret).
    static func validateStreamEndpoint(_ endpoint: String) async -> String? {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: base + "/v1/logs") else {
            return "That doesn't look like a valid stream URL"
        }
        var req = URLRequest(url: url, timeoutInterval: Timeouts.request)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"resourceLogs":[]}"#.utf8)
        do {
            let (data, response) = try await session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                return "Stream answered HTTP \(code): \(String(decoding: data.prefix(120), as: UTF8.self))"
            }
            return nil
        } catch {
            return "Could not reach the stream: \(error.localizedDescription)"
        }
    }

    // MARK: - Stream API (master-token onboarding path)

    /// `https://stream.{host}` for this stack (`connection.<region>...` → `stream.<region>...`).
    static func streamAPIBase(forStack stackURL: String) -> String? {
        guard var comps = URLComponents(string: stackURL), let host = comps.host else {
            return nil
        }
        let prefix = "connection."
        comps.host =
            host.hasPrefix(prefix) ? "stream." + host.dropFirst(prefix.count) : "stream." + host
        comps.path = ""
        return comps.string
    }

    /// Find the OTLP source named ``name`` on the default branch, creating it if missing
    /// (poll the async create task), and return its detail — `otlpEndpoint` carries the full
    /// ingest URL incl. the path-embedded secret (Keychain only, never logs). Requires a
    /// MASTER token; a non-master token surfaces as ``ClientError/masterTokenRequired``.
    func findOrCreateStreamSource(name: String) async throws -> KeboolaAPI.StreamSource {
        guard let base = Self.streamAPIBase(forStack: stackURL) else {
            // Don't echo the URL — it adds no user-actionable detail and keeps URL-shaped
            // values out of surfaced error strings on principle.
            throw ClientError.transport("cannot derive the Stream API host: unexpected stack URL")
        }
        let sourcesURL = base + "/v1/branches/default/sources"

        // 1. Find — list is cheap and idempotent; detail is fetched anyway because the list
        //    may omit the secret-bearing URL.
        let listData = try await Self.send(
            try absoluteRequest(sourcesURL, method: "GET"), session: Self.session)
        let list = try Self.decode(KeboolaAPI.StreamSourceList.self, from: listData)
        if let existing = list.sources.first(where: { $0.name == name && $0.type == "otlp" }) {
            return try await streamSourceDetail(base: base, sourceId: existing.sourceId)
        }

        // 2. Create — HTTP 202 + async task; poll until it finishes.
        var createReq = try absoluteRequest(sourcesURL, method: "POST")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name, "type": "otlp",
        ])
        let taskData = try await Self.send(createReq, session: Self.session)
        let task = try Self.decode(KeboolaAPI.StreamTask.self, from: taskData)
        let finished = try await pollTask(base: base, task: task)
        guard let sourceId = finished.outputs?.sourceId else {
            // The task finished but did not name the source — re-list and find it by name.
            let again = try await Self.send(
                try absoluteRequest(sourcesURL, method: "GET"), session: Self.session)
            let sources = try Self.decode(KeboolaAPI.StreamSourceList.self, from: again).sources
            guard let created = sources.first(where: { $0.name == name && $0.type == "otlp" })
            else { throw ClientError.badResponse("source create finished but source not found") }
            return try await streamSourceDetail(base: base, sourceId: created.sourceId)
        }
        return try await streamSourceDetail(base: base, sourceId: sourceId)
    }

    /// `GET /v1/branches/default/sources/{id}` — full source detail incl. the OTLP URL.
    private func streamSourceDetail(
        base: String, sourceId: String
    ) async throws -> KeboolaAPI.StreamSource {
        let data = try await Self.send(
            try absoluteRequest("\(base)/v1/branches/default/sources/\(sourceId)", method: "GET"),
            session: Self.session)
        return try Self.decode(KeboolaAPI.StreamSource.self, from: data)
    }

    /// Poll an async Stream API task to completion (bounded by ``taskPollBudget``).
    private func pollTask(
        base: String, task: KeboolaAPI.StreamTask
    ) async throws -> KeboolaAPI.StreamTask {
        var current = task
        let deadline = Date().addingTimeInterval(Self.taskPollBudget)
        while !current.finished {
            if current.failed { throw ClientError.badResponse(current.error ?? "task failed") }
            guard Date() < deadline else { throw ClientError.timeout }
            try await Task.sleep(nanoseconds: UInt64(Self.taskPollInterval * 1_000_000_000))
            // Prefer the task's own canonical poll URL; fall back to /v1/tasks/{id}.
            guard let pollURL = current.url ?? task.url ?? task.taskId.map({ "\(base)/v1/tasks/\($0)" })
            else { throw ClientError.badResponse("task has no poll URL") }
            let data = try await Self.send(
                try absoluteRequest(pollURL, method: "GET"), session: Self.session)
            current = try Self.decode(KeboolaAPI.StreamTask.self, from: data)
        }
        if current.failed { throw ClientError.badResponse(current.error ?? "task failed") }
        return current
    }

    // MARK: - Plumbing

    private func request(path: String, method: String) throws -> URLRequest {
        try absoluteRequest(stackURL + path, method: method)
    }

    /// Build a tokened request for an absolute URL (Storage and Stream APIs share the
    /// `X-StorageApi-Token` header convention).
    private func absoluteRequest(_ urlString: String, method: String) throws -> URLRequest {
        guard let t = token(), !t.isEmpty else { throw ClientError.noToken }
        guard let url = URL(string: urlString) else {
            throw ClientError.transport("bad Keboola URL")
        }
        var req = URLRequest(url: url, timeoutInterval: Timeouts.request)
        req.httpMethod = method
        req.setValue(t, forHTTPHeaderField: "X-StorageApi-Token")
        return req
    }

    /// Send + map non-2xx into typed errors (incl. the master-token signal). Error bodies
    /// are API messages — they carry no secrets and are safe to surface.
    private static func send(_ req: URLRequest, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if let apiError = try? JSONDecoder().decode(KeboolaAPI.APIError.self, from: data) {
                if apiError.isMasterTokenRequired { throw ClientError.masterTokenRequired }
                throw ClientError.http(code, apiError.message ?? apiError.error ?? "")
            }
            throw ClientError.http(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ClientError.badResponse("\(T.self) decode failed: \(error)")
        }
    }
}

/// Race ``operation`` against a deadline (used for the screenshot prepare's 3s budget —
/// the click path must never wait long on the network). The losing task is cancelled;
/// URLSession requests honor cancellation.
func withTimeout<T: Sendable>(
    seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw KeboolaClient.ClientError.timeout
        }
        // First finisher wins (the result or the timeout error); cancel the loser.
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
