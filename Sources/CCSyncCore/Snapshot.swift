import Foundation

/// Non-destructive snapshot of the current on-disk state, taken before any file
/// is overwritten during a restore.
///
/// Snapshot policy (locked for Task 5):
///   - **Location.** `~/.claude/.ccsync-backups/<timestamp>/`, mirroring each
///     captured file at its path relative to the home directory.
///   - **Mid-restore failure.** No auto-rollback. If a restore throws partway
///     through, the snapshot is left in place for manual recovery — restoring by
///     hand from a complete snapshot is simpler and less surprising than a partial
///     automatic undo. Callers surface the snapshot path so the user can recover.
///   - **Old snapshots.** Never cleaned up automatically; each restore writes a new
///     timestamped directory. Pruning old snapshots is left to the user.
///
/// Every capture goes through the injected `FileSystem`, so snapshotting is fully
/// exercised on `InMemoryFileSystem`.
public struct Snapshot {
    private let fs: FileSystem
    private let home: String
    /// Absolute path of this snapshot's root directory.
    public let root: String

    public init(fileSystem: FileSystem, home: String, timestamp: String) {
        self.fs = fileSystem
        self.home = (home.count > 1 && home.hasSuffix("/")) ? String(home.dropLast()) : home
        self.root = KnownPaths.join(KnownPaths.join(self.home, ".claude/.ccsync-backups"), timestamp)
    }

    /// Copy the current contents of `path` into the snapshot before it is
    /// overwritten. Returns `true` when a file was actually captured; a no-op
    /// (returns `false`) when `path` does not exist or is a directory.
    @discardableResult
    public func capture(_ path: String) throws -> Bool {
        guard fs.exists(path), !fs.isDirectory(path) else { return false }
        let data = try fs.readData(path)
        try fs.writeData(data, to: destination(for: path))
        return true
    }

    /// Snapshot location for a captured path: its path relative to home, rehomed
    /// under `root`. Paths outside home fall back to their absolute layout.
    private func destination(for path: String) -> String {
        let homePrefix = home + "/"
        let relative: String
        if path.hasPrefix(homePrefix) {
            relative = String(path.dropFirst(homePrefix.count))
        } else {
            relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        return KnownPaths.join(root, relative)
    }
}
