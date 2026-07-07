import Foundation

/// A generic JSON value used everywhere CCSync touches `~/.claude.json`.
///
/// We deliberately avoid a strict model so that unknown/future keys survive a
/// round-trip untouched (a hard requirement for merging into `~/.claude.json`).
/// Integers and floating-point numbers are kept distinct so re-serialisation
/// does not turn metric counters into `1.0`.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public extension JSONValue {
    /// Parse from raw JSON bytes (fragments allowed).
    init(data: Data) throws {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self.init(foundation: obj)
    }

    /// Wrap a Foundation object produced by `JSONSerialization`.
    init(foundation object: Any) {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let type = String(cString: number.objCType, encoding: .ascii),
                      type == "d" || type == "f" {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(foundation: $0) })
        case let dict as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (key, value) in dict { out[key] = JSONValue(foundation: value) }
            self = .object(out)
        case is NSNull:
            self = .null
        default:
            self = .null
        }
    }

    /// Convert back to a Foundation object suitable for `JSONSerialization`.
    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .object(let object):
            var out: [String: Any] = [:]
            for (key, value) in object { out[key] = value.foundationObject }
            return out
        }
    }

    /// Serialise to JSON bytes. Keys are sorted so output is deterministic.
    func serialized(pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: foundationObject, options: options)
    }

    // MARK: - Accessors

    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Child value by key (nil unless this is an object containing `key`).
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}
