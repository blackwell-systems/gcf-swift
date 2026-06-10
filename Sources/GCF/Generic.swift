import Foundation

/// Encode any value into GCF v2.0 generic profile.
///
/// Accepts Dictionary, NSDictionary (preserves key order), Array, String, Int, Double, Bool, and nil.
public func encodeGeneric(_ data: Any?) -> String {
    var out = "GCF profile=generic\n"
    encodeRootValue(data, out: &out)
    return out
}

private func encodeRootValue(_ v: Any?, out: inout String) {
    guard let v = v else {
        out += "=-\n"
        return
    }
    if let dict = asOrderedDict(v) {
        encodeObject(dict, out: &out, depth: 0)
    } else if let arr = v as? [Any] {
        encodeRootArray(arr, out: &out)
    } else if v is NSNull {
        out += "=-\n"
    } else {
        out += "="
        out += formatScalar(v)
        out += "\n"
    }
}

/// Extract ordered key-value pairs from a dictionary.
/// NSDictionary preserves insertion order from JSONSerialization.
/// Swift [String: Any] uses sorted keys as fallback.
func asOrderedDict(_ v: Any) -> [(String, Any)]? {
    if let nsDict = v as? NSDictionary {
        return nsDict.allKeys.compactMap { key -> (String, Any)? in
            guard let k = key as? String, let val = nsDict[key] else { return nil }
            return (k, val)
        }
    }
    if let dict = v as? [String: Any] {
        return dict.keys.sorted().map { ($0, dict[$0]!) }
    }
    return nil
}

private func encodeObject(_ pairs: [(String, Any)], out: inout String, depth: Int) {
    let prefix = indentStr(depth)
    for (key, value) in pairs {
        let fk = formatKey(key)
        if let nested = asOrderedDict(value) {
            out += "\(prefix)## \(fk)\n"
            encodeObject(nested, out: &out, depth: depth + 1)
        } else if let arr = value as? [Any] {
            encodeNamedArray(fk, arr: arr, out: &out, depth: depth)
        } else if value is NSNull {
            out += "\(prefix)\(fk)=-\n"
        } else {
            out += "\(prefix)\(fk)=\(formatScalar(value))\n"
        }
    }
}

private func encodeRootArray(_ arr: [Any], out: inout String) {
    if arr.isEmpty { out += "## [0]\n"; return }
    if allPrimitives(arr) {
        let vals = arr.map { formatScalar($0, delimiter: ",") }
        out += "## [\(arr.count)]: \(vals.joined(separator: ","))\n"
        return
    }
    if let fields = tabularFields(arr) {
        encodeTabular("## ", arr: arr, fields: fields, out: &out, depth: 0)
        return
    }
    encodeExpanded("## ", arr: arr, out: &out, depth: 0)
}

private func encodeNamedArray(_ name: String, arr: [Any], out: inout String, depth: Int) {
    let prefix = indentStr(depth)
    if arr.isEmpty { out += "\(prefix)## \(name) [0]\n"; return }
    if allPrimitives(arr) {
        let vals = arr.map { formatScalar($0, delimiter: ",") }
        out += "\(prefix)\(name)[\(arr.count)]: \(vals.joined(separator: ","))\n"
        return
    }
    if let fields = tabularFields(arr) {
        encodeTabular("\(prefix)## \(name) ", arr: arr, fields: fields, out: &out, depth: depth)
        return
    }
    encodeExpanded("\(prefix)## \(name) ", arr: arr, out: &out, depth: depth)
}

private func tabularFields(_ arr: [Any]) -> [String]? {
    if arr.isEmpty { return nil }
    var fieldOrder: [String] = []
    var seen = Set<String>()
    for item in arr {
        guard let pairs = asOrderedDict(item) else { return nil }
        for (k, _) in pairs {
            if !seen.contains(k) {
                fieldOrder.append(k)
                seen.insert(k)
            }
        }
    }
    return fieldOrder.isEmpty ? nil : fieldOrder
}

