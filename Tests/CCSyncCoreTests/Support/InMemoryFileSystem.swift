import Foundation
@testable import CCSyncCore

/// In-memory `FileSystem` used by tests. It logs every access into `journal`
/// so tests can assert the exact set of paths that were touched — this is how
/// the "don't scan the disk" invariant is verified.
final class InMemoryFileSystem: FileSystem {

    /// A single recorded access.
    enum Access: Equatable {
        case exists(String)
        case isDirectory(String)
        case isSymlink(String)
        case readData(String)
        case writeData(String)
        case listDirectory(String)
        case createDirectory(String)
        case removeItem(String)

        var path: String {
            switch self {
            case .exists(let p), .isDirectory(let p), .isSymlink(let p), .readData(let p),
                 .writeData(let p), .listDirectory(let p), .createDirectory(let p),
                 .removeItem(let p):
                return p
            }
        }
    }

    /// Ordered log of every access.
    private(set) var journal: [Access] = []

    /// Backing store: absolute file path → contents.
    private var files: [String: Data] = [:]
    /// Set of directory paths that exist.
    private var directories: Set<String> = ["/"]
    /// Paths seeded as symbolic links (their targets are not modeled — the
    /// collector must refuse to follow them, so the target is irrelevant).
    private var symlinks: Set<String> = []

    /// Injectable fault hook: keyed by path, forces `removeItem` to throw the
    /// mapped error so a test can simulate a permission-style failure.
    var removeItemErrors: [String: Error] = [:]

    init() {}

    // MARK: - Fixture helpers

    /// Seed a file with UTF-8 text, creating parent directories. Not journalled.
    func seedFile(_ path: String, _ contents: String) {
        seedFile(path, Data(contents.utf8))
    }

    /// Seed a file with raw bytes, creating parent directories. Not journalled.
    func seedFile(_ path: String, _ data: Data) {
        files[path] = data
        seedParentDirectories(of: path)
    }

    /// Seed an empty directory (and its parents). Not journalled.
    func seedDirectory(_ path: String) {
        let normalised = normalise(path)
        directories.insert(normalised)
        seedParentDirectories(of: normalised)
    }

    /// Seed a symbolic link at `path`. Also registers it as a listable entry
    /// (a plain file) so a directory listing surfaces it; the collector is
    /// expected to skip it once `isSymlink` reports true. Not journalled.
    func seedSymlink(_ path: String) {
        let normalised = normalise(path)
        symlinks.insert(normalised)
        files[normalised] = Data()
        seedParentDirectories(of: normalised)
    }

    private func seedParentDirectories(of path: String) {
        var current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty && current != "/" {
            directories.insert(current)
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private func normalise(_ path: String) -> String {
        if path.count > 1 && path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }

    /// All paths that were touched, in order.
    var touchedPaths: [String] { journal.map(\.path) }

    /// Current backing store contents (test-only), not journalled.
    var allFiles: [String: Data] { files }

    // MARK: - FileSystem

    func exists(_ path: String) -> Bool {
        journal.append(.exists(path))
        let p = normalise(path)
        return files[p] != nil || files[path] != nil || directories.contains(p)
    }

    func isDirectory(_ path: String) -> Bool {
        journal.append(.isDirectory(path))
        return directories.contains(normalise(path))
    }

    func isSymlink(_ path: String) -> Bool {
        journal.append(.isSymlink(path))
        return symlinks.contains(normalise(path))
    }

    func readData(_ path: String) throws -> Data {
        journal.append(.readData(path))
        guard let data = files[path] else {
            throw FileSystemError.notFound(path)
        }
        return data
    }

    func writeData(_ data: Data, to path: String) throws {
        journal.append(.writeData(path))
        files[path] = data
        seedParentDirectories(of: path)
    }

    func listDirectory(_ path: String) throws -> [String] {
        journal.append(.listDirectory(path))
        let dir = normalise(path)
        guard directories.contains(dir) else {
            throw FileSystemError.notFound(path)
        }
        let prefix = dir == "/" ? "/" : dir + "/"
        var names = Set<String>()
        for filePath in files.keys where filePath.hasPrefix(prefix) {
            let rest = filePath.dropFirst(prefix.count)
            if let first = rest.split(separator: "/", maxSplits: 1).first {
                names.insert(String(first))
            }
        }
        for dirPath in directories where dirPath != dir && dirPath.hasPrefix(prefix) {
            let rest = dirPath.dropFirst(prefix.count)
            if let first = rest.split(separator: "/", maxSplits: 1).first {
                names.insert(String(first))
            }
        }
        return names.sorted()
    }

    func createDirectory(_ path: String) throws {
        journal.append(.createDirectory(path))
        let dir = normalise(path)
        directories.insert(dir)
        seedParentDirectories(of: dir)
    }

    func removeItem(_ path: String) throws {
        journal.append(.removeItem(path))
        if let error = removeItemErrors[path] ?? removeItemErrors[normalise(path)] {
            throw error
        }
        let target = normalise(path)
        let existsExactFile = files[path] != nil || files[target] != nil
        let existsDir = directories.contains(target)
        guard existsExactFile || existsDir else {
            throw FileSystemError.notFound(path)
        }
        // Remove the exact entry plus everything under it (path + "/").
        let subtreePrefix = target + "/"
        files = files.filter { key, _ in
            !(key == path || key == target || key.hasPrefix(subtreePrefix))
        }
        directories = directories.filter { dir in
            !(dir == target || dir.hasPrefix(subtreePrefix))
        }
        symlinks = symlinks.filter { link in
            !(link == target || link.hasPrefix(subtreePrefix))
        }
    }
}
