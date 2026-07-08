import Foundation

/// Public backup API: collects the in-memory model via `BackupCollector`, packs
/// it with `ArchiveWriter`, and writes the archive through `FileSystem`.
///
/// The default destination is the home directory (`~/ccsync-backup.ccsync`); a
/// full destination path may be supplied instead. All disk access — reads during
/// collection and the single archive write — goes through the injected
/// `FileSystem`, so a full backup runs on `InMemoryFileSystem` without touching
/// the real disk.
public struct BackupService {
    /// Default archive filename written into the home directory.
    public static let defaultFileName = "ccsync-backup.ccsync"

    private let fs: FileSystem
    private let paths: KnownPaths
    private let sourceUser: String?
    private let sourceClaudeVersion: String?

    public init(
        fileSystem: FileSystem,
        paths: KnownPaths,
        sourceUser: String? = nil,
        sourceClaudeVersion: String? = nil
    ) {
        self.fs = fileSystem
        self.paths = paths
        self.sourceUser = sourceUser
        self.sourceClaudeVersion = sourceClaudeVersion
    }

    /// Collect, pack, and write the archive. Returns the destination path.
    ///
    /// - Parameters:
    ///   - destination: a full archive file path, or `nil` to write
    ///     `~/ccsync-backup.ccsync`. An existing directory path is treated as a
    ///     folder and the default filename is written inside it.
    ///   - selection: which layers to capture, forwarded to the collector. `nil`
    ///     means "everything" and exists only for backward compatibility with
    ///     existing `backup(to:)` call sites — GUI and CLI always pass an
    ///     explicit, non-nil `Selection` from `SelectionTree.resolvedSelection()`.
    @discardableResult
    public func backup(to destination: String? = nil, selection: Selection? = nil) throws -> String {
        let model = try BackupCollector(fileSystem: fs, paths: paths, sourceUser: sourceUser).collect(selection: selection)
        let archive = try ArchiveWriter().makeArchive(from: model, sourceClaudeVersion: sourceClaudeVersion)
        let path = resolveDestination(destination)
        try fs.writeData(archive, to: path)
        return path
    }

    private func resolveDestination(_ destination: String?) -> String {
        guard let destination else {
            return KnownPaths.join(paths.home, Self.defaultFileName)
        }
        if fs.isDirectory(destination) {
            return KnownPaths.join(destination, Self.defaultFileName)
        }
        return destination
    }
}
