import Foundation

/// The device recording plan — the DECISION half (`device-recording-plan-v1`).
///
/// An enrolled device asks the Data App what it should record: `GET …/api/device/recording-plan`,
/// authenticated exactly like archive intents (the device token in `X-StorageApi-Token` plus
/// `X-Jazz-Device-Id`). The answer carries the enrolled Area's declared process inventory, which
/// feeds the label panel's process picker without the Storage-Files tag lookup that pasted-token
/// installs still use (``RegistryFetcher``).
///
/// Everything here is pure Foundation and unit-tested in CI: route derivation, request headers and
/// the tolerant response decoding. The executable target (``DeviceRecordingPlanHTTPClient``) owns
/// the URLSession call and the Keychain read.
public enum JazzDeviceRecordingPlanError: Error, Equatable, CustomStringConvertible {
    /// The enrollment route cannot yield a recording-plan endpoint.
    case invalidRoute
    /// The response is not a version-1 plan for THIS device and company.
    case invalidResponse

    public var description: String {
        switch self {
        case .invalidRoute:
            "The device recording plan requires a Jazz Archive enrollment."
        case .invalidResponse:
            "The device recording plan did not match this device's enrollment."
        }
    }
}

// MARK: - Route

/// The recording-plan endpoint, derived like every other native route: from the exact enrolled
/// archive-ingest authority, never from a browser-supplied or user-editable host. Any deployment
/// path prefix is preserved byte-for-byte; only the terminal API resource is replaced.
public struct JazzDeviceRecordingPlanRoute: Equatable, Sendable {
    static let archiveSuffix = "/api/archive-ingests"
    static let planSuffix = "/api/device/recording-plan"

    /// A plan is a handful of Areas and their declared processes — small by construction.
    public static let maximumResponseBytes = 256 * 1_024

    public let url: URL
    public let deviceId: String
    public let companyId: String

    public init(routeBinding: JazzArchiveUploadRouteBinding) throws {
        guard routeBinding.hasDeliveryAuthority,
            var components = URLComponents(string: routeBinding.ingestEndpoint),
            JazzArchiveControlPlaneURL.normalize(routeBinding.ingestEndpoint)
                == routeBinding.ingestEndpoint,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.percentEncodedPath.hasSuffix(Self.archiveSuffix)
        else { throw JazzDeviceRecordingPlanError.invalidRoute }
        components.percentEncodedPath =
            String(components.percentEncodedPath.dropLast(Self.archiveSuffix.count))
            + Self.planSuffix
        guard let url = components.url,
            let scheme = url.scheme?.lowercased(),
            scheme == "https"
                || (scheme == "http"
                    && ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")),
            url.query == nil,
            url.fragment == nil
        else { throw JazzDeviceRecordingPlanError.invalidRoute }
        self.url = url
        deviceId = routeBinding.scope.deviceId
        companyId = routeBinding.scope.companyId
    }

    /// One credential-bearing GET, built in memory for exactly one attempt. The token is read from
    /// the caller's provider per attempt and is never retained by the route.
    public func request(
        credential: JazzArchiveScopedDeviceCredential,
        timeout: TimeInterval = 10
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(deviceId, forHTTPHeaderField: "X-Jazz-Device-Id")
        credential.withValue {
            request.setValue($0, forHTTPHeaderField: "X-StorageApi-Token")
        }
        return request
    }
}

// MARK: - Response

/// Client-side view of `device-recording-plan-v1`. Decoded **tolerantly**, like
/// ``AreaRegistry``: unknown fields are ignored, optional fields default, and a malformed list
/// entry is skipped rather than failing the whole plan. Only the identity fields are strict —
/// `schemaVersion` must be 1 and `deviceId`/`companyId` must be present, so a plan can be bound
/// to the enrollment that asked for it (``validate(for:)``).
public struct JazzDeviceRecordingPlan: Decodable, Equatable, Sendable {
    public static let schemaVersion = 1

    /// One declared process (`{processId, name, description?}`) — the same shape as the Area
    /// registry's inventory entry, so the same tolerant decoder serves both.
    public typealias DeclaredProcess = AreaRegistry.Process

    public struct AreaRef: Decodable, Equatable, Sendable {
        public var areaId: String
        public var name: String

        enum CodingKeys: String, CodingKey {
            case areaId, name
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            areaId = try c.decodeIfPresent(String.self, forKey: .areaId) ?? ""
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        }
    }

    public struct Area: Decodable, Equatable, Sendable {
        public var areaId: String
        public var name: String
        public var declaredProcesses: [DeclaredProcess]

        enum CodingKeys: String, CodingKey {
            case areaId, name, declaredProcesses
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            areaId = try c.decodeIfPresent(String.self, forKey: .areaId) ?? ""
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            declaredProcesses = JazzDeviceRecordingPlan.processes(c, .declaredProcesses)
        }
    }

    public struct Person: Decodable, Equatable, Sendable {
        public var personId: String
        public var displayName: String

