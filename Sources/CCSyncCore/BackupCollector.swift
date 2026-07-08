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

    public func collect() throws -> BackupModel {
        let claudeJSON = try readClaudeJSON()
        let global = try collectGlobal(claudeJSON: claudeJSON)
        let projects = try collectProjects(claudeJSON: claudeJSON)
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

    private func collectProjects(claudeJSON: JSONValue) throws -> [ProjectEntry] {
        // Matching (entry ↔ directory, ordering, incomplete flags) is shared with
        // `BackupPlan` via `ProjectInventory`; the collector only adds the payload,
        // reading sessions solely when the inventory saw a history directory.
        let inventory = try ProjectInventory.list(claudeJSON: claudeJSON, fileSystem: fs, paths: paths)
        let todoNames = listTodos()

        var entries: [ProjectEntry] = []
        for entry in inventory {
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
        let dir = paths.projectDir(encoded: encoded)
        guard isListableDirectory(dir) else { return [] }

        var sessions: [SessionArtifacts] = []
        for name in try fs.listDirectory(dir).sorted() where name.hasSuffix(".jsonl") {
            let full = KnownPaths.join(dir, name)
            guard !fs.isDirectory(full), !fs.isSymlink(full) else { continue }

            let stem = String(name.dropLast(".jsonl".count))
            let isSubAgent = stem.hasPrefix("agent-")

            sessions.append(SessionArtifacts(
                sessionID: stem,
                isSubAgent: isSubAgent,
                transcript: FileBlob(relativePath: name, data: try fs.readData(full)),
                fileHistory: try collectHistoryDir(paths.fileHistoryDir(uuid: stem)),
                sessionEnv: try collectHistoryDir(paths.sessionEnvDir(uuid: stem)),
                todos: try collectTodos(sessionID: stem, todoNames: todoNames)
            ))
        }
        return sessions
    }

    private func collectHistoryDir(_ dir: String) throws -> [FileBlob] {
        guard isListableDirectory(dir) else { return [] }
        return try collectFiles(under: dir)
    }

    private func listTodos() -> [String] {
        guard isListableDirectory(paths.todosDir) else { return [] }
        return (try? fs.listDirectory(paths.todosDir)) ?? []
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

    private func collectTodos(sessionID: String, todoNames: [String]) throws -> [FileBlob] {
        var blobs: [FileBlob] = []
        for name in todoNames.sorted() where todoMatches(name: name, sessionID: sessionID) {
            let full = KnownPaths.join(paths.todosDir, name)
            guard fs.exists(full), !fs.isDirectory(full), !fs.isSymlink(full) else { continue }
            blobs.append(FileBlob(relativePath: name, data: try fs.readData(full)))
        }
        return blobs
    }

    /// A todos file belongs to a session when it is `<sessionID>.json` or begins
    /// `<sessionID>-` (the `<sessionId>-agent-<agentId>.json` sub-agent form).
    private func todoMatches(name: String, sessionID: String) -> Bool {
        name == "\(sessionID).json" || name.hasPrefix("\(sessionID)-")
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
