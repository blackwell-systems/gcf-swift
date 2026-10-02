import Foundation

// This file implements the v3.6.0 tabular column optimizations for the generic
// profile: constant-column factoring (SPEC 7.4.7) and value-grouping (SPEC 7.4.8).
// Constant-column factoring is mandatory canonical and lives in the encoder
// (encodeTabular, Generic.swift); the decode side and the opt-in grouped encoder are
// here. The wire is byte-identical to the Go reference.

/// One parsed entry of a tabular field declaration. A plain field has only a name.
/// A constant column (SPEC 7.4.7) carries an unparsed value token after an unquoted
/// "=". A key column (SPEC 7.4.8.1, 10a.1) carries a leading "@".
struct FieldEntry {
    var name: String
    var isKey: Bool = false
    var isConst: Bool = false
    var constTok: String = ""
}

/// Returns the scalar offset just past the closing quote of a quoted string that
/// starts at the first scalar of `s`, or nil if unterminated. Operates on unicode
/// scalars (SPEC 2.4): structural quotes are code points.
private func quotedStringEndOffset(_ s: String) -> Int? {
    let scalars = Array(s.unicodeScalars)
    var escaped = false
    var i = 1
    while i < scalars.count {
        if escaped { escaped = false; i += 1; continue }
        if scalars[i] == "\\" { escaped = true; i += 1; continue }
        if scalars[i] == "\"" { return i + 1 }
        i += 1
    }
    return nil
}

/// Parses a field entry's name and optional "=value" tail. The name is a Section 2a
/// key (bare or quoted); the "=" that introduces a constant value is the first
/// unquoted "=" after the (possibly quoted) name. A nil value means the entry is a
/// plain field (no "="). Operates on unicode scalars.
private func splitNameValue(_ r: String) throws -> (name: String, value: String?) {
    if r.isEmpty {
        throw GCFError.malformedHeaderField("empty field entry")
    }
    let scalars = Array(r.unicodeScalars)
    if scalars[0] == "\"" {
        guard let end = quotedStringEndOffset(r) else {
            throw GCFError.unterminatedQuote
        }
        let quoted = String(String.UnicodeScalarView(scalars[0..<end]))
        let nm = try parseQuotedString(quoted)
        let after = Array(scalars[end...])
        if after.isEmpty { return (nm, nil) }
        if after[0] == "=" {
            return (nm, String(String.UnicodeScalarView(after[1...])))
        }
        throw GCFError.malformedHeaderField("unexpected characters after quoted field name")
    }
    if let idx = scalars.firstIndex(of: "=") {
        let nm = String(String.UnicodeScalarView(scalars[0..<idx]))
        if nm.isEmpty {
            throw GCFError.malformedHeaderField("empty field name")
        }
        if !isBareKey(nm) {
            throw GCFError.invalidFieldName(nm)
        }
        let v = String(String.UnicodeScalarView(scalars[(idx + 1)...]))
        return (nm, v)
    }
    if !isBareKey(r) {
        throw GCFError.invalidFieldName(r)
    }
    return (r, nil)
}

/// Parses a `{...}` field declaration supporting "@" key markers and "name=value"
/// constant columns. Commas, and the "=" boundary, are parsed respecting quoted
/// names and quoted values (SPEC 7.4.7.2, mirroring 2a.3).
func parseFieldEntries(_ declStr: String) throws -> [FieldEntry] {
    let scalars = Array(declStr.unicodeScalars)
    guard scalars.count >= 2, scalars.first == "{", scalars.last == "}" else {
        throw GCFError.invalidFieldDeclaration(declStr)
    }
    let inner = String(String.UnicodeScalarView(scalars[1..<(scalars.count - 1)]))
    if inner.isEmpty { return [] }
    let raw = splitRespectingQuotes(inner, delimiter: ",")
    var entries: [FieldEntry] = []
    for rawEntry in raw {
        var r = rawEntry.trimmingCharacters(in: .whitespaces)
        var e = FieldEntry(name: "")
        if scalarHasPrefix(r, "@") {
            e.isKey = true
            r = scalarDropFirst(r, 1)
        }
        let (nm, val) = try splitNameValue(r)
        e.name = nm
        if let val = val {
            e.isConst = true
            e.constTok = val
        }
        entries.append(e)
    }
    var seen = Set<String>()
    for e in entries {
        if seen.contains(e.name) {
            throw GCFError.duplicateFieldName(e.name)
        }
        seen.insert(e.name)
    }
    return entries
}

