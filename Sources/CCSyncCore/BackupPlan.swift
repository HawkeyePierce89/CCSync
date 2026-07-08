import Foundation

/// The machine-readable "project list from the local machine" contract — the
/// backup-side mirror of `RestorePlan`.
///
/// Where `RestorePlan` reads the project inventory out of an archive, `BackupPlan`
/// reads it off the current machine (`~/.claude.json` + the `projects/`
/// directories, via `ProjectInventory`). Both feed the same `SelectionTree`, so
/// the GUI and CLI present an identical two-level selection for backup and
/// restore. Sessions are never read here — this is the read-only inventory the
/// selection UI binds to.
public struct BackupPlan: Equatable, Sendable {
    /// Username on this machine (the last path component of `home`).
    public var sourceUser: String
    /// One entry per project discoverable on this machine.
    public var projects: [ManifestProject]

    public init(sourceUser: String, projects: [ManifestProject]) {
        self.sourceUser = sourceUser
        self.projects = projects
    }

    /// Build the plan by reading the local machine's `~/.claude.json` and
    /// `projects/` directories. `hasHistoryDir` from the inventory is intentionally
    /// dropped — the plan never reads sessions.
    public init(fileSystem: FileSystem, paths: KnownPaths, sourceUser: String? = nil) throws {
        let user = sourceUser ?? (paths.home as NSString).lastPathComponent
        let claudeJSON = try Self.readClaudeJSON(fileSystem: fileSystem, paths: paths)
        let entries = try ProjectInventory.list(claudeJSON: claudeJSON, fileSystem: fileSystem, paths: paths)
        self.init(
            sourceUser: user,
            projects: entries.map {
                ManifestProject(
                    path: $0.path,
                    encodedName: $0.encodedName,
                    settings: $0.settings,
                    incomplete: $0.incomplete,
                    incompleteReason: $0.incompleteReason
                )
            }
        )
    }

    /// Read `~/.claude.json` with the same no-follow symlink guard as
    /// `BackupCollector`: a symlinked known path is treated as absent so it can't
    /// siphon an arbitrary outside file into the plan.
    private static func readClaudeJSON(fileSystem: FileSystem, paths: KnownPaths) throws -> JSONValue {
        guard fileSystem.exists(paths.claudeJSON), !fileSystem.isSymlink(paths.claudeJSON) else { return .object([:]) }
        return try JSONValue(data: fileSystem.readData(paths.claudeJSON))
    }
}
