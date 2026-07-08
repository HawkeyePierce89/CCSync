import Foundation

/// The shared "which projects exist locally" matcher.
///
/// Both `BackupCollector` (which then reads each project's sessions) and
/// `BackupPlan` (which does not) need the same three-way match between
/// `~/.claude.json` `projects` entries and the `projects/<encoded>/`
/// directories on disk. That logic lives here once so the two callers cannot
/// drift. Sessions are NOT read here — the `Entry.hasHistoryDir` flag records,
/// as a first-class fact, whether there is a directory a caller *could* read.
public enum ProjectInventory {
    /// One matched project. `hasHistoryDir` says whether a `projects/<encoded>/`
    /// directory is present to read sessions from — the collector reads sessions
    /// only when it is true; the plan ignores it (it never reads sessions).
    public struct Entry: Equatable, Sendable {
        /// Absolute project path (the `~/.claude.json` key). Empty for an orphan
        /// directory with no matching entry.
        public var path: String
        /// Encoded `projects/` directory name — the stable identity of the entry.
        public var encodedName: String
        /// The per-project object from `~/.claude.json` `projects` (generic JSON).
        public var settings: JSONValue?
        /// Whether a listable `projects/<encoded>/` directory exists on disk.
        public var hasHistoryDir: Bool
        /// True when the entry and its on-disk directory did not both exist.
        public var incomplete: Bool
        public var incompleteReason: String?

        public init(
            path: String,
            encodedName: String,
            settings: JSONValue? = nil,
            hasHistoryDir: Bool,
            incomplete: Bool,
            incompleteReason: String? = nil
        ) {
            self.path = path
            self.encodedName = encodedName
            self.settings = settings
            self.hasHistoryDir = hasHistoryDir
            self.incomplete = incomplete
            self.incompleteReason = incompleteReason
        }
    }

    /// Match `~/.claude.json` `projects` entries against `projects/<encoded>/`
    /// directories, in the stable order backup depends on: first the entries from
    /// `~/.claude.json` iterated by `keys.sorted()` (sorted by path), then orphan
    /// directories by `sorted()` (sorted by encoded name). Session contents are
    /// never read.
    public static func list(
        claudeJSON: JSONValue,
        fileSystem: FileSystem,
        paths: KnownPaths
    ) throws -> [Entry] {
        let projectSettings = claudeJSON["projects"]?.objectValue ?? [:]

        var existingDirs: Set<String> = []
        if isListableDirectory(paths.projectsDir, fileSystem: fileSystem) {
            existingDirs = Set(try fileSystem.listDirectory(paths.projectsDir))
        }

        var entries: [Entry] = []
        var matchedDirs: Set<String> = []

        // Entries from ~/.claude.json, linked to their history directory if present.
        for path in projectSettings.keys.sorted() {
            let encoded = ProjectPathEncoding.encode(path)
            // The name appearing in the listing is not enough: a `projects/<encoded>`
            // that is a symlink (or a plain file) is one the collector refuses to
            // read sessions from, so it must not be reported as a complete backup.
            // Gate on listability, exactly as the orphan branch below does.
            let hasDir = existingDirs.contains(encoded)
                && isListableDirectory(paths.projectDir(encoded: encoded), fileSystem: fileSystem)
            if existingDirs.contains(encoded) { matchedDirs.insert(encoded) }

            entries.append(Entry(
                path: path,
                encodedName: encoded,
                settings: projectSettings[path],
                hasHistoryDir: hasDir,
                incomplete: !hasDir,
                incompleteReason: hasDir ? nil : "no history directory on disk"
            ))
        }

        // History directories with no matching entry in ~/.claude.json.
        for dir in existingDirs.sorted() where !matchedDirs.contains(dir) {
            guard isListableDirectory(paths.projectDir(encoded: dir), fileSystem: fileSystem) else { continue }
            entries.append(Entry(
                path: "",
                encodedName: dir,
                settings: nil,
                hasHistoryDir: true,
                incomplete: true,
                incompleteReason: "no entry in ~/.claude.json"
            ))
        }

        return entries
    }

    /// A directory root we are willing to list. `isDirectory` follows symlinks, so
    /// a known root that is itself a symlink would otherwise be entered and its
    /// target scanned — refuse to list any root that is a symlink (mirrors
    /// `BackupCollector.isListableDirectory`).
    private static func isListableDirectory(_ path: String, fileSystem: FileSystem) -> Bool {
        fileSystem.isDirectory(path) && !fileSystem.isSymlink(path)
    }
}
