import Foundation

/// The capture **scope** (ADR 0002 / docs/AREA_MODEL_PLAN.md): the *Area* a recording is anchored to.
/// Phase 2 keeps it a lightweight value — a stable id + a human name — picked at session start and
/// stamped on every event (`area.id`/`area.name`). `mintAreaId` derives a deterministic, tag/URL-safe
/// id from a typed name, so the macOS-minted id is the stable handle the processor groups sessions by
/// (it reads the stamped id verbatim — it never re-slugs). Pure + TCC-free → unit-testable in Core.
public enum CaptureScope {
    /// The default Area. A session with no pick reads as "General" downstream (the ADR 0002 display
    /// default for un-anchored captures).
    public static let generalAreaId = "general"
    public static let generalAreaName = "General"

    /// Derive a stable, lowercase, kebab-case Area id from a human name
    /// (e.g. "Merchant Onboarding" → "merchant-onboarding"). ASCII alphanumerics only (so the id stays
    /// safe as a URL path / Storage tag); every other run of characters collapses to a single dash, and
    /// leading/trailing dashes are trimmed. An empty or punctuation-only name falls back to "general".
    public static func mintAreaId(from name: String) -> String {
        var slug = ""
        var lastWasDash = false
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? generalAreaId : trimmed
    }

    // MARK: - Guided capture (label → process pick)

    /// Resolve a label's text against the Area's declared process inventory ("Guided capture").
    /// Pure and deterministic:
    ///   1. an **exact** case-insensitive name match wins;
    ///   2. else a **unique** case-insensitive substring match (in either direction — "booking"
    ///      finds "Monthly booking", and "monthly booking for Q3" finds it too);
    ///   3. else no processId — the text stays a plain free-text label (Explore).
    /// The returned `label` is the matched process's **canonical** name (so the stamped label and
    /// the `process.name` attribute agree verbatim) or the trimmed raw text when nothing matched.
    /// Free text NEVER mints a processId client-side — declared ids come only from the backend
    /// registry; an unmatched label is simply unanchored.
    public static func resolveLabelPick(
        text: String, inventory: [ProcessChoice]
    ) -> (processId: String?, processName: String?, label: String) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = raw.lowercased()
        guard !needle.isEmpty, !inventory.isEmpty else { return (nil, nil, raw) }
        if let exact = inventory.first(where: { $0.name.lowercased() == needle }) {
            return (exact.id, exact.name, exact.name)
        }
        let partial = inventory.filter {
            let name = $0.name.lowercased()
            return name.contains(needle) || needle.contains(name)
        }
        // Only an UNAMBIGUOUS partial match anchors the segment — two candidates means we
        // don't guess (a wrong process.id is worse than none).
        if partial.count == 1, let match = partial.first {
            return (match.id, match.name, match.name)
        }
        return (nil, nil, raw)
    }
}

/// One pickable Process from the Area's declared inventory — what the ⌥⌘L panel offers in
/// Guided mode and what ``CaptureScope/resolveLabelPick(text:inventory:)`` matches against.
public struct ProcessChoice: Equatable, Hashable, Sendable {
    /// Stable slug identity (`processId` in the registry) — stamped as `process.id`.
    public let id: String
    /// Human display name (`name` in the registry) — stamped as `process.name`.
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Client-side view of one Area's registry document (`contract/schema/area-registry.schema.json`,
/// stored as a Keboola Storage File tagged `jazz-area-registry` + `area:<areaId>`). Decodes
/// only the subset the agent needs (identity + declared process inventory) and decodes it
/// **tolerantly**: missing fields default, unknown fields are ignored, and a malformed process
/// entry is skipped rather than failing the whole document — the registry is written by the
/// backend and may grow fields the agent doesn't know yet.
public struct AreaRegistry: Codable, Equatable, Sendable {
    /// One declared process-inventory entry (the subset of the schema's `$defs/process`).
    public struct Process: Codable, Equatable, Sendable {
        public var processId: String
        public var name: String
        public var description: String?

        public init(processId: String, name: String, description: String? = nil) {
            self.processId = processId
            self.name = name
            self.description = description
        }

        enum CodingKeys: String, CodingKey {
            case processId, name, description
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            processId = try c.decodeIfPresent(String.self, forKey: .processId) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            description = try? c.decodeIfPresent(String.self, forKey: .description)
        }
    }

    public var areaId: String
    public var name: String
    public var processes: [Process]

    public init(areaId: String, name: String, processes: [Process] = []) {
        self.areaId = areaId
        self.name = name
        self.processes = processes
    }

    enum CodingKeys: String, CodingKey {
        case areaId, name, processes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        areaId = try c.decodeIfPresent(String.self, forKey: .areaId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        // Lossy per-element decode: one malformed entry (wrong type, not an object) is dropped,
        // the rest survive. Entries without both a processId and a name are unusable as picks.
        let entries = (try? c.decodeIfPresent([Failable<Process>].self, forKey: .processes)) ?? nil
        processes = (entries ?? [])
            .compactMap(\.value)
            .filter { !$0.processId.isEmpty && !$0.name.isEmpty }
    }

    /// Decode a registry document, or nil when the data isn't a JSON object at all (garbage,
    /// an array, non-JSON bytes). Field-level problems degrade (defaults / skipped entries)
    /// rather than nil-ing the whole document.
    public static func parse(data: Data) -> AreaRegistry? {
        try? JSONDecoder().decode(AreaRegistry.self, from: data)
    }

    /// The declared inventory as picker choices, in registry (declaration) order.
    public var processChoices: [ProcessChoice] {
        processes.map { ProcessChoice(id: $0.processId, name: $0.name) }
    }
}

/// Decodes to nil instead of throwing — the lossy-array element wrapper behind
/// ``AreaRegistry``'s tolerant `processes` decoding.
private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}