/// Parses a constant-column value token into a scalar (SPEC 7.4.7.2). The absent
/// marker and empty/attachment tokens are rejected.
func parseConstValue(_ tok: String) throws -> Any {
    if tok.isEmpty {
        throw GCFError.invalidConstValue("empty constant value (the empty string is always quoted)")
    }
    if tok == "~" {
        throw GCFError.invalidConstValue("absent marker ~ is not valid in a field declaration")
    }
    // Reject only a complete attachment marker, mirroring the encoder's Section 2.4
    // quoting predicate (bare "^", or "^{...}" ending in "}"). A "^{"-prefixed token
    // without a closing "}" (e.g. "^{abc") is not a marker; it is a literal string,
    // and the encoder leaves it bare, so the decoder must accept it as a scalar.
    if isCompleteAttachmentMarker(tok) {
        throw GCFError.invalidConstValue("attachment marker is not a scalar")
    }
    let parsed = try parseScalar(tok, tabularContext: false)
    switch parsed {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .missing: throw GCFError.invalidMissing
    case .attachment, .inlineAttachment: throw GCFError.invalidAttachment
    }
}

/// True only for a COMPLETE attachment marker: exactly "^", or "^{...}" with a
/// closing "}" (scalar length >= 3, starts "^{", ends "}"). A "^{"-prefixed token
/// without a closing "}" is a literal scalar, not a marker. Checked on unicode
/// scalars (SPEC 2.4).
func isCompleteAttachmentMarker(_ tok: String) -> Bool {
    if tok == "^" { return true }
    let scalars = tok.unicodeScalars
    return scalars.count >= 3 && scalarHasPrefix(tok, "^{") && scalarHasSuffix(tok, "}")
}

/// Formats a scalar as a constant-column header value (SPEC 7.4.7.2): the Section
/// 2.4 obligation plus quoting when the value contains "}" (the "," case is already
/// covered by needsQuote). Null is "-".
func formatConstValue(_ v: Any?) -> String {
    guard let v = v, !(v is NSNull) else { return "-" }
    if let s = v as? String {
        if needsQuote(s) || s.unicodeScalars.contains("}") {
            return quoteString(s)
        }
        return s
    }
    return formatScalar(v)
}

/// Returns the top-level group key of a flattened path column (SPEC 7.4.6) and true
/// when the name is a valid path (contains ">" with all segments non-empty),
/// mirroring parseTabularBody's path-column detection.
private func pathTopLevel(_ name: String) -> String? {
    if !name.unicodeScalars.contains(">") { return nil }
    let parts = scalarSplit(name, ">")
    for p in parts where p.isEmpty { return nil }
    return parts[0]
}

