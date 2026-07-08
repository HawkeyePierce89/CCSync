import Foundation

/// Remaps the `/Users/<name>` home segment between two machines.
///
/// We deliberately do *not* decode and re-encode `projects/` directory names —
/// the encoding rule is version-fragile and reported inconsistently. Instead we
/// substitute only the user segment, which is the sole part of the path that
/// differs between machines:
///   - absolute paths:            `/Users/<from>/…` → `/Users/<to>/…`
///   - encoded project dir names: `-Users-<from>-…` → `-Users-<to>-…`
///
/// When the usernames match, every operation is a no-op.
public struct UserRemap: Sendable, Equatable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    /// True when source and target usernames are identical (all remaps are no-ops).
    public var isNoOp: Bool { from == to }

    // MARK: - Absolute paths

    /// Remap an absolute path that begins with `/Users/<from>`.
    ///
    /// Only the leading home segment is substituted; a `/Users/<from>` that
    /// appears elsewhere in the path (not as the prefix) is left untouched to
    /// avoid false positives.
    public func remapAbsolutePath(_ path: String) -> String {
        if isNoOp { return path }
        let fromPrefixSlash = "/Users/\(from)/"
        let toPrefixSlash = "/Users/\(to)/"
        if path.hasPrefix(fromPrefixSlash) {
            return toPrefixSlash + path.dropFirst(fromPrefixSlash.count)
        }
        let fromExact = "/Users/\(from)"
        if path == fromExact {
            return "/Users/\(to)"
        }
        return path
    }

    // MARK: - Encoded project directory names

    /// Remap an encoded `projects/` directory name that begins with
    /// `-Users-<from>-`. Only the leading user segment is substituted.
    ///
    /// The username inside an encoded name is itself run through the `projects/`
    /// encoding (non-alphanumeric → `-`), so a raw username like `alice.smith`
    /// appears as `alice-smith` in the directory name. We therefore match and
    /// substitute the *encoded* form of the user segment — otherwise history for
    /// users with `.`/`_`/etc. in their name would never remap (acceptance #3).
    public func remapEncodedProjectName(_ name: String) -> String {
        if isNoOp { return name }
        let fromEncoded = ProjectPathEncoding.encode(from)
        let toEncoded = ProjectPathEncoding.encode(to)
        let fromPrefix = "-Users-\(fromEncoded)-"
        let toPrefix = "-Users-\(toEncoded)-"
        if name.hasPrefix(fromPrefix) {
            return toPrefix + name.dropFirst(fromPrefix.count)
        }
        // Some project paths may encode to exactly `-Users-<from>` with no
        // trailing segment (the home directory itself).
        let fromExact = "-Users-\(fromEncoded)"
        if name == fromExact {
            return "-Users-\(toEncoded)"
        }
        return name
    }
}
