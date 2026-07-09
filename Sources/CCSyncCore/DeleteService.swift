import Foundation

/// A stop condition during a delete run. Deletion is best-effort per project, but
/// a genuine filesystem failure (a `removeItem` or `~/.claude.json` write that
/// fails for a reason other than "already gone" — e.g. a permission error) halts
/// the run. There is **no rollback**: whatever was already deleted stays deleted.
public enum DeleteError: Error, Equatable {
    /// A `removeItem` failed for a reason other than the target being absent.
    case removeFailed(String)
    /// Writing the mutated `~/.claude.json` back failed.
    case writeFailed(String)
}

/// Public delete API: permanently remove selected projects' Claude Code footprint,
/// and optionally their on-disk folders, by an explicit `Selection`. Everything
/// runs through the injected `FileSystem`, so a full delete is exercised on
/// `InMemoryFileSystem`.
///
/// Behaviour (per the plan and the locked decisions):
///   - Source of truth is a fresh `~/.claude.json` read with the **same no-follow
///     symlink guard as `BackupPlan`** (a symlinked config is treated as absent),
///     fed through `ProjectInventory` — so orphan history directories are visible
///     and selectable.
///   - Per selected project the Claude-data cleanup (history dir + linked
///     per-session artifacts + the one `~/.claude.json` `projects[<path>]` key)
///     always proceeds. For `.entireProject` the project folder is then removed,
///     subject to the folder-removal sanity guards (never `/` or home, never a
///     symlink, missing is a no-op) — a failed guard is warned-about with a
///     **verbatim** wording while the data is still cleaned.
///   - A project where **nothing** was deleted lands in `skippedProjects`
///     (`nothing to delete — already gone`); a folder is never reported as removed
///     when it wasn't.
///   - `dryRun` computes the identical report but performs no `removeItem` /
///     `writeData`, so the would-be report equals the real report for the same
///     selection — only the side effects differ.
///   - No snapshot is taken (the snapshot policy is restore-only).
public struct DeleteService {
    private let fs: FileSystem
    private let paths: KnownPaths

    public init(fileSystem: FileSystem, paths: KnownPaths) {
        self.fs = fileSystem
        self.paths = paths
    }

    /// Delete the selected projects according to `operation`. Throws only on a
    /// stop condition (a `removeItem`/write failure that is not "already gone");
    /// a guard-refused folder or an already-missing path is reported, not thrown.
    @discardableResult
    public func delete(
        selection: Selection,
        operation: DeleteOperation,
        dryRun: Bool
    ) throws -> DeleteReport {
        var claudeJSON = try readClaudeJSON()
        let inventory = try ProjectInventory.list(claudeJSON: claudeJSON, fileSystem: fs, paths: paths)
        let locator = ProjectDataLocator(fileSystem: fs, paths: paths)

        var report = DeleteReport(dryRun: dryRun)
        var claudeJSONDirty = false

        // The selection identity is `encodedName`, but the path→name encoding is
        // lossy (every non-alphanumeric collapses to `-`), so two distinct project
        // paths — e.g. `/Users/x/a-b` and `/Users/x/a_b` — can share one encoded
        // name. Acting on a selected-but-ambiguous name would delete *both* projects'
        // folders and `~/.claude.json` keys from a single-project selection: an
        // irreversible over-delete. Refuse any ambiguous selection — skip+warn,
        // delete nothing for it — and let the user disambiguate manually.
        var encodedNameCounts: [String: Int] = [:]
        for entry in inventory { encodedNameCounts[entry.encodedName, default: 0] += 1 }

        for entry in inventory
        where selection.projectEncodedNames.contains(entry.encodedName) {
            if encodedNameCounts[entry.encodedName, default: 0] > 1 {
                report.skippedProjects.append(.init(
                    path: entry.path,
                    encodedName: entry.encodedName,
                    reason: "ambiguous encoded name — another project path maps to the same "
                        + "Claude directory; refused to delete, disambiguate manually"
                ))
                continue
            }
            try process(
                entry,
                operation: operation,
                dryRun: dryRun,
                locator: locator,
                claudeJSON: &claudeJSON,
                dirty: &claudeJSONDirty,
                report: &report
            )
        }

        // Write the mutated document back once, at the end — only when a key was
        // actually removed and this is a real run. The read above already refuses
        // a symlinked config (so `dirty` can't be set through one), but guard the
        // write for the same reason as `RestoreService`.
        if claudeJSONDirty && !dryRun && !fs.isSymlink(paths.claudeJSON) {
            do {
                try fs.writeData(try claudeJSON.serialized(pretty: true), to: paths.claudeJSON)
            } catch {
                throw DeleteError.writeFailed(paths.claudeJSON)
            }
        }

        return report
    }