/// Parses a tabular array whose field declaration contains one or more constant
/// columns (SPEC 7.4.7). Parses the rows with the bare (per-record) fields only,
/// then rebuilds each record in declaration order, inserting each constant at its
/// position. Returns the records and the number of lines consumed including header.
func decodeConstantArray(_ lines: [String], headerLine: Int, depth: Int,
                         entries: [FieldEntry], count: Int) throws -> (Any, Int) {
    var bareFields: [String] = []
    var constVals: [String: Any] = [:]
    for e in entries {
        if e.isConst {
            constVals[e.name] = try parseConstValue(e.constTok)
            continue
        }
        bareFields.append(e.name)
    }
    if bareFields.isEmpty {
        throw GCFError.noBareColumn("every field is constant; a row must carry at least one per-record column")
    }
    let (rows, consumed) = try parseTabularBody(lines, start: headerLine + 1, depth: depth, fields: bareFields, expectedCount: count)
    if count >= 0 && rows.count != count {
        throw GCFError.countMismatch(count, rows.count)
    }

    // Plan the output-key order over all entries, mirroring parseTabularBody: a bare
    // path column (contains ">") collapses to its top-level key at the first
    // occurrence, a plain field keeps its name, and a constant contributes its name at
    // its position. A record from parseTabularBody is keyed by these collapsed bare
    // keys, so inserting the constants by this plan (and appending any flatten-fallback
    // extras) reconstructs each record in declaration order without losing nested or
    // attachment fields.
    struct OutKey { let name: String; let isConst: Bool }
    var plan: [OutKey] = []
    var inPlan = Set<String>()
    var seenGroup = Set<String>()
    for e in entries {
        if e.isConst {
            plan.append(OutKey(name: e.name, isConst: true))
            inPlan.insert(e.name)
            continue
        }
        if let top = pathTopLevel(e.name) {
            if !seenGroup.contains(top) {
                seenGroup.insert(top)
                plan.append(OutKey(name: top, isConst: false))
                inPlan.insert(top)
            }
            continue
        }
        plan.append(OutKey(name: e.name, isConst: false))
        inPlan.insert(e.name)
    }

    var out: [Any] = []
    out.reserveCapacity(rows.count)
    for r in rows {
        let rm = r as? OrderedDictionary
        let nm = OrderedDictionary()
        for k in plan {
            if k.isConst {
                nm[k.name] = constVals[k.name] ?? NSNull()
                continue
            }
            if let rm = rm, let v = rm[k.name] {
                nm[k.name] = v
            }
        }
        // Append any keys the record carries that were not in the plan (flatten-
        // fallback attachments, SPEC 7.4.6.1.4), in the record's own order.
        if let rm = rm {
            for (k, v) in rm.orderedPairs where !inPlan.contains(k) {
                nm[k] = v
            }
        }
        out.append(nm)
    }
    return (out, consumed + 1)
}

/// Parses a value-grouped tabular array (SPEC 7.4.8). groupClause is the trimmed
/// text after the field declaration's "}" (beginning with "group=").
func decodeGroupedArray(_ lines: [String], headerLine: Int, depth: Int,
                        entries: [FieldEntry], groupClause: String, count: Int) throws -> (Any, Int) {
    if !scalarHasPrefix(groupClause, "group=") {
        throw GCFError.invalidGroupHeader("malformed group clause")
    }
    let groupColTok = scalarDropFirst(groupClause, 6).trimmingCharacters(in: .whitespaces)
    let groupCol: String
    do {
        groupCol = try parseHeaderKey(groupColTok)
    } catch {
        throw GCFError.invalidGroupHeader("\(error)")
    }

    var keyCount = 0
    var keyName = ""
    for e in entries where e.isKey {
        keyCount += 1
        keyName = e.name
    }
    if keyCount != 1 {
        throw GCFError.invalidGroupHeader("a grouped section requires exactly one @ key column")
    }

    // Validate the grouping column: present, not the key, not a constant column.
    guard let groupEntry = entries.first(where: { $0.name == groupCol }) else {
        throw GCFError.invalidGroupHeader("group column \"\(groupCol)\" is not a declared field")
    }
    if groupEntry.isKey {
        throw GCFError.invalidGroupHeader("group column \"\(groupCol)\" is the key column")
    }
    if groupEntry.isConst {
        throw GCFError.invalidGroupHeader("group column \"\(groupCol)\" is a constant column")
    }

    // Per-record (bare) fields are the non-constant fields other than the grouping
    // column; the key column is included.
    var bareFields: [String] = []
    var constVals: [String: Any] = [:]
    for e in entries {
        if e.isConst {
            constVals[e.name] = try parseConstValue(e.constTok)
            continue
        }
        if e.name == groupCol { continue }
        bareFields.append(e.name)
    }

    let indent = String(repeating: "  ", count: depth)
    var records: [Any] = []
    var seenGroups = Set<String>()
    var seenKeys = Set<String>()
    var total = 0
    var i = headerLine + 1
    while i < lines.count {
        var content = lines[i]
        if depth > 0 {
            if !scalarHasPrefix(content, indent) { break }
            content = scalarDropFirst(content, indent.unicodeScalars.count)
        }
        if scalarHasPrefix(content, "## ") || scalarHasPrefix(content, "##!") { break }

        // Subheader: {col}={value} [{count}]
        let (col, groupVal, gcount) = try parseGroupSubheader(content)
        if col != groupCol {
            throw GCFError.invalidGroupHeader("subheader column \"\(col)\" does not match group column \"\(groupCol)\"")
        }
        let gkey = formatScalar(groupVal)
        if seenGroups.contains(gkey) {
            throw GCFError.duplicateGroup(gkey)
        }
        seenGroups.insert(gkey)
        i += 1

        for _ in 0..<gcount {
            if i >= lines.count {
                throw GCFError.countMismatch(gcount, 0)
            }
            var rowContent = lines[i]
            if depth > 0 {
                if !scalarHasPrefix(rowContent, indent) {
                    throw GCFError.countMismatch(gcount, 0)
                }
                rowContent = scalarDropFirst(rowContent, indent.unicodeScalars.count)
            }
            if scalarHasPrefix(rowContent, "## ") || scalarHasPrefix(rowContent, "##!") {
                throw GCFError.countMismatch(gcount, 0)
            }
            let cells = splitRespectingQuotes(rowContent, delimiter: "|")
            if cells.count != bareFields.count {
                throw GCFError.rowWidthMismatch(bareFields.count, cells.count)
            }
            var bareVals: [String: Any] = [:]
            for (j, f) in bareFields.enumerated() {
                let cell = cells[j]
                // Only a COMPLETE attachment marker (bare "^" or "^{...}" ending in
                // "}") is forbidden here; a "^{"-prefixed cell without a closing "}" is
                // a literal scalar (SPEC 7.4 row cell), not an attachment.
                if isCompleteAttachmentMarker(cell) {
                    throw GCFError.invalidGroupHeader("grouped records must not carry attachments")
                }
                let pv = try parseScalar(cell, tabularContext: true)
                if case .missing = pv { continue }
                bareVals[f] = try scalarResultToAny(pv)
            }
            let nm = OrderedDictionary()
            for e in entries {
                if e.name == groupCol {
                    nm[e.name] = groupVal
                } else if e.isConst {
                    nm[e.name] = constVals[e.name] ?? NSNull()
                } else if let v = bareVals[e.name] {
                    nm[e.name] = v
                }
            }
            guard let kv = nm[keyName] else {
                throw GCFError.invalidGroupHeader("record missing key column \"\(keyName)\"")
            }
            let ks = formatScalar(kv)
            if seenKeys.contains(ks) {
                throw GCFError.duplicateKey(ks)
            }
            seenKeys.insert(ks)
            records.append(nm)
            i += 1
        }
        total += gcount
    }

    if count >= 0 && total != count {
        throw GCFError.countMismatch(count, total)
    }
    return (records, i - headerLine)
}

