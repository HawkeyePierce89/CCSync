import Foundation

/// Assembles the in-memory `BackupModel` by reading only from known paths.
///
/// The collector never scans the filesystem: it reads the fixed global config
/// locations, the `~/.claude.json` document, and — for history — lists only the
/// known roots (`projects`, `file-history`, `session-env`, `todos`) and the
/// explicit project paths taken from `~/.claude.json`. This is what makes the
/// "don't scan the disk" invariant assertable via the test FS journal.
public struct BackupCollector {
    private let fs: FileSystem
    private let paths: KnownPaths
    private let sourceUser: String

    public init(fileSystem: FileSystem, paths: KnownPaths, sourceUser: String? = nil) {
        self.fs = fileSystem
        self.paths = paths
        self.sourceUser = sourceUser ?? (paths.home as NSString).lastPathComponent
    }

    /// Collect the in-memory model.
    ///
    /// - Parameter selection: which layers to capture. `nil` means "everything"
    ///   and exists only for backward compatibility with existing `collect()`
    ///   call sites — GUI and CLI always pass an explicit, non-nil `Selection`
    ///   derived from `SelectionTree.resolvedSelection()`. When `selection.global`
    ///   is `false` the global config is not read at all and an empty
    ///   `GlobalConfig()` is stored; a project whose `encodedName` is not in
    ///   `selection.projectEncodedNames` is cut before any of its sessions or
    ///   local settings are read.
    public func collect(selection: Selection? = nil) throws -> BackupModel {
        let claudeJSON = try readClaudeJSON()
        let global = (selection?.global ?? true)
            ? try collectGlobal(claudeJSON: claudeJSON)
            : GlobalConfig()
        let projects = try collectProjects(claudeJSON: claudeJSON, selection: selection)
        return BackupModel(sourceUser: sourceUser, global: global, projects: projects)
    }

    // MARK: - ~/.claude.json

    private func readClaudeJSON() throws -> JSONValue {
        // `RealFileSystem.readData` follows symlinks, so a `~/.claude.json`
        // planted as a symlink would pull an arbitrary outside file's contents
        // into the archive. Treat a symlinked known path as absent, mirroring
        // the no-follow rule already applied to directory traversal.
        guard fs.exists(paths.claudeJSON), !fs.isSymlink(paths.claudeJSON) else { return .object([:]) }
        return try JSONValue(data: fs.readData(paths.claudeJSON))
    }

    // MARK: - Global config

    private func collectGlobal(claudeJSON: JSONValue) throws -> GlobalConfig {
        // As with the recursive capture, never read through a symlink: a
        // symlinked `settings.json` or `CLAUDE.md` at a known path would
        // otherwise siphon an arbitrary outside file into the archive. Skip it.
        var settings: Data?
        if fs.exists(paths.globalSettings), !fs.isSymlink(paths.globalSettings) {
            settings = try fs.readData(paths.globalSettings)
        }

        var claudeMD: Data?
        if fs.exists(paths.globalClaudeMD), !fs.isSymlink(paths.globalClaudeMD) {
            claudeMD = try fs.readData(paths.globalClaudeMD)
        }

        var configDirs: [ConfigDir] = []
        for name in KnownPaths.globalConfigDirNames {
            let dir = KnownPaths.join(paths.claudeDir, name)
            if isListableDirectory(dir) {
                configDirs.append(ConfigDir(name: name, files: try collectFiles(under: dir)))
            }
        }

        return GlobalConfig(
            settings: settings,
            claudeMD: claudeMD,
            configDirs: configDirs,
            mcpServers: claudeJSON["mcpServers"]
        )
    }

    // MARK: - Projects

