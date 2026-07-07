import Foundation

/// The machine-readable "project list from the archive" contract (Task 4).
///
/// Both the SwiftUI app and the `ccsync list` CLI consume this: the source user,
/// the source Claude Code version, and the list of projects with their paths,
/// per-project settings, and the incompleteness flag carried over from backup.
/// Selection (which projects to actually restore) is layered on top in Task 5
/// via `SelectionTree`; this type is the read-only inventory.
public struct RestorePlan: Equatable, Sendable {
    /// Username on the machine the backup was taken from.
    public var sourceUser: String
    /// Source Claude Code version (proxy for the session schema version), if the
    /// manifest recorded one.
    public var sourceClaudeVersion: String?
    /// One entry per project in the archive.
    public var projects: [ManifestProject]

    public init(
        sourceUser: String,
        sourceClaudeVersion: String? = nil,
        projects: [ManifestProject]
    ) {
        self.sourceUser = sourceUser
        self.sourceClaudeVersion = sourceClaudeVersion
        self.projects = projects
    }

    /// Build the plan directly from a parsed manifest.
    public init(manifest: Manifest) {
        self.init(
            sourceUser: manifest.sourceUser,
            sourceClaudeVersion: manifest.sourceClaudeVersion,
            projects: manifest.projects
        )
    }

    /// Convenience: parse an archive's bytes and return its project list.
    /// Throws the same errors as `ArchiveReader` on a corrupt archive/manifest.
    public init(archive data: Data) throws {
        self.init(manifest: try ArchiveReader(data: data).manifest)
    }

    // MARK: - Machine-readable JSON (CLI `list` contract)

    func toJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "sourceUser": .string(sourceUser),
            "projects": .array(projects.map { $0.toJSONValue() }),
        ]
        if let sourceClaudeVersion {
            object["sourceClaudeVersion"] = .string(sourceClaudeVersion)
        }
        return .object(object)
    }

    /// Serialise the project list to JSON bytes for the CLI `list` command.
    public func serialized(pretty: Bool = true) throws -> Data {
        try toJSONValue().serialized(pretty: pretty)
    }
}
