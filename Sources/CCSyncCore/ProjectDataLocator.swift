import Foundation

/// Locates the removable Claude-data paths for a single project, so
/// `DeleteService` can delete exactly what `BackupCollector` would have captured.
///
/// It returns an *ordered set* of paths: the `projects/<encoded>/` history
/// directory (which contains the session transcripts), followed by the linked
/// per-session artifact paths (`file-history/<stem>/`, `session-env/<stem>/`, and
/// the matching `todos/` files). Discovery is delegated to the shared
/// `SessionArtifactDiscovery` so the locator and the collector cannot drift.
///
/// Like the collector, it reads no file contents and never lists `home`; it only
/// probes the explicit known roots (invariant #1). A symlinked root is skipped —
/// never entered, never removed as a target.
public struct ProjectDataLocator {
    private let fs: FileSystem
    private let paths: KnownPaths

    public init(fileSystem: FileSystem, paths: KnownPaths) {
        self.fs = fileSystem
        self.paths = paths
    }

    /// The ordered, de-duplicated set of removable Claude-data paths for the
    /// project with the given encoded name. Empty when the project has no history
    /// directory and no linked artifacts (its cleanup is then the `~/.claude.json`
    /// key alone, handled by the caller).
    public func removablePaths(encodedName: String) throws -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        func add(_ path: String) {
            if seen.insert(path).inserted { ordered.append(path) }
        }

        // The history directory holds every session transcript, so removing it
        // covers the `projects/<encoded>/` subtree in one path. Only a real
        // (non-symlink) directory is entered/removed.
        let projectDir = paths.projectDir(encoded: encodedName)
        if fs.isDirectory(projectDir), !fs.isSymlink(projectDir) {
            add(projectDir)
        }

        let discovery = SessionArtifactDiscovery(fs: fs, paths: paths)
        let todoNames = discovery.listTodos()
        for session in try discovery.sessions(encoded: encodedName, todoNames: todoNames) {
            if let fileHistory = session.fileHistoryDir { add(fileHistory) }
            if let sessionEnv = session.sessionEnvDir { add(sessionEnv) }
            for todo in session.todoFiles { add(todo) }
        }

        return ordered
    }
}
