import Foundation

/// Deep merge for the generic `JSONValue`s that flow into `~/.claude.json`.
///
/// Restore never rewrites `~/.claude.json` wholesale — that would wipe unknown or
/// future keys and other machines' project entries. Instead the incoming global
/// `mcpServers` block and each per-project entry are deep-merged into the existing
/// document:
///   - object ⊕ object → merge key-by-key, recursing into shared keys,
///   - any other pairing (scalar, array, type mismatch) → the incoming value wins.
///
/// Keys present only in the base survive untouched, which is what preserves other
/// projects' entries and future config the tool does not model.
public enum JSONMerge {
    public static func merge(_ base: JSONValue, _ incoming: JSONValue) -> JSONValue {
        guard case let .object(baseObject) = base,
              case let .object(incomingObject) = incoming else {
            return incoming
        }
        var result = baseObject
        for (key, incomingValue) in incomingObject {
            if let existing = result[key] {
                result[key] = merge(existing, incomingValue)
            } else {
                result[key] = incomingValue
            }
        }
        return .object(result)
    }
}
