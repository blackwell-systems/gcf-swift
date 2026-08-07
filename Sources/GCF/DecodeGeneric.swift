import Foundation

// Scalar-based delimiter helpers (scalarHasPrefix, scalarFirstIndex,
// scalarDropFirst, firstScalar, scalarSplit, scalarContains, ...) live in
// ScalarDelimiters.swift and are shared with the graph and delta decoders.

/// Decode GCF generic or graph profile text into a value tree.
public func decodeGeneric(_ input: String) throws -> Any {
    let trimmed = input.trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
    if trimmed.isEmpty { throw GCFError.missingHeader }

    let lines = trimmed.components(separatedBy: "\n")
    let header = lines[0].trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    guard header.hasPrefix("GCF ") else { throw GCFError.missingHeader }

    let profile = try parseHeaderProfile(header)

    if profile == "graph" {
        let p = try decode(input)
        return payloadToDict(p)
    }
    if profile != "generic" { throw GCFError.unknownProfile(profile) }

    // Filter body.
    var contentLines: [String] = []
    var summaryLine = ""
    var deferredCount = 0
    for line in lines.dropFirst() {
        let l = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if l.isEmpty { continue }
        for c in l.unicodeScalars {
            if c == "\t" { throw GCFError.tabIndentation }
            if c != " " { break }
        }
        let trimmedLine = l.trimmingCharacters(in: .whitespaces)
        if scalarHasPrefix(trimmedLine, "# ") { continue }
        if scalarHasPrefix(trimmedLine, "##! ") { summaryLine = trimmedLine; continue }
        if scalarHasPrefix(trimmedLine, "## ") && (scalarContains(trimmedLine, "[?]") || scalarContains(trimmedLine, "[?:]")) { deferredCount += 1 }
        contentLines.append(l)
    }

    if !summaryLine.isEmpty && deferredCount > 0 {
        try validateSummaryCounts(summaryLine, deferredCount: deferredCount, contentLines: contentLines)
    }

    if contentLines.isEmpty { return OrderedDictionary() }

    let first = contentLines[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))

    // Root scalar. Detect '=' on unicode scalars (a value beginning with a
    // grapheme-extending scalar would cluster with the leading '=' Character).
    if first.unicodeScalars.first == "=" {
        if contentLines.count > 1 { throw GCFError.trailingCharacters }
        let afterEq = first.unicodeScalars.index(after: first.unicodeScalars.startIndex)
        return try scalarToAny(parseScalar(String(first.unicodeScalars[afterEq...])))
    }

    // Root array.
    if scalarHasPrefix(first, "## [") {
        let (arr, consumed) = try parseArrayFromHeader(contentLines, headerLine: 0, depth: 0,
                                                  bracketPart: scalarDropFirst(first, 3))
        // A root array or keyed map spans the whole document, so any structural line
        // past the consumed rows is a surplus item, not sibling content. The row loop
        // stops at the declared count, so the count assert only catches the deficit
        // case; surplus is caught here (SPEC Section 13: a mismatch, fewer OR more
        // items than declared, is an error).
        if consumed < contentLines.count {
            throw GCFError.countMismatch(consumed - 1, contentLines.count - 1)
        }
        return arr
    }

    // Root object.
    var result = OrderedDictionary()
    _ = try parseObjectBody(contentLines, start: 0, depth: 0, out: &result)
    return result
}

private func parseHeaderProfile(_ header: String) throws -> String {
    let parts = header.split(separator: " ")
    guard parts.count >= 2 else { throw GCFError.missingProfile }
    var seen = Set<String>()
    var profile = ""
    for p in parts.dropFirst() {
        let s = String(p)
        guard let eq = s.firstIndex(of: "=") else { throw GCFError.malformedHeaderField(s) }
        let key = String(s[s.startIndex..<eq])
        if seen.contains(key) { throw GCFError.duplicateHeaderField(key) }
        seen.insert(key)
        if key == "profile" { profile = String(s[s.index(after: eq)...]) }
    }
    if profile.isEmpty { throw GCFError.missingProfile }
    return profile
}

private func scalarToAny(_ sv: ScalarResult) throws -> Any {
    switch sv {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .missing: throw GCFError.invalidMissing
    case .attachment: throw GCFError.invalidAttachment
    case .inlineAttachment: throw GCFError.invalidAttachment
    }
}

