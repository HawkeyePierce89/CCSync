import Foundation

/// One project's metadata inside the archive manifest: the machine-readable
/// entry that the restore-time "project list" contract (Task 4) returns to the
/// UI/CLI. History payload lives in the container; this is just the description.
public struct ManifestProject: Equatable, Sendable {
    /// Absolute project path (the `~/.claude.json` key). Empty when the project
    /// is known only from a `projects/<encoded>/` directory with no entry.
    public var path: String
    /// Encoded `projects/` directory name (used for user-segment remap on restore).
    public var encodedName: String
    /// The per-project object from `~/.claude.json` `projects` (generic JSON),
    /// preserved verbatim so unknown/future keys survive the round-trip.
    public var settings: JSONValue?
    /// True when the `~/.claude.json` entry and its on-disk directory did not
    /// both exist at backup time (carried over from `BackupCollector`).
    public var incomplete: Bool
    public var incompleteReason: String?

    public init(
        path: String,
        encodedName: String,
        settings: JSONValue? = nil,
        incomplete: Bool = false,
        incompleteReason: String? = nil
    ) {
        self.path = path
        self.encodedName = encodedName
        self.settings = settings
        self.incomplete = incomplete
        self.incompleteReason = incompleteReason
    }

    init(entry: ProjectEntry) {
        self.init(
            path: entry.path,
            encodedName: entry.encodedName,
            settings: entry.settings,
            incomplete: entry.incomplete,
            incompleteReason: entry.incompleteReason
        )
    }

    func toJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "path": .string(path),
            "encodedName": .string(encodedName),
            "incomplete": .bool(incomplete),
        ]
        if let settings { object["settings"] = settings }
        if let incompleteReason { object["incompleteReason"] = .string(incompleteReason) }
        return .object(object)
    }

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue else {
            throw ArchiveError.invalidManifest("project is not an object")
        }
        guard let path = object["path"]?.stringValue,
              let encodedName = object["encodedName"]?.stringValue else {
            throw ArchiveError.invalidManifest("project missing path/encodedName")
        }
        self.init(
            path: path,
            encodedName: encodedName,
            settings: object["settings"],
            incomplete: object["incomplete"]?.boolValue ?? false,
            incompleteReason: object["incompleteReason"]?.stringValue
        )
    }
}

/// The archive manifest: format version, source user, the project list with
/// per-project settings and incompleteness flags, and the source Claude Code
/// version used for the restore-time `VersionCheck` (Task 4).
///
/// Serialised via `JSONValue` (not `Codable`/`JSONDecoder`) so that per-project
/// settings preserve the int/double distinction — a metric counter must not
/// come back as `1.0`.
public struct Manifest: Equatable, Sendable {
    /// Bump when the archive layout or manifest shape changes incompatibly.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var sourceUser: String
    /// Source Claude Code version, if known at backup time (proxy for the
    /// session schema version). Compared against the target at restore time.
    public var sourceClaudeVersion: String?
    public var projects: [ManifestProject]

    public init(
        formatVersion: Int = Manifest.currentFormatVersion,
        sourceUser: String,
        sourceClaudeVersion: String? = nil,
        projects: [ManifestProject]
    ) {
        self.formatVersion = formatVersion
        self.sourceUser = sourceUser
        self.sourceClaudeVersion = sourceClaudeVersion
        self.projects = projects
    }

    init(model: BackupModel, sourceClaudeVersion: String?) {
        self.init(
            sourceUser: model.sourceUser,
            sourceClaudeVersion: sourceClaudeVersion,
            projects: model.projects.map(ManifestProject.init(entry:))
        )
    }

    // MARK: - JSON

    func toJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "formatVersion": .int(formatVersion),
            "sourceUser": .string(sourceUser),
            "projects": .array(projects.map { $0.toJSONValue() }),
        ]
        if let sourceClaudeVersion {
            object["sourceClaudeVersion"] = .string(sourceClaudeVersion)
        }
        return .object(object)
    }

    func serialized() throws -> Data {
        try toJSONValue().serialized(pretty: true)
    }

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue else {
            throw ArchiveError.invalidManifest("manifest is not an object")
        }
        guard let formatVersion = object["formatVersion"]?.intValue else {
            throw ArchiveError.invalidManifest("missing formatVersion")
        }
        // The format version gates incompatible layout/manifest changes. A binary
        // must not silently reinterpret a newer archive as the version it knows —
        // stop with a clear error rather than restore misread data.
        guard formatVersion <= Manifest.currentFormatVersion else {
            throw ArchiveError.invalidManifest(
                "unsupported archive format version \(formatVersion) (this build supports up to \(Manifest.currentFormatVersion))"
            )
        }
        guard let sourceUser = object["sourceUser"]?.stringValue else {
            throw ArchiveError.invalidManifest("missing sourceUser")
        }
        guard let projectsArray = object["projects"]?.arrayValue else {
            throw ArchiveError.invalidManifest("missing projects list")
        }
        self.init(
            formatVersion: formatVersion,
            sourceUser: sourceUser,
            sourceClaudeVersion: object["sourceClaudeVersion"]?.stringValue,
            projects: try projectsArray.map(ManifestProject.init(jsonValue:))
        )
    }

    init(data: Data) throws {
        let json: JSONValue
        do {
            json = try JSONValue(data: data)
        } catch {
            throw ArchiveError.invalidManifest("manifest is not valid JSON")
        }
        try self.init(jsonValue: json)
    }
}
