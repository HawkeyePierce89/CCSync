import Foundation

/// Reads a CCSync archive from raw `Data`: parses the manifest and gives access
/// to the packed payload entries (global config + per-project history).
///
/// The read side mirrors `ArchiveWriter`: everything is parsed in memory over
/// `Data` (see `ArchiveContainer`) with no temp files and no shell-out. Per the
/// plan's Error Handling section, a byte stream that is not a valid archive, or
/// an archive whose manifest is missing/malformed, is a stop condition — the
/// initialiser throws an `ArchiveError` and no partial result is produced.
public struct ArchiveReader {
    /// The parsed manifest (format version, source user, project list, source
    /// Claude Code version).
    public let manifest: Manifest

    /// All container entries by their logical path, including the manifest.
    private let entries: [String: Data]

    /// Parse `data` as a CCSync archive.
    ///
    /// - Throws: `ArchiveError.notAnArchive` / `.corrupt` if the container is not
    ///   a valid CCSAR1 byte stream, or `.invalidManifest` if the manifest entry
    ///   is absent or not parseable.
    public init(data: Data) throws {
        let unpacked = try ArchiveContainer.unpack(data)
        var byPath: [String: Data] = [:]
        for entry in unpacked {
            byPath[entry.path] = entry.data
        }
        guard let manifestData = byPath[ArchiveLayout.manifest] else {
            throw ArchiveError.invalidManifest("archive has no manifest entry")
        }
        self.manifest = try Manifest(data: manifestData)
        self.entries = byPath
    }

    // MARK: - Project list contract

    /// The machine-readable project list from the archive, for UI and CLI.
    public var restorePlan: RestorePlan { RestorePlan(manifest: manifest) }

    // MARK: - Payload access

    /// Raw payload bytes for a container entry path, or `nil` if absent. The
    /// manifest itself is addressable here too (`ArchiveLayout.manifest`).
    public func payload(at path: String) -> Data? {
        entries[path]
    }

    /// All container entry paths beginning with `prefix`, sorted.
    public func payloadPaths(withPrefix prefix: String) -> [String] {
        entries.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// Every container entry path, sorted (includes the manifest).
    public var allPaths: [String] { entries.keys.sorted() }
}