private func parseObjectBody(_ lines: [String], start: Int, depth: Int,
                              out: inout OrderedDictionary) throws -> Int {
    let ind = String(repeating: "  ", count: depth)
    var i = start
    while i < lines.count {
        let line = lines[i]
        if depth > 0 && !scalarHasPrefix(line, ind) { break }
        let content = depth > 0 ? scalarDropFirst(line, ind.unicodeScalars.count) : line
        if !content.isEmpty && firstScalar(content) == " " {
            throw GCFError.invalidIndent
        }

        // Array section.
        if scalarHasPrefix(content, "## ") {
            let hdr = scalarDropFirst(content, 3)
            // Locate the named-array count bracket outside any quoted name, so a
            // quoted section/key name containing " [" (e.g. `## "a [1] b"`) is not
            // misread as a named-array header (mirrors findClosingBrace).
            if let bi = findHeaderBracketStart(hdr) {
                let name = try parseKeyFromHeader(String(hdr[hdr.startIndex..<bi]))
                try checkDup(out, key: name)
                let (arr, consumed) = try parseArrayFromHeader(lines, headerLine: i, depth: depth,
                                                                bracketPart: String(hdr[bi...]))
                out[name] = arr
                i += consumed
                continue
            }
            let name = try parseKeyFromHeader(hdr)
            try checkDup(out, key: name)
            i += 1
            var nested = OrderedDictionary()
            let consumed = try parseObjectBody(lines, start: i, depth: depth + 1, out: &nested)
            out[name] = nested
            i += consumed
            continue
        }

        // Key=value. Check before inline array so bracket patterns in quoted
        // values (e.g. text="ERR[404]: Not Found") are not misinterpreted.
        if let eqIdx = findKVSplit(content), eqIdx > content.startIndex {
            let name = try parseKeyFromHeader(String(content[content.startIndex..<eqIdx]))
            try checkDup(out, key: name)
            let afterEq = content.unicodeScalars.index(after: eqIdx)
            let val = try scalarToAny(parseScalar(String(content[afterEq...])))
            out[name] = val
            i += 1
            continue
        }

        // Inline array (e.g. items[3]: a,b,c). Only reached if no = found.
        if !scalarHasPrefix(content, "@") && !scalarHasPrefix(content, "##") {
            if let bracketIdx = scalarFirstIndex(content, "["), bracketIdx > content.unicodeScalars.startIndex {
                let rest = String(content.unicodeScalars[bracketIdx...])
                if let closeIdx = scalarFirstIndex(rest, "]") {
                    let after = String(rest.unicodeScalars[rest.unicodeScalars.index(after: closeIdx)...])
                    if scalarHasPrefix(after, ": ") || after == ":" {
                        let name = try parseKeyFromHeader(String(content.unicodeScalars[content.unicodeScalars.startIndex..<bracketIdx]))
                        try checkDup(out, key: name)
                        let (arr, _) = try parseArrayFromHeader(lines, headerLine: i, depth: depth, bracketPart: rest)
                        out[name] = arr
                        i += 1
                        continue
                    }
                }
            }
        }

        // An object-body line that is not a `## ` section, a `key=value` field, or
        // an inline array is not valid content and MUST NOT be silently skipped
        // (that dropped data — a lossless round-trip hole). A pipe-delimited line is
        // a stray positional inline body with no eligible `^` cell (SPEC 16.5,
        // orphan_inline_attachment); any other unrecognized line is likewise rejected.
        if content.unicodeScalars.contains("|") {
            throw GCFError.orphanInlineAttachment(content)
        }
        throw GCFError.invalidLine(content)
    }
    return i - start
}

private func findKVSplit(_ s: String) -> String.Index? {
    if s.isEmpty { return nil }
    let scalars = s.unicodeScalars
    if scalars.first == "\"" {
        var i = scalars.index(after: scalars.startIndex)
        while i < scalars.endIndex {
            if scalars[i] == "\\" { i = scalars.index(i, offsetBy: 2, limitedBy: scalars.endIndex) ?? scalars.endIndex; continue }
            if scalars[i] == "\"" {
                let next = scalars.index(after: i)
                if next < scalars.endIndex && scalars[next] == "=" { return next }
                return nil
            }
            i = scalars.index(after: i)
        }
        return nil
    }
    // Find first '=' but only before any '[' (to avoid matching = inside inline array values).
    var bracketSeen = false
    for i in scalars.indices {
        if scalars[i] == "[" { bracketSeen = true }
        if scalars[i] == "=" { return bracketSeen ? nil : i }
    }
    return nil
}

private func parseKeyFromHeader(_ s: String) throws -> String {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.count >= 2 && trimmed.unicodeScalars.first == "\"" {
        return try parseQuotedString(trimmed)
    }
    return trimmed
}

private func checkDup(_ dict: OrderedDictionary, key: String) throws {
    if dict[key] != nil { throw GCFError.duplicateKey(key) }
}

