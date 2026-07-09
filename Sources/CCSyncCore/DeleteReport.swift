import Foundation

/// What a delete run does to each selected project.
public enum DeleteOperation: Equatable, Sendable {
    /// Remove the project's Claude Code footprint only (history dir + linked
    /// per-session artifacts + its one `~/.claude.json` key). The project folder
    /// on disk is left untouched.
    case claudeDataOnly
    /// The Claude-data cleanup above *plus* the project folder on disk, subject to
    /// the folder-removal sanity guards (never `/` or home, never a symlink).
    case entireProject
}

/// The outcome of a delete run: what was deleted, what was skipped and why, and
/// any advisory warnings (e.g. a folder that could not be removed). Its shape
/// mirrors `RestoreReport` so the CLI JSON serialisation is symmetric.
///
/// Deletion is best-effort: a folder that fails a guard is warned about while the
/// project's Claude data is still removed; only a project where **nothing** was
/// deleted lands in `skippedProjects`.
public struct DeleteReport: Equatable, Sendable {
    /// A project whose Claude data (and possibly folder) was removed.
    public struct DeletedProject: Equatable, Sendable {
        /// The project path (the `~/.claude.json` key); empty for an orphan.
        public var path: String
        /// The encoded `projects/` directory name — the stable identity.
        public var encodedName: String
        /// Whether the project folder on disk was actually removed.
        public var folderRemoved: Bool
        /// The exact paths that were targeted for removal.
        public var removedPaths: [String]

        public init(
            path: String,
            encodedName: String,
            folderRemoved: Bool,
            removedPaths: [String]
        ) {
            self.path = path
            self.encodedName = encodedName
            self.folderRemoved = folderRemoved
            self.removedPaths = removedPaths
        }
    }

    /// A project that was selected but where nothing was deleted.
    public struct SkippedProject: Equatable, Sendable {
        public var path: String
        public var encodedName: String
        public var reason: String

        public init(path: String, encodedName: String, reason: String) {
            self.path = path
            self.encodedName = encodedName
            self.reason = reason
        }
    }

    /// Whether this was a dry run (no side effects performed).
    public var dryRun: Bool
    /// Projects whose Claude data (and possibly folder) was removed.
    public var deletedProjects: [DeletedProject]
    /// Projects that were selected but had nothing to delete.
    public var skippedProjects: [SkippedProject]
    /// Advisory warnings (a refused folder removal, an already-missing path, …).
    public var warnings: [String]

    public init(
        dryRun: Bool = false,
        deletedProjects: [DeletedProject] = [],
        skippedProjects: [SkippedProject] = [],
        warnings: [String] = []
    ) {
        self.dryRun = dryRun
        self.deletedProjects = deletedProjects
        self.skippedProjects = skippedProjects
        self.warnings = warnings
    }
}