    private func collectProjects(claudeJSON: JSONValue, selection: Selection?) throws -> [ProjectEntry] {
        // Matching (entry ↔ directory, ordering, incomplete flags) is shared with
        // `BackupPlan` via `ProjectInventory`; the collector only adds the payload,
        // reading sessions solely when the inventory saw a history directory.
        let inventory = try ProjectInventory.list(claudeJSON: claudeJSON, fileSystem: fs, paths: paths)
        let todoNames = SessionArtifactDiscovery(fs: fs, paths: paths).listTodos()

        var entries: [ProjectEntry] = []
        for entry in inventory {
            // Selectivity before reading: cut an unselected project here, before
            // any `collectSessions`/`collectLocalSettings` call, so its paths never
            // enter the FS journal. Filter the source, not the finished model.
            if let selection, !selection.projectEncodedNames.contains(entry.encodedName) {
                continue
            }
            let sessions = entry.hasHistoryDir
                ? try collectSessions(encoded: entry.encodedName, todoNames: todoNames)
                : []
            entries.append(ProjectEntry(
                path: entry.path,
                encodedName: entry.encodedName,
                settings: entry.settings,
                localSettings: try collectLocalSettings(projectPath: entry.path),
                sessions: sessions,
                incomplete: entry.incomplete,
                incompleteReason: entry.incompleteReason
            ))
        }

        return entries
    }

    private func collectLocalSettings(projectPath: String) throws -> Data? {
        guard !projectPath.isEmpty else { return nil }
        let claudeDir = KnownPaths.join(projectPath, ".claude")
        let local = KnownPaths.join(claudeDir, "settings.local.json")
        // Don't follow a symlinked `settings.local.json` into an outside file.
        guard fs.exists(local), !fs.isSymlink(local) else { return nil }
        return try fs.readData(local)
    }

    // MARK: - Sessions & linked history

    private func collectSessions(encoded: String, todoNames: [String]) throws -> [SessionArtifacts] {
        // Discovery of *which* paths belong to the project's sessions is shared
        // with `ProjectDataLocator`; the collector only reads the discovered paths.
        let discovery = SessionArtifactDiscovery(fs: fs, paths: paths)

        var sessions: [SessionArtifacts] = []
        for session in try discovery.sessions(encoded: encoded, todoNames: todoNames) {
            var todos: [FileBlob] = []
            for todoPath in session.todoFiles {
                todos.append(FileBlob(
                    relativePath: (todoPath as NSString).lastPathComponent,
                    data: try fs.readData(todoPath)
                ))
            }

            sessions.append(SessionArtifacts(
                sessionID: session.sessionID,
                isSubAgent: session.isSubAgent,
                transcript: FileBlob(
                    relativePath: (session.transcriptPath as NSString).lastPathComponent,
                    data: try fs.readData(session.transcriptPath)
                ),
                fileHistory: try session.fileHistoryDir.map { try collectFiles(under: $0) } ?? [],
                sessionEnv: try session.sessionEnvDir.map { try collectFiles(under: $0) } ?? [],
                todos: todos
            ))
        }
        return sessions
    }

    /// A directory root we are willing to list. `FileSystem.isDirectory` follows
    /// symlinks, so a known root (`~/.claude/commands`, a `projects/<encoded>`
    /// folder, a `file-history/<uuid>` dir, …) that is *itself* a symlink would
    /// otherwise be entered and its target scanned — redirecting collection
    /// outside the approved paths (violating "don't scan the disk"). Refuse to
    /// list any root that is a symlink; symlinked *children* are skipped
    /// separately in `collectFiles`.
    private func isListableDirectory(_ path: String) -> Bool {
        fs.isDirectory(path) && !fs.isSymlink(path)
    }

    // MARK: - Recursive file capture (bounded to a single known directory)

    private func collectFiles(under root: String, prefix: String = "") throws -> [FileBlob] {
        var result: [FileBlob] = []
        for name in try fs.listDirectory(root).sorted() {
            let full = KnownPaths.join(root, name)
            // Never follow symlinks: one planted under a known root could redirect
            // this recursion outside the approved paths (violating "don't scan the
            // disk") or form a cycle. Skip the entry entirely.
            if fs.isSymlink(full) { continue }
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            if fs.isDirectory(full) {
                result += try collectFiles(under: full, prefix: relative)
            } else {
                result.append(FileBlob(relativePath: relative, data: try fs.readData(full)))
            }
        }
        return result
    }
}