private func parseArrayFromHeader(_ lines: [String], headerLine: Int, depth: Int,
                                   bracketPart: String) throws -> (Any, Int) {
    let bp = bracketPart.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    guard scalarHasPrefix(bp, "[") else { throw GCFError.invalidCount(bp) }
    let bpv = bp.unicodeScalars
    guard let closeIdx = scalarFirstIndex(bp, "]") else { throw GCFError.invalidCount(bp) }
    var countStr = String(bpv[bpv.index(after: bpv.startIndex)..<closeIdx])
    let after = String(bpv[bpv.index(after: closeIdx)...])

    // Keyed map marker: `[N:]` (the `:` after the count reconstructs a JSON object,
    // not an array; SPEC 7.2a.2). A keyed header MUST be followed by a field
    // declaration.
    let keyed = scalarHasSuffix(countStr, ":")
    if keyed {
        countStr = String(countStr.unicodeScalars.dropLast())
        guard scalarHasPrefix(after, "{") else {
            throw GCFError.invalidFieldDeclaration("keyed_map: missing field declaration")
        }
    }

    let count: Int = countStr == "?" ? -1 : try parseCountValue(countStr)

    // A keyed map has at least one member; an empty object is encoded per
    // Section 7.7, never as [0:] (SPEC 7.2a.4).
    if keyed && count == 0 {
        throw GCFError.invalidCount("keyed_map: zero count [0:] is invalid (an empty object uses Section 7.7)")
    }

    if count == 0 && !scalarHasPrefix(after, "{") && !scalarHasPrefix(after, ":") {
        return ([] as [Any], 1)
    }

    // Inline.
    if scalarHasPrefix(after, ": ") || after == ":" {
        let valsStr = scalarHasPrefix(after, ": ") ? scalarDropFirst(after, 2) : ""
        if valsStr.isEmpty {
            if count >= 0 && count != 0 { throw GCFError.countMismatch(count, 0) }
            return ([] as [Any], 1)
        }
        let vals = splitRespectingQuotes(valsStr, delimiter: ",")
        if count >= 0 && vals.count != count { throw GCFError.countMismatch(count, vals.count) }
        let parsed = try vals.map { try scalarToAny(parseScalar($0.trimmingCharacters(in: .whitespaces))) }
        return (parsed, 1)
    }

    // Tabular.
    if scalarHasPrefix(after, "{") {
        guard let braceEnd = findClosingBrace(after) else { throw GCFError.invalidFieldDeclaration(after) }
        let braceIdx = after.unicodeScalars.index(after.unicodeScalars.startIndex, offsetBy: braceEnd)
        let declStr = String(after.unicodeScalars[after.unicodeScalars.startIndex...braceIdx])
        let fields = try splitFieldDecl(declStr)
        // A keyed header MUST declare at least two fields: the key column plus at
        // least one value field (SPEC 7.2a.2).
        if keyed && fields.count < 2 {
            throw GCFError.invalidFieldDeclaration("keyed_map: header must declare at least two fields")
        }
        let (rows, consumed) = try parseTabularBody(lines, start: headerLine + 1, depth: depth, fields: fields, expectedCount: count)
        if count >= 0 && rows.count != count { throw GCFError.countMismatch(count, rows.count) }
        if keyed {
            let m = try keyedRowsToMap(rows, fields: fields)
            return (m, consumed + 1)
        }
        return (rows, consumed + 1)
    }

    // Expanded.
    let (items, consumed) = try parseExpandedBody(lines, start: headerLine + 1, depth: depth)
    if count >= 0 && items.count != count { throw GCFError.countMismatch(count, items.count) }
    return (items, consumed + 1)
}

private func parseAttachmentName(_ rest: String) -> (String, String) {
    if rest.unicodeScalars.first == "\"" {
        // Iterate over unicode scalars to avoid grapheme clustering merging
        // non-ASCII characters with adjacent delimiters like ".
        let scalars = Array(rest.unicodeScalars)
        var j = 1
        while j < scalars.count {
            if scalars[j] == "\\" { j += 2; continue }
            if scalars[j] == "\"" {
                // Build the quoted portion and remainder from scalar offsets.
                let quoted = String(String.UnicodeScalarView(scalars[0...j]))
                let remainder = String(String.UnicodeScalarView(scalars[(j+1)...]))
                if let name = try? parseQuotedString(quoted) {
                    return (name, remainder)
                }
                break
            }
            j += 1
        }
        return ("", rest)
    }
    if let sp = scalarFirstIndex(rest, " ") {
        let rv = rest.unicodeScalars
        return (String(rv[rv.startIndex..<sp]), String(rv[sp...]))
    }
    return (rest, "")
}

