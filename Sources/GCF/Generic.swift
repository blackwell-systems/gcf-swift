import Foundation

/// Encode any value into GCF generic profile.
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
/// OrderedDictionary preserves insertion order.
/// NSDictionary uses sorted keys (allKeys order is not reliable).
/// Swift [String: Any] uses sorted keys as fallback.
func asOrderedDict(_ v: Any) -> [(String, Any)]? {
    if let od = v as? OrderedDictionary {
        return od.orderedPairs
    }
    if let nsDict = v as? NSDictionary {
        let keys = nsDict.allKeys.compactMap { $0 as? String }.sorted()
        return keys.compactMap { key -> (String, Any)? in
            guard let val = nsDict[key] else { return nil }
            return (key, val)
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

private func inlineSchemaFields(_ arr: [Any], fieldName: String) -> [String]? {
    guard !arr.isEmpty else { return nil }
    guard let firstPairs = asOrderedDict(arr[0]) else { return nil }
    let firstDict = Dictionary(uniqueKeysWithValues: firstPairs)
    guard let firstVal = firstDict[fieldName], !(firstVal is NSNull) else { return nil }
    guard let firstObj = asOrderedDict(firstVal) else { return nil }

    var canonicalKeys: [String]? = nil
    for item in arr {
        guard let pairs = asOrderedDict(item) else { return nil }
        let dict = Dictionary(uniqueKeysWithValues: pairs)
        guard let v = dict[fieldName] else { continue }
        if v is NSNull { continue }
        guard let obj = asOrderedDict(v) else { return nil }
        let keys = obj.map { $0.0 }
        for (_, val) in obj {
            if asOrderedDict(val) != nil || val is [Any] { return nil }
        }
        if canonicalKeys == nil {
            canonicalKeys = keys
        } else if keys != canonicalKeys! {
            return nil
        }
    }
    guard let ck = canonicalKeys, ck.count >= 3 else { return nil }
    return ck
}

private func sharedArraySchema(_ arr: [Any], fieldName: String) -> [String]? {
    guard !arr.isEmpty else { return nil }
    guard let firstPairs = asOrderedDict(arr[0]) else { return nil }
    let firstDict = Dictionary(uniqueKeysWithValues: firstPairs)
    guard let firstVal = firstDict[fieldName], firstVal is [Any] else { return nil }

    var canonicalFields: [String]? = nil
    for item in arr {
        guard let pairs = asOrderedDict(item) else { return nil }
        let dict = Dictionary(uniqueKeysWithValues: pairs)
        guard let v = dict[fieldName] else { continue }
        if v is NSNull { continue }
        guard let subArr = v as? [Any] else { return nil }
        guard let fields = tabularFields(subArr) else { return nil }
        // All values must be scalars.
        for subItem in subArr {
            guard let subPairs = asOrderedDict(subItem) else { return nil }
            for (_, val) in subPairs {
                if asOrderedDict(val) != nil || val is [Any] { return nil }
            }
        }
        if canonicalFields == nil {
            canonicalFields = fields
        } else if fields != canonicalFields! {
            return nil
        }
    }
    return canonicalFields
}

private func encodeTabular(_ headerPrefix: String, arr: [Any], fields: [String], out: inout String, depth: Int) {
    let prefix = indentStr(depth)

    // Pre-compute inline schemas and shared array schemas.
    var inlineSchemas: [String: [String]] = [:]
    var sharedArrSchemas: [String: [String]] = [:]
    for f in fields {
        if let ifs = inlineSchemaFields(arr, fieldName: f) { inlineSchemas[f] = ifs }
        if let sas = sharedArraySchema(arr, fieldName: f) { sharedArrSchemas[f] = sas }
    }

    let fmtFields = fields.map { formatKey($0) }
    out += "\(headerPrefix)[\(arr.count)]{\(fmtFields.joined(separator: ","))}\n"

    for (i, item) in arr.enumerated() {
        guard let pairs = asOrderedDict(item) else { continue }
        let dict = Dictionary(uniqueKeysWithValues: pairs)

        var cells: [String] = []
        struct Att { let name: String; let value: Any; let inline: Bool; let inlineFields: [String]? }
        var attachments: [Att] = []
        var rowHasAttachment = false

        for f in fields {
            guard let v = dict[f] else { cells.append("~"); continue }
            if v is NSNull { cells.append("-"); continue }
            if asOrderedDict(v) != nil || v is [Any] {
                if let ifs = inlineSchemas[f], asOrderedDict(v) != nil {
                    if i == 0 {
                        let fmtIF = ifs.map { formatKey($0) }
                        cells.append("^{\(fmtIF.joined(separator: ","))}")
                    } else {
                        cells.append("^")
                    }
                    attachments.append(Att(name: f, value: v, inline: true, inlineFields: ifs))
                } else {
                    cells.append("^")
                    attachments.append(Att(name: f, value: v, inline: false, inlineFields: nil))
                }
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

        for att in attachments {
            let fk = formatKey(att.name)
            if att.inline, let ifs = att.inlineFields, let obj = asOrderedDict(att.value) {
                let objDict = Dictionary(uniqueKeysWithValues: obj)
                let vals = ifs.map { inf -> String in
                    guard let val = objDict[inf] else { return "~" }
                    return formatScalar(val, delimiter: "|")
                }
                out += "\(prefix)\(vals.joined(separator: "|"))\n"
            } else if let nested = asOrderedDict(att.value) {
                out += "\(prefix).\(fk) {}\n"
                encodeObject(nested, out: &out, depth: depth + 2)
            } else if let subArr = att.value as? [Any] {
                if let sas = sharedArrSchemas[att.name], i > 0 {
                    encodeAttachmentArrayShared(prefix, fk: fk, arr: subArr, out: &out, depth: depth + 2, sharedFields: sas)
                } else {
                    encodeAttachmentArray(prefix, fk: fk, arr: subArr, out: &out, depth: depth + 2)
                }
            }
        }
    }
}

private func encodeAttachmentArrayShared(_ attPrefix: String, fk: String, arr: [Any], out: inout String, depth: Int, sharedFields: [String]) {
    if arr.isEmpty { out += "\(attPrefix).\(fk) [0]\n"; return }
    if allPrimitives(arr) {
        let vals = arr.map { formatScalar($0, delimiter: ",") }
        out += "\(attPrefix).\(fk) [\(arr.count)]: \(vals.joined(separator: ","))\n"
        return
    }
    if let fields = tabularFields(arr), fields == sharedFields {
        let p = indentStr(depth)
        out += "\(attPrefix).\(fk) [\(arr.count)]\n"
        for item in arr {
            guard let pairs = asOrderedDict(item) else { continue }
            let dict = Dictionary(uniqueKeysWithValues: pairs)
            let cells = sharedFields.map { f -> String in
                guard let v = dict[f] else { return "~" }
                if v is NSNull { return "-" }
                return formatScalar(v, delimiter: "|")
            }
            out += "\(p)\(cells.joined(separator: "|"))\n"
        }
        return
    }
    encodeAttachmentArray(attPrefix, fk: fk, arr: arr, out: &out, depth: depth)
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
    return arr.allSatisfy { !($0 is [String: Any]) && !($0 is NSDictionary) && !($0 is OrderedDictionary) && !($0 is [Any]) }
}

private func indentStr(_ depth: Int) -> String {
    return String(repeating: "  ", count: depth)
}
