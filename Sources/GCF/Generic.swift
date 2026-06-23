import Foundation

/// Options for controlling generic encoding behavior.
public struct GenericOptions {
    /// When true, disables promotion of fixed-shape nested objects to path
    /// columns (e.g. "customer>name"). Nested objects use attachment syntax
    /// instead. Set when targeting open-weight models that show lower
    /// comprehension on flattened encoding.
    public var noFlatten: Bool

    public init(noFlatten: Bool = false) {
        self.noFlatten = noFlatten
    }
}

/// Encode any value into GCF generic profile.
///
/// Accepts Dictionary, NSDictionary (preserves key order), Array, String, Int, Double, Bool, and nil.
public func encodeGeneric(_ data: Any?, opts: GenericOptions = GenericOptions()) -> String {
    var out = "GCF profile=generic\n"
    encodeRootValue(data, out: &out, opts: opts)
    return out
}

private func encodeRootValue(_ v: Any?, out: inout String, opts: GenericOptions) {
    guard let v = v else {
        out += "=-\n"
        return
    }
    if let dict = asOrderedDict(v) {
        encodeObject(dict, out: &out, depth: 0, opts: opts)
    } else if let arr = v as? [Any] {
        encodeRootArray(arr, out: &out, opts: opts)
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

private func encodeObject(_ pairs: [(String, Any)], out: inout String, depth: Int, opts: GenericOptions) {
    let prefix = indentStr(depth)
    for (key, value) in pairs {
        let fk = formatKey(key)
        if let nested = asOrderedDict(value) {
            out += "\(prefix)## \(fk)\n"
            encodeObject(nested, out: &out, depth: depth + 1, opts: opts)
        } else if let arr = value as? [Any] {
            encodeNamedArray(fk, arr: arr, out: &out, depth: depth, opts: opts)
        } else if value is NSNull {
            out += "\(prefix)\(fk)=-\n"
        } else {
            out += "\(prefix)\(fk)=\(formatScalar(value))\n"
        }
    }
}

private func encodeRootArray(_ arr: [Any], out: inout String, opts: GenericOptions) {
    if arr.isEmpty { out += "## [0]\n"; return }
    if allPrimitives(arr) {
        let vals = arr.map { formatScalar($0, delimiter: ",") }
        out += "## [\(arr.count)]: \(vals.joined(separator: ","))\n"
        return
    }
    if let fields = tabularFields(arr) {
        encodeTabular("## ", arr: arr, fields: fields, out: &out, depth: 0, opts: opts)
        return
    }
    encodeExpanded("## ", arr: arr, out: &out, depth: 0, opts: opts)
}

private func encodeNamedArray(_ name: String, arr: [Any], out: inout String, depth: Int, opts: GenericOptions) {
    let prefix = indentStr(depth)
    if arr.isEmpty { out += "\(prefix)## \(name) [0]\n"; return }
    if allPrimitives(arr) {
        let vals = arr.map { formatScalar($0, delimiter: ",") }
        out += "\(prefix)\(name)[\(arr.count)]: \(vals.joined(separator: ","))\n"
        return
    }
    if let fields = tabularFields(arr) {
        encodeTabular("\(prefix)## \(name) ", arr: arr, fields: fields, out: &out, depth: depth, opts: opts)
        return
    }
    encodeExpanded("\(prefix)## \(name) ", arr: arr, out: &out, depth: depth, opts: opts)
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

// MARK: - Nested object flattening (v3.2)

private struct FlatLeaf {
    let path: String
    let keys: [String]
}

private func analyzeFlattenable(_ arr: [Any], fieldName: String, parentPath: String) -> [FlatLeaf]? {
    // Field names containing ">" cannot be flattened (would create ambiguous paths).
    if fieldName.contains(">") { return nil }
    var canonicalShape: [String: String]? = nil // key -> "scalar" | "nested"
    var canonicalKeys: [String]? = nil

    for item in arr {
        guard let pairs = asOrderedDict(item) else { return nil }
        let dict = Dictionary(uniqueKeysWithValues: pairs)
        guard let v = dict[fieldName] else { continue }
        if v is NSNull { continue }
        guard let obj = asOrderedDict(v) else { return nil }
        if v is [Any] { return nil }

        let keys = obj.map { $0.0 }

        if canonicalShape == nil {
            var shape: [String: String] = [:]
            for (k, val) in obj {
                if k.contains(">") { return nil }
                if val is [Any] { return nil }
                if asOrderedDict(val) != nil {
                    shape[k] = "nested"
                } else {
                    shape[k] = "scalar"
                }
            }
            canonicalShape = shape
            canonicalKeys = keys
        } else {
            if keys != canonicalKeys! { return nil }
            for (k, val) in obj {
                guard let expected = canonicalShape![k] else { return nil }
                if expected == "scalar" {
                    if asOrderedDict(val) != nil || val is [Any] { return nil }
                } else if expected == "nested" {
                    if val is [Any] { return nil }
                    if !(val is NSNull) && asOrderedDict(val) == nil {
                        return nil
                    }
                }
            }
        }
    }

    guard let shape = canonicalShape, let ck = canonicalKeys else { return nil }

    let currentPath = parentPath.isEmpty ? fieldName : "\(parentPath)>\(fieldName)"
    let parentKeys = parentPath.isEmpty ? [fieldName] : parentPath.split(separator: ">").map(String.init) + [fieldName]

    var leaves: [FlatLeaf] = []
    for k in ck {
        if shape[k] == "scalar" {
            leaves.append(FlatLeaf(path: "\(currentPath)>\(k)", keys: parentKeys + [k]))
        } else {
            let subArr: [Any] = arr.map { item -> Any in
                guard let pairs = asOrderedDict(item) else { return [String: Any]() }
                let dict = Dictionary(uniqueKeysWithValues: pairs)
                guard let v = dict[fieldName], !(v is NSNull) else { return [String: Any]() }
                return v
            }
            guard let subLeaves = analyzeFlattenable(subArr, fieldName: k, parentPath: currentPath), !subLeaves.isEmpty else { return nil }
            leaves.append(contentsOf: subLeaves)
        }
    }

    // Guard: reject if any row has non-null object with all-null leaves.
    if !leaves.isEmpty {
        for item in arr {
            guard let pairs = asOrderedDict(item) else { continue }
            let dict = Dictionary(uniqueKeysWithValues: pairs)
            guard let v = dict[fieldName], !(v is NSNull) else { continue }
            let allNull = leaves.allSatisfy { leaf in
                let (val, exists) = resolveKeyChain(item, keys: leaf.keys)
                return exists && (val is NSNull || val == nil)
            }
            if allNull { return nil }
        }
    }

    return leaves
}

private func resolveKeyChain(_ item: Any, keys: [String]) -> (Any?, Bool) {
    guard !keys.isEmpty else { return (nil, false) }
    guard let pairs = asOrderedDict(item) else { return (nil, false) }
    let dict = Dictionary(uniqueKeysWithValues: pairs)
    guard let first = dict[keys[0]] else { return (nil, false) }
    if first is NSNull { return (nil, true) }
    var current: Any = first
    for k in keys.dropFirst() {
        guard let pairs2 = asOrderedDict(current) else { return (nil, false) }
        let d = Dictionary(uniqueKeysWithValues: pairs2)
        guard let next = d[k] else { return (nil, false) }
        current = next
    }
    return (current, true)
}

private func encodeTabular(_ headerPrefix: String, arr: [Any], fields: [String], out: inout String, depth: Int, opts: GenericOptions) {
    let prefix = indentStr(depth)

    // Phase 0: Analyze fields for flattening.
    var flattenMap: [String: [FlatLeaf]] = [:]
    if !opts.noFlatten {
        for f in fields {
            if let leaves = analyzeFlattenable(arr, fieldName: f, parentPath: ""), !leaves.isEmpty {
                flattenMap[f] = leaves
            }
        }
    }

    // Fields whose names contain ">" must not appear as tabular columns
    // because the decoder would interpret them as flattened path columns.
    let gtFields = Set(fields.filter { flattenMap[$0] == nil && $0.contains(">") })

    // Build expanded column list.
    struct Col { let header: String; let type: String; let field: String; let keys: [String] }
    var columns: [Col] = []
    for f in fields {
        if gtFields.contains(f) { continue }
        if let leaves = flattenMap[f] {
            for leaf in leaves {
                columns.append(Col(header: formatKey(leaf.path), type: "flat", field: f, keys: leaf.keys))
            }
        } else {
            columns.append(Col(header: formatKey(f), type: "original", field: f, keys: []))
        }
    }

    // If all fields were excluded (all contain ">"), fall back to expanded.
    if columns.isEmpty {
        encodeExpanded(headerPrefix, arr: arr, out: &out, depth: depth, opts: opts)
        return
    }

    // Pre-compute inline schemas and shared array schemas (skip flattened).
    var inlineSchemas: [String: [String]] = [:]
    var sharedArrSchemas: [String: [String]] = [:]
    for f in fields {
        if flattenMap[f] != nil { continue }
        if let ifs = inlineSchemaFields(arr, fieldName: f) { inlineSchemas[f] = ifs }
        if let sas = sharedArraySchema(arr, fieldName: f) { sharedArrSchemas[f] = sas }
    }

    let headerFields = columns.map { $0.header }
    out += "\(headerPrefix)[\(arr.count)]{\(headerFields.joined(separator: ","))}\n"

    for (i, item) in arr.enumerated() {
        guard let pairs = asOrderedDict(item) else { continue }
        let dict = Dictionary(uniqueKeysWithValues: pairs)

        var cells: [String] = []
        struct Att { let name: String; let value: Any; let inline: Bool; let inlineFields: [String]? }
        var attachments: [Att] = []
        var rowHasAttachment = false

        for col in columns {
            if col.type == "flat" {
                guard dict[col.keys[0]] != nil else { cells.append("~"); continue }
                let topVal = dict[col.keys[0]]!
                if topVal is NSNull {
                    cells.append("-")
                } else {
                    let (val, exists) = resolveKeyChain(item, keys: col.keys)
                    if !exists { cells.append("~") }
                    else if val is NSNull || val == nil { cells.append("-") }
                    else { cells.append(formatScalar(val!, delimiter: "|")) }
                }
                continue
            }

            let f = col.field
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

        // Emit fields with ">" in their names as per-row attachments.
        for f in fields {
            guard gtFields.contains(f) else { continue }
            guard let v = dict[f] else { continue }
            rowHasAttachment = true
            attachments.append(Att(name: f, value: v, inline: false, inlineFields: nil))
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
                encodeObject(nested, out: &out, depth: depth + 2, opts: opts)
            } else if let subArr = att.value as? [Any] {
                if let sas = sharedArrSchemas[att.name], i > 0 {
                    encodeAttachmentArrayShared(prefix, fk: fk, arr: subArr, out: &out, depth: depth + 2, sharedFields: sas, opts: opts)
                } else {
                    encodeAttachmentArray(prefix, fk: fk, arr: subArr, out: &out, depth: depth + 2, opts: opts)
                }
            } else {
                // Scalar attachment (e.g. field names containing ">").
                if att.value is NSNull {
                    out += "\(prefix).\(fk) =-\n"
                } else {
                    out += "\(prefix).\(fk) =\(formatScalar(att.value))\n"
                }
            }
        }
    }
}

private func encodeAttachmentArrayShared(_ attPrefix: String, fk: String, arr: [Any], out: inout String, depth: Int, sharedFields: [String], opts: GenericOptions) {
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
    encodeAttachmentArray(attPrefix, fk: fk, arr: arr, out: &out, depth: depth, opts: opts)
}

private func encodeAttachmentArray(_ attPrefix: String, fk: String, arr: [Any], out: inout String, depth: Int, opts: GenericOptions = GenericOptions()) {
    if arr.isEmpty {
        out += "\(attPrefix).\(fk) [0]\n"
    } else if allPrimitives(arr) {
        let vals = arr.map { formatScalar($0, delimiter: ",") }
        out += "\(attPrefix).\(fk) [\(arr.count)]: \(vals.joined(separator: ","))\n"
    } else if let fields = tabularFields(arr) {
        encodeTabular("\(attPrefix).\(fk) ", arr: arr, fields: fields, out: &out, depth: depth, opts: opts)
    } else {
        encodeExpanded("\(attPrefix).\(fk) ", arr: arr, out: &out, depth: depth, opts: opts)
    }
}

private func encodeExpanded(_ headerPrefix: String, arr: [Any], out: inout String, depth: Int, opts: GenericOptions = GenericOptions()) {
    let prefix = indentStr(depth)
    out += "\(headerPrefix)[\(arr.count)]\n"
    for (i, item) in arr.enumerated() {
        if let nested = asOrderedDict(item) {
            out += "\(prefix)@\(i) {}\n"
            encodeObject(nested, out: &out, depth: depth + 1, opts: opts)
        } else if let subArr = item as? [Any] {
            encodeExpandedArrayItem(prefix, idx: i, arr: subArr, out: &out, depth: depth, opts: opts)
        } else if item is NSNull {
            out += "\(prefix)@\(i) =-\n"
        } else {
            out += "\(prefix)@\(i) =\(formatScalar(item))\n"
        }
    }
}

private func encodeExpandedArrayItem(_ prefix: String, idx: Int, arr: [Any], out: inout String, depth: Int, opts: GenericOptions = GenericOptions()) {
    if arr.isEmpty {
        out += "\(prefix)@\(idx) [0]\n"
    } else if allPrimitives(arr) {
        let vals = arr.map { formatScalar($0, delimiter: ",") }
        out += "\(prefix)@\(idx) [\(arr.count)]: \(vals.joined(separator: ","))\n"
    } else if let fields = tabularFields(arr) {
        encodeTabular("\(prefix)@\(idx) ", arr: arr, fields: fields, out: &out, depth: depth + 1, opts: opts)
    } else {
        encodeExpanded("\(prefix)@\(idx) ", arr: arr, out: &out, depth: depth + 1, opts: opts)
    }
}

private func allPrimitives(_ arr: [Any]) -> Bool {
    return arr.allSatisfy { !($0 is [String: Any]) && !($0 is NSDictionary) && !($0 is OrderedDictionary) && !($0 is [Any]) }
}

private func indentStr(_ depth: Int) -> String {
    return String(repeating: "  ", count: depth)
}