private func parseAttachment(_ lines: [String], lineIdx: Int, rest: String, depth: Int,
                               sharedSchemas: inout [String: [String]]) throws -> (String, Any, Int, [String]?) {
    let (name, afterNameRaw) = parseAttachmentName(rest)
    if name.isEmpty && !scalarHasPrefix(rest, "\"\"") { throw GCFError.invalidFieldDeclaration("invalid attachment: \(rest)") }
    let afterName = afterNameRaw.trimmingCharacters(in: CharacterSet(charactersIn: " "))

    if scalarHasPrefix(afterName, "{}") {
        var nested = OrderedDictionary()
        let consumed = try parseObjectBody(lines, start: lineIdx + 1, depth: depth, out: &nested)
        return (name, nested, consumed + 1, nil)
    }
    if scalarHasPrefix(afterName, "[") {
        let anv = afterName.unicodeScalars
        guard let cb = scalarFirstIndex(afterName, "]") else { throw GCFError.invalidFieldDeclaration("missing ]") }
        let afterClose = String(anv[anv.index(after: cb)...])

        if scalarHasPrefix(afterClose, "{") {
            var parsedFields: [String]? = nil
            if let eb = findClosingBraceSwift(afterClose) {
                let acv = afterClose.unicodeScalars
                parsedFields = try? splitFieldDecl(String(acv[acv.startIndex...acv.index(acv.startIndex, offsetBy: eb)]))
            }
            let (arr, consumed) = try parseArrayFromHeader(lines, headerLine: lineIdx, depth: depth, bracketPart: afterName)
            return (name, arr, consumed, parsedFields)
        }

        // Inline primitive array.
        if scalarHasPrefix(afterClose, ": ") || afterClose == ":" {
            let (arr, consumed) = try parseArrayFromHeader(lines, headerLine: lineIdx, depth: depth, bracketPart: afterName)
            return (name, arr, consumed, nil)
        }

        // Shared schema.
        if let sf = sharedSchemas[name] {
            let countStr = String(anv[anv.index(after: anv.startIndex)..<cb])
            let count = countStr == "?" ? -1 : (Int(countStr) ?? -1)
            if count == 0 { return (name, [Any](), 1, nil) }
            var useShared = true
            let ind = String(repeating: "  ", count: depth)
            let nextIdx = lineIdx + 1
            if nextIdx < lines.count {
                var nc = lines[nextIdx]
                if depth > 0 && scalarHasPrefix(nc, ind) { nc = scalarDropFirst(nc, ind.unicodeScalars.count) }
                if scalarHasPrefix(nc.trimmingCharacters(in: CharacterSet(charactersIn: " ")), "@") { useShared = false }
            }
            if useShared {
                let (rows, consumed) = try parseTabularBody(lines, start: lineIdx + 1, depth: depth, fields: sf, expectedCount: count)
                if count >= 0 && rows.count != count { throw GCFError.countMismatch(count, rows.count) }
                return (name, rows, consumed + 1, nil)
            }
        }

        let (arr, consumed) = try parseArrayFromHeader(lines, headerLine: lineIdx, depth: depth, bracketPart: afterName)
        return (name, arr, consumed, nil)
    }
    // Scalar: =value (field names containing ">" excluded from tabular columns).
    if afterName.unicodeScalars.first == "=" {
        // Detect the '=' delimiter on unicode scalars, not Characters: a value that
        // begins with a grapheme-extending scalar (for example U+0BD7) would cluster
        // with the leading '=' into a single Character, so hasPrefix("=") and
        // dropFirst() would misread the value (SPEC 2.4 scalars are code points).
        let valStr = String(afterName.unicodeScalars.dropFirst())
        let parsed = try parseScalar(valStr, tabularContext: true)
        if case .missing = parsed { return (name, NSNull(), 1, nil) }
        return (name, try scalarToAny(parsed), 1, nil)
    }
    throw GCFError.invalidFieldDeclaration("invalid attachment form: \(afterName)")
}

/// Returns the String.Index of the space before the named-array count bracket
/// (" [") that lies OUTSIDE any quoted name, tracking quote state and escapes.
/// Returns nil when no such bracket exists (mirrors findClosingBrace).
private func findHeaderBracketStart(_ s: String) -> String.Index? {
    var inQuote = false
    var escaped = false
    let sv = s.unicodeScalars
    var i = sv.startIndex
    while i < sv.endIndex {
        let c = sv[i]
        if escaped { escaped = false; i = sv.index(after: i); continue }
        if c == "\\" && inQuote { escaped = true; i = sv.index(after: i); continue }
        if c == "\"" { inQuote = !inQuote; i = sv.index(after: i); continue }
        if !inQuote && c == " " {
            let next = sv.index(after: i)
            if next < sv.endIndex && sv[next] == "[" { return i }
        }
        i = sv.index(after: i)
    }
    return nil
}

