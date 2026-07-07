import Foundation

/// Abstraction over filesystem access.
///
/// Every disk read/write in CCSync goes through this protocol so that backup and
/// restore can run against an in-memory implementation in tests, and so the
/// "don't scan the disk" invariant can be verified by asserting the exact set of
/// paths that were touched.
///
/// Paths are plain absolute-path strings. Directory operations are explicit
/// requests — there is no implicit recursive traversal in the protocol surface.
public protocol FileSystem {
    /// Whether a file or directory exists at `path`.
    func exists(_ path: String) -> Bool

    /// Whether `path` exists and is a directory.
    func isDirectory(_ path: String) -> Bool

    /// Whether `path` is itself a symbolic link (the link is *not* followed).
    /// Backup uses this to refuse to traverse symlinks planted under a known
    /// root, which could otherwise redirect collection outside the approved
    /// paths or form a cycle.
    func isSymlink(_ path: String) -> Bool

    /// Read the raw bytes of the file at `path`.
    /// Throws if the file does not exist or cannot be read.
    func readData(_ path: String) throws -> Data

    /// Write raw bytes to `path`, creating intermediate directories as needed.
    func writeData(_ data: Data, to path: String) throws

    /// List the immediate entry names (not full paths) of the directory at `path`.
    /// This is a single-level listing — it does not recurse.
    /// Throws if `path` is not an existing directory.
    func listDirectory(_ path: String) throws -> [String]

    /// Create a directory at `path`, including intermediate directories.
    func createDirectory(_ path: String) throws
}

public extension FileSystem {
    /// Convenience: read a UTF-8 text file.
    func readString(_ path: String) throws -> String {
        let data = try readData(path)
        guard let s = String(data: data, encoding: .utf8) else {
            throw FileSystemError.notUTF8(path)
        }
        return s
    }

    /// Convenience: write a UTF-8 text file.
    func writeString(_ string: String, to path: String) throws {
        try writeData(Data(string.utf8), to: path)
    }
}

public enum FileSystemError: Error, Equatable {
    case notFound(String)
    case notADirectory(String)
    case notUTF8(String)
}

/// Real filesystem implementation backed by `FileManager`.
public struct RealFileSystem: FileSystem {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func exists(_ path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    public func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let ok = fileManager.fileExists(atPath: path, isDirectory: &isDir)
        return ok && isDir.boolValue
    }

    public func isSymlink(_ path: String) -> Bool {
        // `attributesOfItem` uses lstat semantics — it describes the link itself,
        // not its target — so a symlink reports `.typeSymbolicLink` here even
        // when it points at a directory.
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else {
            return false
        }
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    public func readData(_ path: String) throws -> Data {
        guard fileManager.fileExists(atPath: path) else {
            throw FileSystemError.notFound(path)
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func writeData(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url)
    }

    public func listDirectory(_ path: String) throws -> [String] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
            throw FileSystemError.notFound(path)
        }
        guard isDir.boolValue else {
            throw FileSystemError.notADirectory(path)
        }
        return try fileManager.contentsOfDirectory(atPath: path)
    }

    public func createDirectory(_ path: String) throws {
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: path),
            withIntermediateDirectories: true
        )
    }
}
