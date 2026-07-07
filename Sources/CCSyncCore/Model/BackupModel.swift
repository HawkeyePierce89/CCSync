import Foundation

/// A single captured file plus its location relative to some capture root.
///
/// Transcripts store their bare filename; files under a config or history
/// directory store their path relative to that directory (e.g. `sub/tool.md`).
public struct FileBlob: Equatable, Sendable {
    public var relativePath: String
    public var data: Data

    public init(relativePath: String, data: Data) {
        self.relativePath = relativePath
        self.data = data
    }
}

/// One of the optional global config directories under `~/.claude`
/// (`commands`, `agents`, `skills`, `rules`, `output-styles`, `hooks`).
public struct ConfigDir: Equatable, Sendable {
    public var name: String
    public var files: [FileBlob]

    public init(name: String, files: [FileBlob]) {
        self.name = name
        self.files = files
    }
}

/// Everything captured from the global (`~/.claude`) layer plus the global
/// `mcpServers` block from `~/.claude.json`.
public struct GlobalConfig: Equatable, Sendable {
    public var settings: Data?
    public var claudeMD: Data?
    public var configDirs: [ConfigDir]
    public var mcpServers: JSONValue?

    public init(
        settings: Data? = nil,
        claudeMD: Data? = nil,
        configDirs: [ConfigDir] = [],
        mcpServers: JSONValue? = nil
    ) {
        self.settings = settings
        self.claudeMD = claudeMD
        self.configDirs = configDirs
        self.mcpServers = mcpServers
    }
}

/// The linked history of one Claude Code session (a main session or a
/// `Task`-tool sub-agent), keyed by the transcript filename stem.
public struct SessionArtifacts: Equatable, Sendable {
    /// Filename stem of the transcript (a UUID for main sessions,
    /// `agent-<shortId>` for sub-agents).
    public var sessionID: String
    public var isSubAgent: Bool
    /// The `<stem>.jsonl` transcript itself.
    public var transcript: FileBlob
    /// Contents of `file-history/<sessionID>/` (empty if absent).
    public var fileHistory: [FileBlob]
    /// Contents of `session-env/<sessionID>/` (empty if absent).
    public var sessionEnv: [FileBlob]
    /// Matching `todos/<sessionID>*.json` files (empty if absent).
    public var todos: [FileBlob]

    public init(
        sessionID: String,
        isSubAgent: Bool,
        transcript: FileBlob,
        fileHistory: [FileBlob] = [],
        sessionEnv: [FileBlob] = [],
        todos: [FileBlob] = []
    ) {
        self.sessionID = sessionID
        self.isSubAgent = isSubAgent
        self.transcript = transcript
        self.fileHistory = fileHistory
        self.sessionEnv = sessionEnv
        self.todos = todos
    }
}

/// One project in the backup: its `~/.claude.json` entry, its local settings,
/// and its captured session history.
public struct ProjectEntry: Equatable, Sendable {
    /// Absolute project path (the `~/.claude.json` key). Empty when the project
    /// is known only from a `projects/<encoded>/` directory with no entry.
    public var path: String
    /// Encoded `projects/` directory name for this project.
    public var encodedName: String
    /// The per-project object from `~/.claude.json` `projects` (generic JSON).
    public var settings: JSONValue?
    /// The project's own `.claude/settings.local.json`, if present.
    public var localSettings: Data?
    public var sessions: [SessionArtifacts]
    /// True when the entry and its on-disk directory did not both exist.
    public var incomplete: Bool
    public var incompleteReason: String?

    public init(
        path: String,
        encodedName: String,
        settings: JSONValue? = nil,
        localSettings: Data? = nil,
        sessions: [SessionArtifacts] = [],
        incomplete: Bool = false,
        incompleteReason: String? = nil
    ) {
        self.path = path
        self.encodedName = encodedName
        self.settings = settings
        self.localSettings = localSettings
        self.sessions = sessions
        self.incomplete = incomplete
        self.incompleteReason = incompleteReason
    }
}

/// The full in-memory backup model, assembled by `BackupCollector` and consumed
/// by the archive layer.
public struct BackupModel: Equatable, Sendable {
    public var sourceUser: String
    public var global: GlobalConfig
    public var projects: [ProjectEntry]

    public init(sourceUser: String, global: GlobalConfig, projects: [ProjectEntry]) {
        self.sourceUser = sourceUser
        self.global = global
        self.projects = projects
    }
}