/// Returns the unicode scalar offset of the closing `}`.
private func findClosingBraceSwift(_ s: String) -> Int? {
    var inQuote = false; var escaped = false; var idx = 0
    for c in s.unicodeScalars {
        if escaped { escaped = false; idx += 1; continue }
        if c == "\\" && inQuote { escaped = true; idx += 1; continue }
        if c == "\"" { inQuote = !inQuote; idx += 1; continue }
        if c == "}" && !inQuote { return idx }
        idx += 1
    }
    return nil
}

private func parseTabularBody(_ lines: [String], start: Int, depth: Int,
                               fields: [String], expectedCount: Int) throws -> ([Any], Int) {
    let ind = String(repeating: "  ", count: depth)
    var rows: [Any] = []
    var i = start
    var inlineSchemas: [String: [String]] = [:]
    var sharedArraySchemas: [String: [String]] = [:]

    // Detect path columns: fields containing ">".
    var pathColumnMap: [String: [String]] = [:]
    for f in fields {
        if f.unicodeScalars.contains(">") {
            let parts = scalarSplit(f, ">")
            // Only treat as a path column if all segments are non-empty.
            if parts.allSatisfy({ !$0.isEmpty }) {
                pathColumnMap[f] = parts
            }
        }
    }

    while i < lines.count {
        let line = lines[i]
        let content: String
        if depth > 0 {
            guard scalarHasPrefix(line, ind) else { break }
            content = scalarDropFirst(line, ind.unicodeScalars.count)
        } else {
            content = line
        }
        if scalarHasPrefix(content, "## ") || scalarHasPrefix(content, "##!") { break }
        if !content.isEmpty && firstScalar(content) == " " {
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if scalarHasPrefix(trimmed, ".") { break }
            break
        }

        var rowData = content
        var rowHasID = false
        if scalarHasPrefix(rowData, "@") {
            let rv = rowData.unicodeScalars
            if let sp = scalarFirstIndex(rowData, " ") {
                let idStr = String(rv[rv.index(after: rv.startIndex)..<sp])
                if !idStr.isEmpty && idStr.unicodeScalars.allSatisfy({ $0.isASCII && ($0.value >= 0x30 && $0.value <= 0x39) }) {
                    rowData = String(rv[rv.index(after: sp)...])
                    rowHasID = true
                }
            }
        }

        let vals = splitRespectingQuotes(rowData, delimiter: "|")
        if vals.count != fields.count { throw GCFError.rowWidthMismatch(fields.count, vals.count) }

        let cellValues = OrderedDictionary()
        var traditionalAttFields: [String] = []
        var inlineAttFields: [String] = []
        var inlineAttOrder: [String] = []
        var missingFields = Set<String>()

        // Collect path column values for unflattening.
        var flatValues: [String: Any] = [:]
        var flatAbsent = Set<String>()

        for (j, f) in fields.enumerated() {
            let cellVal = vals[j]

            // Path columns: store values for later unflattening.
            if pathColumnMap[f] != nil {
                let parsed = try parseScalar(cellVal, tabularContext: true)
                switch parsed {
                case .missing: flatAbsent.insert(f)
                default: flatValues[f] = try scalarToAny(parsed)
                }
                continue
            }

            if scalarHasPrefix(cellVal, "^{") && scalarHasSuffix(cellVal, "}") {
                let schemaStr = scalarDropFirst(cellVal, 1)
                let ifs = try splitFieldDecl(schemaStr)
                inlineSchemas[f] = ifs
                inlineAttFields.append(f)
                inlineAttOrder.append(f)
                continue
            }
            let parsed = try parseScalar(cellVal, tabularContext: true)
            switch parsed {
            case .missing: missingFields.insert(f)
            case .attachment:
                if inlineSchemas[f] != nil { inlineAttFields.append(f); inlineAttOrder.append(f) }
                else { traditionalAttFields.append(f) }
            case .inlineAttachment(let schema):
                let ifs = try splitFieldDecl(schema)
                inlineSchemas[f] = ifs
                inlineAttFields.append(f)
                inlineAttOrder.append(f)
            default: cellValues[f] = try scalarToAny(parsed)
            }
        }
        i += 1

        let allAttFields = traditionalAttFields + inlineAttFields
        let expectedAtt = Set(allAttFields)
        let attachmentValues = OrderedDictionary()

        if rowHasID {
            var inlineIdx = 0

            while i < lines.count {
                let aLine = lines[i]
                let aContent: String?
                if depth == 0 || scalarHasPrefix(aLine, ind) {
                    aContent = depth > 0 ? scalarDropFirst(aLine, ind.unicodeScalars.count) : aLine
                } else {
                    break
                }
                guard var ac = aContent else { break }

                // Handle v2 indented attachments: strip one extra indent level.
                if !scalarHasPrefix(ac, ".") && scalarHasPrefix(ac, "  .") {
                    ac = scalarDropFirst(ac, 2)
                }

                if scalarHasPrefix(ac, ".") {
                    let rest = scalarDropFirst(ac, 1)
                    let (attName, afterNameR) = parseAttachmentName(rest)

                    // Reject orphan attachments: a .fieldname that does not bind to a
                    // ^-marked column of this row, unless it is a ">" flatten-fallback
                    // attachment (SPEC 7.4.6.1.4).
                    if !expectedAtt.contains(attName) && !attName.unicodeScalars.contains(">") {
                        throw GCFError.orphanAttachment(attName)
                    }

                    // Check for duplicate attachment.
                    if attachmentValues[attName] != nil {
                        throw GCFError.duplicateAttachment(attName)
                    }
                    let afterNameS = afterNameR.trimmingCharacters(in: CharacterSet(charactersIn: " "))

                    if let ifs = inlineSchemas[attName], !scalarHasPrefix(afterNameS, "{}"), !scalarHasPrefix(afterNameS, "[") {
                        let inlineVals = splitRespectingQuotes(afterNameS, delimiter: "|")
                        if inlineVals.count != ifs.count { throw GCFError.rowWidthMismatch(ifs.count, inlineVals.count) }
                        let obj = OrderedDictionary()
                        for (k, inf) in ifs.enumerated() {
                            let p = try parseScalar(inlineVals[k], tabularContext: true)
                            if case .missing = p { continue }
                            obj[inf] = try scalarToAny(p)
                        }
                        attachmentValues[attName] = obj
                        i += 1; continue
                    }

                    let (attNameT, attVal, consumed, parsedFields) = try parseAttachment(lines, lineIdx: i, rest: rest, depth: depth + 2, sharedSchemas: &sharedArraySchemas)
                    if rows.isEmpty, let pf = parsedFields { sharedArraySchemas[attNameT] = pf }
                    attachmentValues[attNameT] = attVal
                    i += consumed; continue
                }

                // No-prefix: positional inline data.
                var foundInline = false
                var nextInlineField = ""
                while inlineIdx < inlineAttOrder.count {
                    let candidate = inlineAttOrder[inlineIdx]
                    if attachmentValues[candidate] == nil { nextInlineField = candidate; foundInline = true; break }
                    inlineIdx += 1
                }
                if !foundInline { break }

                let ifs = inlineSchemas[nextInlineField]!
                let inlineVals = splitRespectingQuotes(ac, delimiter: "|")
                if inlineVals.count != ifs.count { throw GCFError.rowWidthMismatch(ifs.count, inlineVals.count) }
                let obj = OrderedDictionary()
                for (k, inf) in ifs.enumerated() {
                    let p = try parseScalar(inlineVals[k], tabularContext: true)
                    if case .missing = p { continue }
                    obj[inf] = try scalarToAny(p)
                }
                attachmentValues[nextInlineField] = obj
                inlineIdx += 1; i += 1
            }

            for f in allAttFields {
                if attachmentValues[f] == nil { throw GCFError.missingAttachment(f) }
            }

            // Check for extra attachment lines after all fields resolved (duplicate).
            if i < lines.count {
                let extraLine = lines[i]
                var extraContent = ""
                if depth == 0 || scalarHasPrefix(extraLine, ind) {
                    extraContent = depth > 0 ? scalarDropFirst(extraLine, ind.unicodeScalars.count) : extraLine
                }
                // Handle v2 indented format.
                if !scalarHasPrefix(extraContent, ".") && scalarHasPrefix(extraContent, "  .") {
                    extraContent = scalarDropFirst(extraContent, 2)
                }
                if scalarHasPrefix(extraContent, ".") {
                    let (extraName, _) = parseAttachmentName(scalarDropFirst(extraContent, 1))
                    if attachmentValues[extraName] != nil {
                        throw GCFError.duplicateAttachment(extraName)
                    }
                }
            }
        }

        // Reconstruct the row in declared field-union order. A flattened group is
        // emitted at the position of its first path column, so the nested object
        // reappears where the original field was, not appended at the end (SPEC
        // 7.4.6.1 step 7 and the key-order preservation requirement, SPEC 52, 931).
        let nested = pathColumnMap.isEmpty
            ? OrderedDictionary()
            : unflattenPaths(pathColumnMap, orderedFields: fields, flatValues: flatValues, flatAbsent: flatAbsent)
        var emittedGroups = Set<String>()
        let row = OrderedDictionary()
        for f in fields {
            if let paths = pathColumnMap[f] {
                let top = paths[0]
                if emittedGroups.contains(top) { continue }
                emittedGroups.insert(top)
                if let v = nested[top] { row[top] = v }  // omitted when the whole group is absent
                continue
            }
            if missingFields.contains(f) { continue }
            if let v = cellValues[f] { row[f] = v; continue }
            if let v = attachmentValues[f] { row[f] = v; continue }
        }
        // Also add any orphan attachment values (fields excluded from column list, e.g. ">" fields).
        for (k, v) in attachmentValues.orderedPairs {
            if row[k] == nil { row[k] = v }
        }

        rows.append(row)

        if expectedCount >= 0 && rows.count >= expectedCount { break }
    }
    return (rows, i - start)
}