/// Converts a parsed scalar result into a host value, matching the generic decoder.
private func scalarResultToAny(_ sv: ScalarResult) throws -> Any {
    switch sv {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .missing: throw GCFError.invalidMissing
    case .attachment, .inlineAttachment: throw GCFError.invalidAttachment
    }
}

/// Parses a Section 2a key (bare or quoted) that occupies the whole of `s`.
func parseHeaderKey(_ s: String) throws -> String {
    if s.isEmpty { throw GCFError.invalidFieldName("empty key") }
    if s.unicodeScalars.first == "\"" {
        guard let end = quotedStringEndOffset(s), end == s.unicodeScalars.count else {
            throw GCFError.invalidFieldName("malformed quoted key: \(s)")
        }
        return try parseQuotedString(s)
    }
    if !isBareKey(s) {
        throw GCFError.invalidFieldName(s)
    }
    return s
}

/// Parses a line of the form `{col}={value} [{count}]` (SPEC 7.4.8.3). The value
/// runs from the first unquoted "=" to the final " [" that begins the count.
func parseGroupSubheader(_ content: String) throws -> (col: String, value: Any, count: Int) {
    guard scalarHasSuffix(content, "]") else {
        throw GCFError.invalidGroupHeader("subheader missing count bracket")
    }
    guard let cntOpen = scalarLastIndexOf(content, " [") else {
        throw GCFError.invalidGroupHeader("subheader missing count bracket")
    }
    let scalars = Array(content.unicodeScalars)
    // countStr is between "[" (cntOpen+2 scalars) and the final "]".
    let countStr = String(String.UnicodeScalarView(scalars[(cntOpen + 2)..<(scalars.count - 1)]))
    let n: Int
    do {
        n = try parseCountValueForGroup(countStr)
    } catch {
        throw GCFError.invalidCount(countStr)
    }
    if n == 0 {
        throw GCFError.invalidCount("a group names at least one record")
    }
    let colEqVal = String(String.UnicodeScalarView(scalars[0..<cntOpen]))
    guard let eq = indexUnquotedEqOffset(colEqVal) else {
        throw GCFError.invalidGroupHeader("subheader missing '='")
    }
    let cevScalars = Array(colEqVal.unicodeScalars)
    let colName: String
    do {
        colName = try parseHeaderKey(String(String.UnicodeScalarView(cevScalars[0..<eq])))
    } catch {
        throw GCFError.invalidGroupHeader("\(error)")
    }
    let valTok = String(String.UnicodeScalarView(cevScalars[(eq + 1)...]))
    let v = try parseConstValue(valTok)
    return (colName, v, n)
}

