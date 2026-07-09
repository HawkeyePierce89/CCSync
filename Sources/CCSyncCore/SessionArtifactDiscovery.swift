import Foundation

/// The single, shared per-session artifact discovery used by both
/// `BackupCollector` (which reads each artifact) and `ProjectDataLocator` (which
/// removes it). Having one implementation is what stops the two callers from
/// drifting on *which* files belong to a project's sessions — an equivalence test
/// pins that they see the same paths on the same fixture home.
///
/// This helper discovers **paths only** — it never reads file contents. It
/// enforces the same no-follow discipline as the collector: only a listable,
/// non-symlink directory root is entered; a symlinked root (a `projects/<encoded>`
/// folder, a `file-history/<uuid>` dir, …) is skipped so collection/removal is
/// never redirected outside the approved paths.
struct SessionArtifactDiscovery {
    /// One session's discovered artifact paths. Directory roots are `nil` when the
    /// entry is absent, a plain file, or a symlink (never entered); `todoFiles`
    /// holds the full paths of the matching, non-symlink todos entries.
    struct Session {
        let sessionID: String
        let isSubAgent: Bool
        /// Full path to the `<stem>.jsonl` transcript (a real, non-symlink file).
        let transcriptPath: String
        /// `file-history/<stem>/` when it is a listable non-symlink directory.
        let fileHistoryDir: String?
        /// `session-env/<stem>/` when it is a listable non-symlink directory.
        let sessionEnvDir: String?
        /// Full paths of the `todos/` entries belonging to this session.
        let todoFiles: [String]
    }

    let fs: FileSystem
    let paths: KnownPaths

    /// The (already-listed) `todos/` directory names, shared across all of a
    /// project's sessions. Empty when the dir is absent or not listable.
    func listTodos() -> [String] {
        guard isListableDirectory(paths.todosDir) else { return [] }
        return (try? fs.listDirectory(paths.todosDir)) ?? []
    }

    /// All session descriptors for the given encoded project. Returns `[]` when the
    /// `projects/<encoded>/` history directory is absent or not listable (a symlink
    /// or a plain file). `todoNames` is the result of `listTodos()`.
    func sessions(encoded: String, todoNames: [String]) throws -> [Session] {
        let dir = paths.projectDir(encoded: encoded)
        guard isListableDirectory(dir) else { return [] }

        var result: [Session] = []
        for name in try fs.listDirectory(dir).sorted() where name.hasSuffix(".jsonl") {
            let full = KnownPaths.join(dir, name)
            guard !fs.isDirectory(full), !fs.isSymlink(full) else { continue }

            let stem = String(name.dropLast(".jsonl".count))
            let fileHistory = paths.fileHistoryDir(uuid: stem)
            let sessionEnv = paths.sessionEnvDir(uuid: stem)

            result.append(Session(
                sessionID: stem,
                isSubAgent: stem.hasPrefix("agent-"),
                transcriptPath: full,
                fileHistoryDir: isListableDirectory(fileHistory) ? fileHistory : nil,
                sessionEnvDir: isListableDirectory(sessionEnv) ? sessionEnv : nil,
                todoFiles: todoFiles(sessionID: stem, todoNames: todoNames)
            ))
        }
        return result
    }

    private func todoFiles(sessionID: String, todoNames: [String]) -> [String] {
        var files: [String] = []
        for name in todoNames.sorted() where todoMatches(name: name, sessionID: sessionID) {
            let full = KnownPaths.join(paths.todosDir, name)
            guard fs.exists(full), !fs.isDirectory(full), !fs.isSymlink(full) else { continue }
            files.append(full)
        }
        return files
    }

    /// A todos file belongs to a session when it is `<sessionID>.json` or begins
    /// `<sessionID>-` (the `<sessionId>-agent-<agentId>.json` sub-agent form).
    private func todoMatches(name: String, sessionID: String) -> Bool {
        name == "\(sessionID).json" || name.hasPrefix("\(sessionID)-")
    }

    /// A directory root we are willing to enter. `isDirectory` follows symlinks, so
    /// a known root that is itself a symlink would otherwise be entered and its
    /// target scanned/removed — refuse any root that is a symlink.
    private func isListableDirectory(_ path: String) -> Bool {
        fs.isDirectory(path) && !fs.isSymlink(path)
    }
}