        enum CodingKeys: String, CodingKey {
            case personId, displayName
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            personId = try c.decode(String.self, forKey: .personId)
            displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
        }
    }

    /// Whether the device's person binding is settled. A value this client does not know yet
    /// decodes as ``unknown`` instead of failing the plan.
    public enum BindingState: String, Decodable, Equatable, Sendable {
        case unbound, proposed, confirmed, unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = BindingState(rawValue: raw) ?? .unknown
        }
    }

    public struct Assignment: Decodable, Equatable, Sendable {
        public var assignmentId: String
        public var areaId: String
        public var processId: String
        public var processLabel: String?
        public var state: String

        enum CodingKeys: String, CodingKey {
            case assignmentId, areaId, processId, processLabel, state
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            assignmentId = try c.decode(String.self, forKey: .assignmentId)
            areaId = try c.decodeIfPresent(String.self, forKey: .areaId) ?? ""
            processId = try c.decodeIfPresent(String.self, forKey: .processId) ?? ""
            processLabel = try? c.decodeIfPresent(String.self, forKey: .processLabel)
            state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? ""
        }
    }

    public var schemaVersion: Int
    public var deviceId: String
    public var companyId: String
    /// The enrolled Area; nil when the device is company-scoped only.
    public var area: AreaRef?
    public var areas: [Area]
    /// The enrolled Area's declared inventory.
    public var declaredProcesses: [DeclaredProcess]
    public var person: Person?
    public var bindingState: BindingState
    public var assigned: [Assignment]
    public var minClientVersion: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, deviceId, companyId, area, areas, declaredProcesses, person
        case bindingState, assigned, minClientVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        companyId = try c.decode(String.self, forKey: .companyId)
        area = try? c.decodeIfPresent(AreaRef.self, forKey: .area)
        let areaEntries = (try? c.decodeIfPresent([Failable<Area>].self, forKey: .areas)) ?? nil
        areas = (areaEntries ?? []).compactMap(\.value).filter { !$0.areaId.isEmpty }
        declaredProcesses = Self.processes(c, .declaredProcesses)
        person = try? c.decodeIfPresent(Person.self, forKey: .person)
        bindingState =
            (try? c.decodeIfPresent(BindingState.self, forKey: .bindingState)) ?? .unbound
        let assignmentEntries =
            (try? c.decodeIfPresent([Failable<Assignment>].self, forKey: .assigned)) ?? nil
        assigned = (assignmentEntries ?? []).compactMap(\.value)
        minClientVersion = try? c.decodeIfPresent(String.self, forKey: .minClientVersion)
    }

    /// Lossy per-element decode shared by the top-level and per-Area inventories. Entries without
    /// both a processId and a name are unusable as picks, exactly as in ``AreaRegistry``.
    fileprivate static func processes<K: CodingKey>(
        _ c: KeyedDecodingContainer<K>, _ key: K
    ) -> [DeclaredProcess] {
        let entries = (try? c.decodeIfPresent([Failable<DeclaredProcess>].self, forKey: key)) ?? nil
        return (entries ?? [])
            .compactMap(\.value)
            .filter { !$0.processId.isEmpty && !$0.name.isEmpty }
    }

    /// Decode a plan, or nil when the bytes are not a version-1 plan object.
    public static func parse(data: Data) -> JazzDeviceRecordingPlan? {
        guard let plan = try? JSONDecoder().decode(JazzDeviceRecordingPlan.self, from: data),
            plan.schemaVersion == schemaVersion
        else { return nil }
        return plan
    }

    /// A plan only counts when it is about the device and company that asked. Scope comes from the
    /// device token server-side; this is the response-binding assertion on our side.
    public func validate(for route: JazzDeviceRecordingPlanRoute) throws {
        guard schemaVersion == Self.schemaVersion,
            deviceId == route.deviceId,
            companyId == route.companyId
        else { throw JazzDeviceRecordingPlanError.invalidResponse }
    }

    /// The declared process choices for ``areaId`` in declaration order, or nil when this plan
    /// says nothing about that Area (the caller then falls back to the Files registry lookup).
    /// For the enrolled Area the top-level `declaredProcesses` is authoritative; an entry in
    /// `areas` is used for any other Area the device may record into. An Area the plan names with
    /// no declared processes returns `[]` — Explore mode, not a fallback.
    public func processChoices(forAreaId areaId: String) -> [ProcessChoice]? {
        guard !areaId.isEmpty else { return nil }
        let listed = areas.first(where: { $0.areaId == areaId })
        let processes: [DeclaredProcess]
        if area?.areaId == areaId {
            processes = declaredProcesses.isEmpty
                ? (listed?.declaredProcesses ?? []) : declaredProcesses
        } else if let listed {
            processes = listed.declaredProcesses
        } else {
            return nil
        }
        var seen = Set<String>()
        return processes
            .filter { seen.insert($0.processId).inserted }
            .map { ProcessChoice(id: $0.processId, name: $0.name) }
    }
}
