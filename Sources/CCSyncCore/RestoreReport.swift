import Foundation

/// The outcome of a restore run: what was applied, what was skipped and why, and
/// any advisory warnings (e.g. a version mismatch). Restore never throws for an
/// on-disk-missing project — it records it here and carries on.
public struct RestoreReport: Equatable, Sendable {
    /// A project that was selected but could not be applied.
    public struct SkippedProject: Equatable, Sendable {
        /// The (remapped, where known) project path.
        public var path: String
        /// The (remapped, where known) encoded `projects/` directory name.
        public var encodedName: String
        /// Human-readable reason it was skipped.
        public var reason: String

        public init(path: String, encodedName: String, reason: String) {
            self.path = path
            self.encodedName = encodedName
            self.reason = reason
        }
    }

    /// Whether the global config layer was applied.
    public var globalRestored: Bool
    /// Remapped paths of the projects that were restored.
    public var restoredProjects: [String]
    /// Projects that were selected but skipped, with reasons.
    public var skippedProjects: [SkippedProject]
    /// Advisory warnings (version mismatch, etc.); none of these stop the restore.
    public var warnings: [String]
    /// The snapshot root, set when at least one file was captured before overwrite.
    public var snapshotPath: String?

    public init(
        globalRestored: Bool = false,
        restoredProjects: [String] = [],
        skippedProjects: [SkippedProject] = [],
        warnings: [String] = [],
        snapshotPath: String? = nil
    ) {
        self.globalRestored = globalRestored
        self.restoredProjects = restoredProjects
        self.skippedProjects = skippedProjects
        self.warnings = warnings
        self.snapshotPath = snapshotPath
    }
}
