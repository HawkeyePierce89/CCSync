import Foundation

/// Errors from the archive layer. A corrupt archive or an invalid manifest is a
/// stop condition (see the plan's Error Handling section).
public enum ArchiveError: Error, Equatable {
    /// The byte stream is not a CCSync archive (bad magic / truncated header).
    case notAnArchive
    /// The archive is structurally corrupt (truncated entry, bad length).
    case corrupt(String)
    /// The manifest is missing or malformed.
    case invalidManifest(String)
}

/// A pure-Swift, in-memory container of named byte entries — the physical layer
/// of a CCSync archive.
///
/// Archive-layer decision (locked in Task 3): the container is assembled and
/// parsed entirely in memory from `Data`, with **no shell-out to system `tar`**
/// and no on-disk temp files. All disk I/O stays behind the `FileSystem`
/// boundary in `BackupService`/`RestoreService`, so the whole backup path is
/// testable on `InMemoryFileSystem`. The accepted real-FS-integration fallback
/// was **not** taken.
///
/// Wire format (all integers little-endian):
///   magic  : "CCSAR1\n"  (7 bytes)
///   count  : UInt32       (number of entries)
///   entry* : UInt32 pathByteCount, path UTF-8 bytes,
///            UInt64 dataByteCount, data bytes
enum ArchiveContainer {
    struct Entry: Equatable {
        var path: String
        var data: Data
    }

    static let magic = Data("CCSAR1\n".utf8)

    // MARK: - Pack

    static func pack(_ entries: [Entry]) -> Data {
        var out = Data()
        out.append(magic)
        out.appendUInt32(UInt32(entries.count))
        for entry in entries {
            let pathBytes = Data(entry.path.utf8)
            out.appendUInt32(UInt32(pathBytes.count))
            out.append(pathBytes)
            out.appendUInt64(UInt64(entry.data.count))
            out.append(entry.data)
        }
        return out
    }

    // MARK: - Unpack

    static func unpack(_ data: Data) throws -> [Entry] {
        var cursor = Cursor(data)
        guard let header = cursor.take(magic.count), header == magic else {
            throw ArchiveError.notAnArchive
        }
        guard let count = cursor.takeUInt32() else {
            throw ArchiveError.corrupt("missing entry count")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let pathLen = cursor.takeUInt32(),
                  let pathBytes = cursor.take(Int(pathLen)),
                  let path = String(data: pathBytes, encoding: .utf8) else {
                throw ArchiveError.corrupt("truncated entry path")
            }
            guard let dataLen = cursor.takeUInt64(),
                  let payload = cursor.take(Int(dataLen)) else {
                throw ArchiveError.corrupt("truncated entry payload")
            }
            entries.append(Entry(path: path, data: payload))
        }
        return entries
    }

    // MARK: - Cursor

    private struct Cursor {
        private let data: Data
        private var offset: Int
        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        mutating func take(_ length: Int) -> Data? {
            guard length >= 0, offset + length <= data.endIndex else { return nil }
            let slice = data.subdata(in: offset..<(offset + length))
            offset += length
            return slice
        }

        mutating func takeUInt32() -> UInt32? {
            guard let bytes = take(4) else { return nil }
            var result: UInt32 = 0
            for (index, byte) in bytes.enumerated() {
                result |= UInt32(byte) << (8 * index)
            }
            return result
        }

        mutating func takeUInt64() -> UInt64? {
            guard let bytes = take(8) else { return nil }
            var result: UInt64 = 0
            for (index, byte) in bytes.enumerated() {
                result |= UInt64(byte) << (8 * index)
            }
            return result
        }
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
