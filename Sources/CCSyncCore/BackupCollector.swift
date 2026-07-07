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
        guard fs.exists(paths.claudeJSON) else { return .object([:]) }
        return try JSONValue(data: fs.readData(paths.claudeJSON))
    }

    // MARK: - Global config

    private func collectGlobal(claudeJSON: JSONValue) throws -> GlobalConfig {
        var settings: Data?
        if fs.exists(paths.globalSettings) {
            settings = try fs.readData(paths.globalSettings)
        }

        var claudeMD: Data?
        if fs.exists(paths.globalClaudeMD) {
            claudeMD = try fs.readData(paths.globalClaudeMD)
        }

        var configDirs: [ConfigDir] = []
        for name in KnownPaths.globalConfigDirNames {
            let dir = KnownPaths.join(paths.claudeDir, name)
            if fs.isDirectory(dir) {
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
        let projectSettings = claudeJSON["projects"]?.objectValue ?? [:]

        var existingDirs: Set<String> = []
        if fs.isDirectory(paths.projectsDir) {
            existingDirs = Set(try fs.listDirectory(paths.projectsDir))
        }
        let todoNames = listTodos()

        var entries: [ProjectEntry] = []
        var matchedDirs: Set<String> = []

        // Entries from ~/.claude.json, linked to their history directory if present.
        for path in projectSettings.keys.sorted() {
            let encoded = ProjectPathEncoding.encode(path)
            let hasDir = existingDirs.contains(encoded)
            if hasDir { matchedDirs.insert(encoded) }

            let sessions = hasDir
                ? try collectSessions(encoded: encoded, todoNames: todoNames)
                : []

            entries.append(ProjectEntry(
                path: path,
                encodedName: encoded,
                settings: projectSettings[path],
                localSettings: try collectLocalSettings(projectPath: path),
                sessions: sessions,
                incomplete: !hasDir,
                incompleteReason: hasDir ? nil : "no history directory on disk"
            ))
        }

        // History directories with no matching entry in ~/.claude.json.
        for dir in existingDirs.sorted() where !matchedDirs.contains(dir) {
            guard fs.isDirectory(paths.projectDir(encoded: dir)) else { continue }
            entries.append(ProjectEntry(
                path: "",
                encodedName: dir,
                settings: nil,
                localSettings: nil,
                sessions: try collectSessions(encoded: dir, todoNames: todoNames),
                incomplete: true,
                incompleteReason: "no entry in ~/.claude.json"
            ))
        }

        return entries
    }

    private func collectLocalSettings(projectPath: String) throws -> Data? {
        guard !projectPath.isEmpty else { return nil }
        let claudeDir = KnownPaths.join(projectPath, ".claude")
        let local = KnownPaths.join(claudeDir, "settings.local.json")
        guard fs.exists(local) else { return nil }
        return try fs.readData(local)
    }

    // MARK: - Sessions & linked history

    private func collectSessions(encoded: String, todoNames: [String]) throws -> [SessionArtifacts] {
        let dir = paths.projectDir(encoded: encoded)
        guard fs.isDirectory(dir) else { return [] }

        var sessions: [SessionArtifacts] = []
        for name in try fs.listDirectory(dir).sorted() where name.hasSuffix(".jsonl") {
            let full = KnownPaths.join(dir, name)
            guard !fs.isDirectory(full) else { continue }

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
        guard fs.isDirectory(dir) else { return [] }
        return try collectFiles(under: dir)
    }

    private func listTodos() -> [String] {
        guard fs.isDirectory(paths.todosDir) else { return [] }
        return (try? fs.listDirectory(paths.todosDir)) ?? []
    }

    private func collectTodos(sessionID: String, todoNames: [String]) throws -> [FileBlob] {
        var blobs: [FileBlob] = []
        for name in todoNames.sorted() where todoMatches(name: name, sessionID: sessionID) {
            let full = KnownPaths.join(paths.todosDir, name)
            guard fs.exists(full), !fs.isDirectory(full) else { continue }
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