private func encodeTabular(_ headerPrefix: String, arr: [Any], fields: [String], out: inout String, depth: Int) {
    let prefix = indentStr(depth)
    let fmtFields = fields.map { formatKey($0) }
    out += "\(headerPrefix)[\(arr.count)]{\(fmtFields.joined(separator: ","))}\n"

    for (i, item) in arr.enumerated() {
        guard let pairs = asOrderedDict(item) else { continue }
        let dict = Dictionary(uniqueKeysWithValues: pairs)

        var cells: [String] = []
        var attachments: [(String, Any)] = []
        var rowHasAttachment = false

        for f in fields {
            guard let v = dict[f] else { cells.append("~"); continue }
            if v is NSNull { cells.append("-"); continue }
            if asOrderedDict(v) != nil || v is [Any] {
                cells.append("^")
                attachments.append((f, v))
                rowHasAttachment = true
            } else {
                cells.append(formatScalar(v, delimiter: "|"))
            }
        }

        let row = cells.joined(separator: "|")
        if rowHasAttachment {
            out += "\(prefix)@\(i) \(row)\n"
        } else {
            out += "\(prefix)\(row)\n"
        }

        for (attName, attVal) in attachments {
            let attPrefix = prefix + "  "
            let fk = formatKey(attName)
            if let nested = asOrderedDict(attVal) {
                out += "\(attPrefix).\(fk) {}\n"
                encodeObject(nested, out: &out, depth: depth + 2)
            } else if let subArr = attVal as? [Any] {
                encodeAttachmentArray(attPrefix, fk: fk, arr: subArr, out: &out, depth: depth + 2)
            }
        }
    }
}

private func encodeAttachmentArray(_ attPrefix: String, fk: String, arr: [Any], out: inout String, depth: Int) {
    if arr.isEmpty {
        out += "\(attPrefix).\(fk) [0]\n"
    } else if allPrimitives(arr) {
        let vals = arr.map { formatScalar($0, delimiter: ",") }
        out += "\(attPrefix).\(fk) [\(arr.count)]: \(vals.joined(separator: ","))\n"
    } else if let fields = tabularFields(arr) {
        encodeTabular("\(attPrefix).\(fk) ", arr: arr, fields: fields, out: &out, depth: depth)
    } else {
        encodeExpanded("\(attPrefix).\(fk) ", arr: arr, out: &out, depth: depth)
    }
}

private func encodeExpanded(_ headerPrefix: String, arr: [Any], out: inout String, depth: Int) {
    let prefix = indentStr(depth)
    out += "\(headerPrefix)[\(arr.count)]\n"
    for (i, item) in arr.enumerated() {
        if let nested = asOrderedDict(item) {
            out += "\(prefix)@\(i) {}\n"
            encodeObject(nested, out: &out, depth: depth + 1)
        } else if let subArr = item as? [Any] {
            encodeExpandedArrayItem(prefix, idx: i, arr: subArr, out: &out, depth: depth)
        } else if item is NSNull {
            out += "\(prefix)@\(i) =-\n"
        } else {
            out += "\(prefix)@\(i) =\(formatScalar(item))\n"
        }
    }
}

private func encodeExpandedArrayItem(_ prefix: String, idx: Int, arr: [Any], out: inout String, depth: Int) {
    if arr.isEmpty {
        out += "\(prefix)@\(idx) [0]\n"
    } else if allPrimitives(arr) {
        let vals = arr.map { formatScalar($0, delimiter: ",") }
        out += "\(prefix)@\(idx) [\(arr.count)]: \(vals.joined(separator: ","))\n"
    } else if let fields = tabularFields(arr) {
        encodeTabular("\(prefix)@\(idx) ", arr: arr, fields: fields, out: &out, depth: depth + 1)
    } else {
        encodeExpanded("\(prefix)@\(idx) ", arr: arr, out: &out, depth: depth + 1)
    }
}

private func allPrimitives(_ arr: [Any]) -> Bool {
    return arr.allSatisfy { !($0 is [String: Any]) && !($0 is NSDictionary) && !($0 is [Any]) }
}

private func indentStr(_ depth: Int) -> String {
    return String(repeating: "  ", count: depth)
}