/// Group-subheader count parse (SPEC 13.5): mirrors the Go parseCount (rejects a
/// leading zero, accepts "0").
private func parseCountValueForGroup(_ s: String) throws -> Int {
    if s == "0" { return 0 }
    let scalars = Array(s.unicodeScalars)
    guard !scalars.isEmpty, scalars[0] != "0" else { throw GCFError.invalidCount(s) }
    var n = 0
    for c in scalars {
        guard c >= "0" && c <= "9" else { throw GCFError.invalidCount(s) }
        n = n * 10 + Int(c.value - 0x30)
    }
    return n
}

/// Returns the scalar offset of the last occurrence of the two-scalar needle
/// " [" in `s`, or nil.
private func scalarLastIndexOf(_ s: String, _ needle: String) -> Int? {
    let sv = Array(s.unicodeScalars)
    let nv = Array(needle.unicodeScalars)
    if nv.isEmpty || sv.count < nv.count { return nil }
    var start = sv.count - nv.count
    while start >= 0 {
        var match = true
        for k in 0..<nv.count where sv[start + k] != nv[k] { match = false; break }
        if match { return start }
        start -= 1
    }
    return nil
}

/// Returns the scalar offset of the first "=" outside a quoted string, or nil.
private func indexUnquotedEqOffset(_ s: String) -> Int? {
    var inQuote = false
    var escaped = false
    var idx = 0
    for c in s.unicodeScalars {
        if escaped { escaped = false; idx += 1; continue }
        if c == "\\" && inQuote { escaped = true; idx += 1; continue }
        if c == "\"" { inQuote.toggle(); idx += 1; continue }
        if c == "=" && !inQuote { return idx }
        idx += 1
    }
    return nil
}

// MARK: - Opt-in grouped encoder (SPEC 7.4.8)

