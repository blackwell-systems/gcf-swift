import Foundation

/// Dictionary that preserves insertion order of keys.
/// Used for conformance-grade JSON round-tripping where key order matters.
public class OrderedDictionary: NSObject {
    private var keys: [String] = []
    private var values: [String: Any] = [:]

    public override init() {
        super.init()
    }

    public init(_ pairs: [(String, Any)]) {
        super.init()
        for (k, v) in pairs {
            self[k] = v
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public var orderedKeys: [String] { keys }

    public var orderedPairs: [(String, Any)] {
        keys.map { ($0, values[$0]!) }
    }

    public subscript(key: String) -> Any? {
        get { values[key] }
        set {
            if let val = newValue {
                if values[key] == nil {
                    keys.append(key)
                }
                values[key] = val
            } else {
                if values[key] != nil {
                    keys.removeAll { $0 == key }
                    values[key] = nil
                }
            }
        }
    }

    public func contains(_ key: String) -> Bool {
        values[key] != nil
    }
}

/// Parse JSON preserving insertion order using OrderedDictionary.
public func parseJSONOrdered(_ data: Data) throws -> Any {
    let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return convertOrdered(raw, jsonBytes: data)
}

/// Convert a JSONSerialization result into OrderedDictionary-based tree,
/// re-parsing objects to recover insertion order from the raw bytes.
private func convertOrdered(_ value: Any, jsonBytes: Data) -> Any {
    if let nsDict = value as? NSDictionary {
        // Re-parse to get insertion order from the raw JSON.
        // JSONSerialization doesn't guarantee order, so we scan the bytes.
        let od = OrderedDictionary()
        let orderedKeys = extractKeyOrder(from: jsonBytes, keys: nsDict.allKeys.compactMap { $0 as? String })
        for key in orderedKeys {
            if let v = nsDict[key] {
                od[key] = convertOrdered(v, jsonBytes: jsonBytes)
            }
        }
        // Add any keys we missed (shouldn't happen, but safety).
        for key in nsDict.allKeys.compactMap({ $0 as? String }) {
            if !od.contains(key) {
                od[key] = convertOrdered(nsDict[key]!, jsonBytes: jsonBytes)
            }
        }
        return od
    }
    if let arr = value as? [Any] {
        return arr.map { convertOrdered($0, jsonBytes: jsonBytes) }
    }
    return value
}

/// Extract key order by finding their first occurrence positions in the JSON bytes.
/// This is a best-effort approach that works for non-nested duplicate keys.
private func extractKeyOrder(from data: Data, keys: [String]) -> [String] {
    guard let str = String(data: data, encoding: .utf8) else { return keys.sorted() }
    var positions: [(String, Int)] = []
    for key in keys {
        // Search for "key": pattern. Use the first occurrence.
        let searchPattern = "\"\(escapeForSearch(key))\""
        if let range = str.range(of: searchPattern) {
            positions.append((key, str.distance(from: str.startIndex, to: range.lowerBound)))
        } else {
            positions.append((key, Int.max))
        }
    }
    positions.sort { $0.1 < $1.1 }
    return positions.map { $0.0 }
}

private func escapeForSearch(_ s: String) -> String {
    var out = ""
    for c in s {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        default: out.append(c)
        }
    }
    return out
}