private func unflattenPaths(_ pathColumns: [String: [String]],
                            orderedFields: [String],
                            flatValues: [String: Any],
                            flatAbsent: Set<String>) -> OrderedDictionary {
    // Group by top-level parent, walking fields in declared path-column order so
    // both the group order and the nested leaf order follow the header (SPEC 905:
    // flattened columns reconstruct in nested key order). Iterating the unordered
    // pathColumns map instead would sort leaves nondeterministically.
    var groups: [String: [String]] = [:]
    var groupOrder: [String] = []
    for fieldName in orderedFields {
        guard let paths = pathColumns[fieldName], !paths.isEmpty else { continue }
        let top = paths[0]
        if groups[top] == nil {
            groups[top] = []
            groupOrder.append(top)
        }
        groups[top]!.append(fieldName)
    }

    let result = OrderedDictionary()

    for top in groupOrder {
        let fieldNames = groups[top]!
        let allAbsent = fieldNames.allSatisfy { flatAbsent.contains($0) }
        let allNull = fieldNames.allSatisfy { f in
            if flatAbsent.contains(f) { return false }
            if let val = flatValues[f] { return val is NSNull }
            return true
        }

        if allAbsent { continue }
        if allNull { result[top] = NSNull(); continue }

        for fieldName in fieldNames {
            if flatAbsent.contains(fieldName) { continue }
            let paths = pathColumns[fieldName]!
            let val = flatValues[fieldName] ?? NSNull()

            var current = result
            for k in paths.dropLast() {
                if current[k] == nil {
                    current[k] = OrderedDictionary()
                }
                current = current[k] as! OrderedDictionary
            }
            current[paths.last!] = val
        }
    }

    return result
}