/// Encodes an array of uniform records as a value-grouped keyed set (SPEC 7.4.8):
/// opt-in, never the canonical default. `keyField` is the unique identity column
/// (emitted @-marked); `groupField` is the low-cardinality column the records are
/// clustered by. Other constant columns are factored (SPEC 7.4.7). Throws when the
/// array is not a keyed set the grammar can represent: a missing key/group field, a
/// non-unique key, key == group, or any record needing an attachment (nested value),
/// which grouped rows do not carry in this version. The wire is byte-identical to the
/// Go EncodeGenericGrouped.
public func encodeGenericGrouped(_ data: Any?, keyField: String, groupField: String) throws -> String {
    guard let arr = data as? [Any] else {
        throw GCFError.invalidFieldDeclaration("value-grouping requires a JSON array")
    }
    if arr.isEmpty {
        throw GCFError.invalidFieldDeclaration("value-grouping requires a non-empty array")
    }
    if keyField == groupField {
        throw GCFError.invalidFieldDeclaration("value-grouping: key field and group field must differ")
    }
    for item in arr {
        if asOrderedDict(item) == nil {
            throw GCFError.invalidFieldDeclaration("value-grouping requires an array of objects")
        }
    }
    guard let fields = groupedTabularFields(arr) else {
        throw GCFError.invalidFieldDeclaration("value-grouping requires an array of objects with fields")
    }
    if !fields.contains(keyField) {
        throw GCFError.invalidFieldDeclaration("value-grouping: key field \"\(keyField)\" not present in the records")
    }
    if !fields.contains(groupField) {
        throw GCFError.invalidFieldDeclaration("value-grouping: group field \"\(groupField)\" not present in the records")
    }

    var keySeen = Set<String>()
    for item in arr {
        let pairs = asOrderedDict(item)!
        let dict = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        for f in fields {
            guard let val = dict[f] else { continue }
            if asOrderedDict(val) != nil || val is [Any] {
                throw GCFError.invalidFieldDeclaration("value-grouping does not support nested values in this version: field \"\(f)\"")
            }
        }
        guard let kv = dict[keyField], !(kv is NSNull) else {
            throw GCFError.invalidFieldDeclaration("value-grouping: key field \"\(keyField)\" missing in a record")
        }
        let ks = formatScalar(kv)
        if keySeen.contains(ks) {
            throw GCFError.invalidFieldDeclaration("value-grouping: key field \"\(keyField)\" is not unique (\(ks))")
        }
        keySeen.insert(ks)
    }

    // Constant columns (excluding key and group), factored per SPEC 7.4.7.
    var constVal: [String: String] = [:]
    if arr.count >= 2 {
        for f in fields {
            if f == keyField || f == groupField { continue }
            var first = ""
            var firstSet = false
            var isc = true
            for item in arr {
                let dict = Dictionary(asOrderedDict(item)!, uniquingKeysWith: { a, _ in a })
                guard let val = dict[f] else { isc = false; break }
                let cv = formatConstValue(val)
                if !firstSet {
                    first = cv
                    firstSet = true
                } else if cv != first {
                    isc = false
                    break
                }
            }
            if isc { constVal[f] = first }
        }
    }

    var headerFields: [String] = []
    for f in fields {
        if f == keyField {
            headerFields.append("@" + formatKey(f))
        } else if f == groupField {
            headerFields.append(formatKey(f))
        } else if let cv = constVal[f] {
            headerFields.append(formatKey(f) + "=" + cv)
        } else {
            headerFields.append(formatKey(f))
        }
    }

    var bareFields: [String] = []
    for f in fields {
        if f == groupField { continue }
        if constVal[f] != nil { continue }
        bareFields.append(f)
    }

    var groupOrder: [String] = []
    var groupMembers: [String: [Any]] = [:]
    var groupValRaw: [String: Any] = [:]
    for item in arr {
        let dict = Dictionary(asOrderedDict(item)!, uniquingKeysWith: { a, _ in a })
        let gv = dict[groupField] ?? NSNull()
        let gk = formatScalar(gv)
        if groupMembers[gk] == nil {
            groupOrder.append(gk)
            groupValRaw[gk] = gv
        }
        groupMembers[gk, default: []].append(item)
    }

    var out = "GCF profile=generic\n"
    out += "## [\(arr.count)]{\(headerFields.joined(separator: ","))} group=\(formatKey(groupField))\n"
    for gk in groupOrder {
        let members = groupMembers[gk]!
        let gvStr = formatScalar(groupValRaw[gk] ?? NSNull())
        out += "\(formatKey(groupField))=\(gvStr) [\(members.count)]\n"
        for item in members {
            let dict = Dictionary(asOrderedDict(item)!, uniquingKeysWith: { a, _ in a })
            var cells: [String] = []
            cells.reserveCapacity(bareFields.count)
            for f in bareFields {
                if let val = dict[f] {
                    if val is NSNull { cells.append("-") }
                    else { cells.append(formatScalar(val, delimiter: "|")) }
                } else {
                    cells.append("~")
                }
            }
            out += cells.joined(separator: "|") + "\n"
        }
    }
    return out
}

/// The ordered field union across an array of objects (SPEC 7.4.3), first-encounter
/// order. Mirrors the encoder's tabularFields but is accessible to the grouped encoder.
private func groupedTabularFields(_ arr: [Any]) -> [String]? {
    if arr.isEmpty { return nil }
    var order: [String] = []
    var seen = Set<String>()
    for item in arr {
        guard let pairs = asOrderedDict(item) else { return nil }
        for (k, _) in pairs where !seen.contains(k) {
            seen.insert(k)
            order.append(k)
        }
    }
    return order.isEmpty ? nil : order
}