    // MARK: - Per-project

    private func process(
        _ entry: ProjectInventory.Entry,
        operation: DeleteOperation,
        dryRun: Bool,
        locator: ProjectDataLocator,
        claudeJSON: inout JSONValue,
        dirty: inout Bool,
        report: inout DeleteReport
    ) throws {
        // 1. Claude-data paths on disk (history dir + linked artifacts). The
        //    locator only returns real, present, non-symlink roots (invariant #1).
        let dataPaths = try locator.removablePaths(encodedName: entry.encodedName)

        // 2. The one `~/.claude.json` key, computed surgically. `existed == false`
        //    for an orphan (empty path) or a project with no entry.
        let (prunedJSON, keyExisted) = entry.path.isEmpty
            ? (claudeJSON, false)
            : JSONMerge.removeProject(entry.path, from: claudeJSON)

        // 3. Folder handling — only for "entirely" on a real (non-orphan) project.
        //    Guards are re-checked here at execution time; an orphan degenerates to
        //    data-only silently.
        var removedPaths = dataPaths
        var folderRemoved = false
        var folderWarning: String?
        if operation == .entireProject && !entry.path.isEmpty {
            switch ManagePlan.folderStatus(for: entry.path, fileSystem: fs, paths: paths) {
            case .deletable:
                removedPaths.append(entry.path)
                folderRemoved = true
            case .unsafePath:
                folderWarning = "refused to delete project folder (unsafe path: \(entry.path)) — Claude data removed"
            case .symlink:
                folderWarning = "project path is a symlink — folder not removed, Claude data removed"
            case .missing:
                folderWarning = "project folder not found on disk — Claude data removed, nothing to delete for the folder"
            case .orphan:
                break // unreachable: guarded by `!entry.path.isEmpty`.
            }
        }

        // 4. Nothing at all to delete → skip, and emit no misleading folder
        //    warning (the guard warnings all claim "Claude data removed").
        guard !dataPaths.isEmpty || keyExisted || folderRemoved else {
            report.skippedProjects.append(.init(
                path: entry.path,
                encodedName: entry.encodedName,
                reason: "nothing to delete — already gone"
            ))
            return
        }

        // 5. Perform side effects (skipped entirely on a dry run).
        if !dryRun {
            for path in dataPaths {
                do {
                    try fs.removeItem(path)
                } catch FileSystemError.notFound {
                    // Raced away between discovery and removal — advisory, not fatal.
                    report.warnings.append("path already gone, skipped: \(path)")
                } catch {
                    throw DeleteError.removeFailed(path)
                }
            }
            if folderRemoved {
                do {
                    try fs.removeItem(entry.path)
                } catch {
                    throw DeleteError.removeFailed(entry.path)
                }
            }
        }

        // 6. Commit the key removal to the in-memory document; the batched
        //    write-back happens once at the end.
        if keyExisted {
            claudeJSON = prunedJSON
            dirty = true
        }

        if let folderWarning { report.warnings.append(folderWarning) }
        report.deletedProjects.append(.init(
            path: entry.path,
            encodedName: entry.encodedName,
            folderRemoved: folderRemoved,
            removedPaths: removedPaths
        ))
    }

    // MARK: - Helpers

    /// Read `~/.claude.json` with the same no-follow symlink guard as `BackupPlan`:
    /// a symlinked config is treated as absent so it can't redirect the read.
    private func readClaudeJSON() throws -> JSONValue {
        guard fs.exists(paths.claudeJSON), !fs.isSymlink(paths.claudeJSON) else { return .object([:]) }
        return try JSONValue(data: fs.readData(paths.claudeJSON))
    }
}
