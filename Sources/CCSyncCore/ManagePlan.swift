import Foundation

/// The machine-readable "project list for the Manage tab" contract.
///
/// `ManagePlan` wraps a `BackupPlan` (the same local-machine inventory the Backup
/// screen binds to) and augments it with a per-project *folder status* — a Core
/// pre-computation of whether the project's on-disk folder can be safely removed
/// by "Delete project entirely". This is an early UI signal only: `DeleteService`
/// re-checks the same guards at execution time, since the CLI has no UI and the
/// disk may change while the window is open.
///
/// Existence/symlink checks are made through `FileSystem` on the explicit project
/// paths only — the filesystem is never scanned (invariant #1).
public struct ManagePlan: Equatable, Sendable {
    /// Per-project on-disk folder status for "Delete project entirely".
    public enum FolderStatus: Equatable, Sendable {
        /// A real (non-symlink) directory exists at the project path — the folder
        /// can be removed.
        case deletable
        /// The path is `/` or the home directory — refused as a delete target.
        case unsafePath
        /// No directory exists at the path — nothing to delete for the folder.
        case missing
        /// The entry at the path is a symlink — the link is never followed and the
        /// target is never removed.
        case symlink
        /// The project has no path (`path.isEmpty`) — an orphan history directory
        /// with no `~/.claude.json` entry, so there is no folder at all.
        case orphan
    }

    /// The underlying local inventory (identical to what the Backup screen sees).
    public var plan: BackupPlan
    /// Folder status per project, keyed by `encodedName`.
    public var folderStatuses: [String: FolderStatus]

    public init(plan: BackupPlan, folderStatuses: [String: FolderStatus]) {
        self.plan = plan
        self.folderStatuses = folderStatuses
    }

    /// Build the plan off the local machine, computing each project's folder
    /// status by probing only the explicit project path (no scanning).
    public init(fileSystem: FileSystem, paths: KnownPaths, sourceUser: String? = nil) throws {
        let plan = try BackupPlan(fileSystem: fileSystem, paths: paths, sourceUser: sourceUser)
        var statuses: [String: FolderStatus] = [:]
        for project in plan.projects {
            statuses[project.encodedName] = Self.folderStatus(
                for: project.path, fileSystem: fileSystem, paths: paths
            )
        }
        self.init(plan: plan, folderStatuses: statuses)
    }

    /// Derive the folder status for a project path. The check order matches the
    /// locked decision: orphan → unsafe → symlink → missing → deletable.
    static func folderStatus(for path: String, fileSystem: FileSystem, paths: KnownPaths) -> FolderStatus {
        guard !path.isEmpty else { return .orphan }
        let normalized = KnownPaths.normalize(path)
        if normalized == "/" || normalized == KnownPaths.normalize(paths.home) {
            return .unsafePath
        }
        if fileSystem.isSymlink(path) { return .symlink }
        // `isDirectory` follows symlinks, but a symlink at the path was already
        // handled above, so this only ever sees a real (non-symlink) entry.
        if !fileSystem.isDirectory(path) { return .missing }
        return .deletable
    }

    // MARK: - Presentation helpers

    /// The single Core wording for a row caption describing why "Delete project
    /// entirely" will fall back to Claude-data-only for this project. `nil` when
    /// the folder is `deletable` (no caption) or an `orphan` (which already
    /// renders its `incompleteSummary`).
    public func folderCaption(for encodedName: String) -> String? {
        switch folderStatuses[encodedName] {
        case .deletable, .orphan, .none:
            return nil
        case .missing:
            return "folder already gone — Claude data only"
        case .unsafePath:
            return "unsafe path — Claude data only"
        case .symlink:
            return "symlink — Claude data only"
        }
    }

    /// Split a selection into the count of selected projects whose folder will be
    /// removed versus those that will have Claude data cleaned only. Used by the
    /// confirmation modal's "N project folders will be deleted, M will have Claude
    /// data cleaned only" copy.
    public func deletionSplit(selection: Selection) -> (folders: Int, dataOnly: Int) {
        var folders = 0
        var dataOnly = 0
        for name in selection.projectEncodedNames {
            if folderStatuses[name] == .deletable {
                folders += 1
            } else {
                dataOnly += 1
            }
        }
        return (folders, dataOnly)
    }
}