private func parseAttachment(_ lines: [String], lineIdx: Int, rest: String,
                              depth: Int) throws -> (String, Any, Int) {
    let name: String
    let afterName: String
    let rv = rest.unicodeScalars
    if rv.first == "\"" {
        var closeIdx: String.UnicodeScalarView.Index? = nil
        var j = rv.index(after: rv.startIndex)
        while j < rv.endIndex {
            if rv[j] == "\\" { j = rv.index(j, offsetBy: 2, limitedBy: rv.endIndex) ?? rv.endIndex; continue }
            if rv[j] == "\"" { closeIdx = j; break }
            j = rv.index(after: j)
        }
        guard let ci = closeIdx else { throw GCFError.unterminatedQuote }
        name = try parseQuotedString(String(rv[rv.startIndex...ci]))
        afterName = String(rv[rv.index(after: ci)...]).trimmingCharacters(in: CharacterSet(charactersIn: " "))
    } else {
        guard let sp = scalarFirstIndex(rest, " ") else { throw GCFError.invalidFieldDeclaration("invalid attachment: \(rest)") }
        name = String(rv[rv.startIndex..<sp])
        afterName = String(rv[sp...]).trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    if scalarHasPrefix(afterName, "{}") {
        var nested = OrderedDictionary()
        let consumed = try parseObjectBody(lines, start: lineIdx + 1, depth: depth, out: &nested)
        return (name, nested, consumed + 1)
    }
    if scalarHasPrefix(afterName, "[") {
        let (arr, consumed) = try parseArrayFromHeader(lines, headerLine: lineIdx, depth: depth, bracketPart: afterName)
        return (name, arr, consumed)
    }
    if afterName.unicodeScalars.first == "=" {
        // Detect the '=' delimiter on unicode scalars, not Characters: a value that
        // begins with a grapheme-extending scalar (for example U+0BD7) would cluster
        // with the leading '=' into a single Character, so hasPrefix("=") and
        // dropFirst() would misread the value (SPEC 2.4 scalars are code points).
        let valStr = String(afterName.unicodeScalars.dropFirst())
        let parsed = try parseScalar(valStr, tabularContext: true)
        if case .missing = parsed { return (name, NSNull(), 1) }
        return (name, try scalarToAny(parsed), 1)
    }
    throw GCFError.invalidFieldDeclaration("invalid attachment form: \(afterName)")
}

private func parseExpandedBody(_ lines: [String], start: Int, depth: Int) throws -> ([Any], Int) {
    let ind = String(repeating: "  ", count: depth)
    var items: [Any] = []
    var i = start

    while i < lines.count {
        let line = lines[i]
        let content: String
        if depth > 0 {
            guard scalarHasPrefix(line, ind) else { break }
            content = scalarDropFirst(line, ind.unicodeScalars.count)
        } else {
            content = line
        }
        if scalarHasPrefix(content, "## ") || scalarHasPrefix(content, "##!") { break }
        guard scalarHasPrefix(content, "@") else { break }
        let cv = content.unicodeScalars
        guard let sp = scalarFirstIndex(content, " ") else { break }

        let idStr = String(cv[cv.index(after: cv.startIndex)..<sp])
        if let id = Int(idStr), id != items.count {
            throw GCFError.invalidItemId(items.count, idStr)
        }

        let marker = String(cv[cv.index(after: sp)...])

        if marker.unicodeScalars.first == "=" {
            let afterEq = marker.unicodeScalars.index(after: marker.unicodeScalars.startIndex)
            let val = try scalarToAny(parseScalar(String(marker.unicodeScalars[afterEq...])))
            items.append(val)
            i += 1
            continue
        }
        if scalarHasPrefix(marker, "{}") {
            var nested = OrderedDictionary()
            i += 1
            let consumed = try parseObjectBody(lines, start: i, depth: depth + 1, out: &nested)
            items.append(nested)
            i += consumed
            continue
        }
        if scalarHasPrefix(marker, "[") {
            let (arr, consumed) = try parseArrayFromHeader(lines, headerLine: i, depth: depth + 1, bracketPart: marker)
            items.append(arr)
            i += consumed
            continue
        }
        break
    }
    return (items, i - start)
}

private func parseCountValue(_ s: String) throws -> Int {
    if s == "0" { return 0 }
    guard !s.isEmpty, s.first != "0" else { throw GCFError.invalidCount(s) }
    guard let n = Int(s), String(n) == s else { throw GCFError.invalidCount(s) }
    return n
}

private func payloadToDict(_ p: Payload) -> [String: Any] {
    let syms: [[String: Any]] = p.symbols.map {
        ["qualifiedName": $0.qualifiedName, "kind": $0.kind, "score": $0.score,
         "provenance": $0.provenance, "distance": $0.distance]
    }
    let edges: [[String: Any]] = p.edges.map {
        ["source": $0.source, "target": $0.target, "edgeType": $0.edgeType, "status": $0.status]
    }
    return [
        "tool": p.tool, "tokenBudget": p.tokenBudget, "tokensUsed": p.tokensUsed,
        "packRoot": p.packRoot, "symbols": syms, "edges": edges,
    ]
}

private func validateSummaryCounts(_ summaryLine: String, deferredCount: Int, contentLines: [String]) throws {
    var countsStr = ""
    for p in summaryLine.split(separator: " ") {
        let ps = String(p)
        if scalarHasPrefix(ps, "counts=") { countsStr = scalarDropFirst(ps, 7); break }
    }
    if countsStr.isEmpty { return }
    let countVals = countsStr.split(separator: ",").map { String($0) }
    if countVals.count != deferredCount {
        throw GCFError.countMismatch(deferredCount, countVals.count)
    }
    var actualCounts: [Int] = []
    var inDeferred = false
    var currentCount = 0
    for line in contentLines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if scalarHasPrefix(trimmed, "## ") && (scalarContains(trimmed, "[?]") || scalarContains(trimmed, "[?:]")) {
            if inDeferred { actualCounts.append(currentCount) }
            inDeferred = true; currentCount = 0; continue
        }
        if scalarHasPrefix(trimmed, "## ") {
            if inDeferred { actualCounts.append(currentCount); inDeferred = false }
            continue
        }
        if inDeferred && !scalarHasPrefix(trimmed, " ") && !scalarHasPrefix(trimmed, ".") {
            currentCount += 1
        }
    }
    if inDeferred { actualCounts.append(currentCount) }
    for (idx, cv) in countVals.enumerated() {
        guard let declared = Int(cv) else { throw GCFError.countMismatch(0, 0) }
        if idx < actualCounts.count && declared != actualCounts[idx] {
            throw GCFError.countMismatch(declared, actualCounts[idx])
        }
    }
}
