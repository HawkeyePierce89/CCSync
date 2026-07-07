import Foundation

/// All known paths CCSync reads from and writes to, derived from an injected
/// home directory. The filesystem is never scanned — everything CCSync touches
/// is computed here from these fixed, known locations (plus explicit project
/// paths supplied at runtime).
public struct KnownPaths: Sendable {
    /// Absolute path to the user's home directory (e.g. `/Users/alice`).
    public let home: String

    public init(home: String) {
        // Normalise a trailing slash so joins are predictable.
        if home.count > 1 && home.hasSuffix("/") {
            self.home = String(home.dropLast())
        } else {
            self.home = home
        }
    }

    // MARK: - Roots

    /// `~/.claude`
    public var claudeDir: String { join(home, ".claude") }

    /// `~/.claude.json`
    public var claudeJSON: String { join(home, ".claude.json") }

    // MARK: - Global config files

    /// `~/.claude/settings.json`
    public var globalSettings: String { join(claudeDir, "settings.json") }

    /// `~/.claude/CLAUDE.md` (optional)
    public var globalClaudeMD: String { join(claudeDir, "CLAUDE.md") }

    /// Names of the optional global config directories under `~/.claude`.
    /// Any that are absent are simply skipped.
    public static let globalConfigDirNames: [String] = [
        "commands", "agents", "skills", "rules", "output-styles", "hooks"
    ]

    /// Absolute paths of the optional global config directories under `~/.claude`.
    public var globalConfigDirs: [String] {
        Self.globalConfigDirNames.map { join(claudeDir, $0) }
    }

    // MARK: - History roots

    /// `~/.claude/projects`
    public var projectsDir: String { join(claudeDir, "projects") }

    /// `~/.claude/file-history`
    public var fileHistoryDir: String { join(claudeDir, "file-history") }

    /// `~/.claude/session-env`
    public var sessionEnvDir: String { join(claudeDir, "session-env") }

    /// `~/.claude/todos`
    public var todosDir: String { join(claudeDir, "todos") }

    // MARK: - Per-session / per-project helpers

    /// `~/.claude/projects/<encoded>`
    public func projectDir(encoded: String) -> String {
        join(projectsDir, encoded)
    }

    /// `~/.claude/file-history/<uuid>`
    public func fileHistoryDir(uuid: String) -> String {
        join(fileHistoryDir, uuid)
    }

    /// `~/.claude/session-env/<uuid>`
    public func sessionEnvDir(uuid: String) -> String {
        join(sessionEnvDir, uuid)
    }

    // MARK: - Exclusions

    /// Top-level names under `~/.claude` that are never backed up (local noise
    /// and credentials). Matched by exact name.
    public static let excludedNames: Set<String> = [
        "history.jsonl",
        "statsig",
        "debug",
        "shell-snapshots",
        "cache",
        "paste-cache",
        ".credentials.json",
    ]

    /// Whether a top-level `~/.claude` entry name is excluded from backup.
    public static func isExcluded(name: String) -> Bool {
        excludedNames.contains(name)
    }

    // MARK: - Joining

    private func join(_ base: String, _ component: String) -> String {
        Self.join(base, component)
    }

    /// Join two path segments with a single separator.
    public static func join(_ base: String, _ component: String) -> String {
        if base.hasSuffix("/") {
            return base + component
        }
        return base + "/" + component
    }

    // MARK: - Containment

    /// Lexically resolve `.` and `..` segments in `path` (no filesystem access,
    /// no symlink resolution). A leading `/` is preserved; `..` segments that
    /// would climb above an absolute root are dropped, matching how the kernel
    /// clamps `/..` at `/`.
    public static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var stack: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
            default:
                stack.append(String(segment))
            }
        }
        return (isAbsolute ? "/" : "") + stack.joined(separator: "/")
    }

    /// Whether `path`, after lexical normalization, is `root` itself or lies
    /// beneath it. Used to reject archive entries whose relative segments escape
    /// their intended restore root (a `..`-traversal in a hostile archive).
    public static func isContained(_ path: String, within root: String) -> Bool {
        let normalizedPath = normalize(path)
        let normalizedRoot = normalize(root)
        return normalizedPath == normalizedRoot
            || normalizedPath.hasPrefix(normalizedRoot + "/")
    }
}
