import Foundation

/// Encode any value into GCF tabular format.
///
/// Handles Dictionary, Array, String, Int, Double, Bool, and nil.
/// Uniform object arrays are rendered as tabular rows; nested dicts use
/// `## key` section headers; primitives use `key=value`.
public func encodeGeneric(_ data: Any?) -> String {
    guard let data = data else { return "" }

    if let dict = data as? [String: Any] {
        var lines: [String] = []
        encodeObjectEntries(dict, lines: &lines, depth: 0)
        if lines.isEmpty { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    if let arr = data as? [Any] {
        if arr.isEmpty { return "" }
        var lines: [String] = []
        encodeArray(arr, name: "root", lines: &lines, depth: 0)
        return lines.joined(separator: "\n") + "\n"
    }

    // Primitive.
    return formatPrimitive(data)
}

// MARK: - Private Helpers

private func formatPrimitive(_ value: Any?) -> String {
    guard let value = value else { return "-" }
    if let b = value as? Bool { return b ? "true" : "false" }
    if let i = value as? Int { return String(i) }
    if let d = value as? Double {
        if d == d.rounded(.towardZero) && abs(d) < 1e15 {
            return String(Int(d))
        }
        return String(d)
    }
    if let s = value as? String { return s }
    return String(describing: value)
}

private func formatValue(_ value: Any?) -> String {
    guard let value = value else { return "-" }
    if let b = value as? Bool { return b ? "true" : "false" }
    if let i = value as? Int { return String(i) }
    if let d = value as? Double {
        if d == d.rounded(.towardZero) && abs(d) < 1e15 {
            return String(Int(d))
        }
        return String(d)
    }
    if let s = value as? String {
        if s.isEmpty { return "\"\"" }
        if s.contains("|") || s.contains("\n") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return s
    }
    return "-"
}

private func indentStr(_ depth: Int) -> String {
    return String(repeating: "  ", count: depth)
}

private func isObject(_ value: Any) -> Bool {
    return value is [String: Any]
}

private func isArray(_ value: Any) -> Bool {
    return value is [Any]
}

private func isUniformObjectArray(_ arr: [Any]) -> Bool {
    guard !arr.isEmpty else { return false }
    guard let first = arr[0] as? [String: Any], !first.isEmpty else { return false }
    let firstKeys = Set(first.keys)

    let checkCount = min(5, arr.count)
    for i in 1..<checkCount {
        guard let obj = arr[i] as? [String: Any] else { return false }
        let itemKeys = Set(obj.keys)
        let overlap = firstKeys.intersection(itemKeys).count
        if Double(overlap) < Double(firstKeys.count) * 0.7 {
            return false
        }
    }
    return true
}

private func encodeArray(_ arr: [Any], name: String, lines: inout [String], depth: Int) {
    let prefix = indentStr(depth)

    if arr.isEmpty {
        lines.append("\(prefix)## \(name) [0]")
        return
    }

    if isUniformObjectArray(arr) {
        encodeTabular(arr, name: name, lines: &lines, depth: depth)
        return
    }

    // Non-uniform array.
    lines.append("\(prefix)## \(name) [\(arr.count)]")
    for (i, item) in arr.enumerated() {
        if isObject(item) {
            lines.append("\(prefix)@\(i)")
            encodeObjectEntries(item as! [String: Any], lines: &lines, depth: depth + 1)
        } else if isArray(item) {
            encodeArray(item as! [Any], name: String(i), lines: &lines, depth: depth + 1)
        } else {
            lines.append("\(prefix)@\(i) \(formatValue(item))")
        }
    }
}

private func encodeTabular(_ arr: [Any], name: String, lines: inout [String], depth: Int) {
    let prefix = indentStr(depth)
    let objects = arr.compactMap { $0 as? [String: Any] }
    guard let first = objects.first else { return }

    // Collect all keys from all items (preserving order: first's keys, then extras).
    var allKeys: [String] = []
    var seen = Set<String>()
    for obj in objects {
        for key in obj.keys.sorted() {
            if seen.insert(key).inserted {
                allKeys.append(key)
            }
        }
    }

    // Separate primitive from nested fields (sample from first element).
    var primitiveFields: [String] = []
    var nestedFields: [String] = []
    for key in allKeys {
        if let sample = first[key], (isObject(sample) || isArray(sample)) {
            nestedFields.append(key)
        } else {
            primitiveFields.append(key)
        }
    }

    // Header.
    let fieldList = primitiveFields.joined(separator: ",")
    lines.append("\(prefix)## \(name) [\(arr.count)]{\(fieldList)}")

    let hasNested = !nestedFields.isEmpty

    for (i, obj) in objects.enumerated() {
        let vals = primitiveFields.map { f -> String in
            guard let v = obj[f] else { return "-" }
            if v is NSNull { return "-" }
            return formatValue(v)
        }
        let rowStr = vals.joined(separator: "|")

        if hasNested {
            lines.append("\(prefix)@\(i) \(rowStr)")
            for nf in nestedFields {
                guard let nv = obj[nf] else { continue }
                if nv is NSNull { continue }
                if let subArr = nv as? [Any] {
                    encodeArray(subArr, name: nf, lines: &lines, depth: depth + 1)
                } else if let subObj = nv as? [String: Any] {
                    lines.append("\(indentStr(depth + 1)).\(nf)")
                    encodeObjectEntries(subObj, lines: &lines, depth: depth + 2)
                }
            }
        } else {
            lines.append("\(prefix)\(rowStr)")
        }
    }
}

private func encodeObjectEntries(_ map: [String: Any], lines: inout [String], depth: Int) {
    let prefix = indentStr(depth)

    for key in map.keys.sorted() {
        guard let value = map[key] else { continue }
        if value is NSNull { continue }
        if let arr = value as? [Any] {
            encodeArray(arr, name: key, lines: &lines, depth: depth)
        } else if let subObj = value as? [String: Any] {
            lines.append("\(indentStr(depth + 1))## \(key)")
            encodeObjectEntries(subObj, lines: &lines, depth: depth + 2)
        } else {
            lines.append("\(prefix)\(key)=\(formatValue(value))")
        }
    }
}
