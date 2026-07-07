import Foundation

/// Logical entry paths inside a CCSync archive container. Shared by
/// `ArchiveWriter` (Task 3) and `ArchiveReader` (Task 4) so the two stay in sync.
enum ArchiveLayout {
    static let manifest = "manifest.json"

    static let globalSettings = "global/settings.json"
    static let globalClaudeMD = "global/CLAUDE.md"
    static let globalMCPServers = "global/mcpServers.json"
    /// Prefix for a global config directory's captured files:
    /// `global/dirs/<dirName>/<relativePath>`.
    static let globalDirsPrefix = "global/dirs/"

    /// Prefix for a project's payload: `projects/<encodedName>/…`.
    static let projectsPrefix = "projects/"
    static let projectLocalSettings = "settings.local.json"
    static let sessionsComponent = "sessions"
    static let transcriptComponent = "transcript"
    static let fileHistoryComponent = "file-history"
    static let sessionEnvComponent = "session-env"
    static let todosComponent = "todos"
}

/// Packs an in-memory `BackupModel` into a single archive: the manifest, the
/// global config, and each project's history.
///
/// Per the locked archive-layer decision, everything is assembled in memory over
/// `Data` (see `ArchiveContainer`) — there is no shell-out to system `tar` and
/// no temp files. The result is a byte blob the caller writes through the
/// `FileSystem` abstraction, which keeps the whole path testable in memory.
public struct ArchiveWriter {
    public init() {}

    /// Build the archive bytes for `model`. `sourceClaudeVersion` (if known) is
    /// recorded in the manifest for the restore-time version check.
    public func makeArchive(from model: BackupModel, sourceClaudeVersion: String? = nil) throws -> Data {
        var entries: [ArchiveContainer.Entry] = []

        let manifest = Manifest(model: model, sourceClaudeVersion: sourceClaudeVersion)
        entries.append(.init(path: ArchiveLayout.manifest, data: try manifest.serialized()))

        appendGlobal(model.global, into: &entries)
        for project in model.projects {
            appendProject(project, into: &entries)
        }

        return ArchiveContainer.pack(entries)
    }

    // MARK: - Global

    private func appendGlobal(_ global: GlobalConfig, into entries: inout [ArchiveContainer.Entry]) {
        if let settings = global.settings {
            entries.append(.init(path: ArchiveLayout.globalSettings, data: settings))
        }
        if let claudeMD = global.claudeMD {
            entries.append(.init(path: ArchiveLayout.globalClaudeMD, data: claudeMD))
        }
        for dir in global.configDirs {
            for file in dir.files {
                let path = ArchiveLayout.globalDirsPrefix + dir.name + "/" + file.relativePath
                entries.append(.init(path: path, data: file.data))
            }
        }
        if let mcpServers = global.mcpServers, let data = try? mcpServers.serialized() {
            entries.append(.init(path: ArchiveLayout.globalMCPServers, data: data))
        }
    }

    // MARK: - Projects

    private func appendProject(_ project: ProjectEntry, into entries: inout [ArchiveContainer.Entry]) {
        let base = ArchiveLayout.projectsPrefix + project.encodedName

        if let local = project.localSettings {
            entries.append(.init(path: base + "/" + ArchiveLayout.projectLocalSettings, data: local))
        }

        for session in project.sessions {
            let sessionBase = base + "/" + ArchiveLayout.sessionsComponent + "/" + session.sessionID
            entries.append(.init(
                path: sessionBase + "/" + ArchiveLayout.transcriptComponent + "/" + session.transcript.relativePath,
                data: session.transcript.data
            ))
            append(session.fileHistory, under: sessionBase + "/" + ArchiveLayout.fileHistoryComponent, into: &entries)
            append(session.sessionEnv, under: sessionBase + "/" + ArchiveLayout.sessionEnvComponent, into: &entries)
            append(session.todos, under: sessionBase + "/" + ArchiveLayout.todosComponent, into: &entries)
        }
    }

    private func append(_ files: [FileBlob], under prefix: String, into entries: inout [ArchiveContainer.Entry]) {
        for file in files {
            entries.append(.init(path: prefix + "/" + file.relativePath, data: file.data))
        }
    }
}
