import Foundation

/// Decode GCF v2.0 generic or graph profile text into a value tree.
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
        for c in l {
            if c == "\t" { throw GCFError.tabIndentation }
            if c != " " { break }
        }
        let trimmedLine = l.trimmingCharacters(in: .whitespaces)
        if trimmedLine.hasPrefix("# ") { continue }
        if trimmedLine.hasPrefix("##! ") { summaryLine = trimmedLine; continue }
        if trimmedLine.hasPrefix("## ") && trimmedLine.contains("[?]") { deferredCount += 1 }
        contentLines.append(l)
    }

    if !summaryLine.isEmpty && deferredCount > 0 {
        try validateSummaryCounts(summaryLine, deferredCount: deferredCount, contentLines: contentLines)
    }

    if contentLines.isEmpty { return [String: Any]() as NSDictionary }

    let first = contentLines[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))

    // Root scalar.
    if first.hasPrefix("=") {
        if contentLines.count > 1 { throw GCFError.trailingCharacters }
        return try scalarToAny(parseScalar(String(first.dropFirst())))
    }

    // Root array.
    if first.hasPrefix("## [") {
        let (arr, _) = try parseArrayFromHeader(contentLines, headerLine: 0, depth: 0,
                                                  bracketPart: String(first.dropFirst(3)))
        return arr
    }

    // Root object.
    var result = NSMutableDictionary()
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
    }
}

private func parseObjectBody(_ lines: [String], start: Int, depth: Int,
                              out: inout NSMutableDictionary) throws -> Int {
    let ind = String(repeating: "  ", count: depth)
    var i = start
    while i < lines.count {
        let line = lines[i]
        if depth > 0 && !line.hasPrefix(ind) { break }
        let content = depth > 0 ? String(line.dropFirst(ind.count)) : line
        if !content.isEmpty && content.first == " " {
            throw GCFError.invalidIndent
        }

        // Array section.
        if content.hasPrefix("## ") {
            let hdr = String(content.dropFirst(3))
            if let bi = hdr.range(of: " [") {
                let name = try parseKeyFromHeader(String(hdr[hdr.startIndex..<bi.lowerBound]))
                try checkDup(out, key: name)
                let (arr, consumed) = try parseArrayFromHeader(lines, headerLine: i, depth: depth,
                                                                bracketPart: String(hdr[bi.lowerBound...]))
                out[name] = arr
                i += consumed
                continue
            }
            let name = try parseKeyFromHeader(hdr)
            try checkDup(out, key: name)
            i += 1
            var nested = NSMutableDictionary()
            let consumed = try parseObjectBody(lines, start: i, depth: depth + 1, out: &nested)
            out[name] = nested
            i += consumed
            continue
        }

        // Inline array.
        if !content.hasPrefix("@") && !content.hasPrefix("##") {
            if let bracketIdx = content.firstIndex(of: "["), bracketIdx > content.startIndex {
                let rest = String(content[bracketIdx...])
                if let closeIdx = rest.firstIndex(of: "]") {
                    let after = String(rest[rest.index(after: closeIdx)...])
                    if after.hasPrefix(": ") || after == ":" {
                        let name = try parseKeyFromHeader(String(content[content.startIndex..<bracketIdx]))
                        try checkDup(out, key: name)
                        let (arr, _) = try parseArrayFromHeader(lines, headerLine: i, depth: depth, bracketPart: rest)
                        out[name] = arr
                        i += 1
                        continue
                    }
                }
            }
        }

        // Key=value.
        if let eqIdx = findKVSplit(content), eqIdx > content.startIndex {
            let name = try parseKeyFromHeader(String(content[content.startIndex..<eqIdx]))
            try checkDup(out, key: name)
            let val = try scalarToAny(parseScalar(String(content[content.index(after: eqIdx)...])))
            out[name] = val
            i += 1
            continue
        }

        i += 1
    }
    return i - start
}

private func findKVSplit(_ s: String) -> String.Index? {
    if s.isEmpty { return nil }
    if s.first == "\"" {
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            if s[i] == "\\" { i = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex; continue }
            if s[i] == "\"" {
                let next = s.index(after: i)
                if next < s.endIndex && s[next] == "=" { return next }
                return nil
            }
            i = s.index(after: i)
        }
        return nil
    }
    return s.firstIndex(of: "=")
}

private func parseKeyFromHeader(_ s: String) throws -> String {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.count >= 2 && trimmed.first == "\"" {
        return try parseQuotedString(trimmed)
    }
    return trimmed
}

private func checkDup(_ dict: NSMutableDictionary, key: String) throws {
    if dict[key] != nil { throw GCFError.duplicateKey(key) }
}

private func parseArrayFromHeader(_ lines: [String], headerLine: Int, depth: Int,
                                   bracketPart: String) throws -> (Any, Int) {
    let bp = bracketPart.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    guard bp.hasPrefix("[") else { throw GCFError.invalidCount(bp) }
    guard let closeIdx = bp.firstIndex(of: "]") else { throw GCFError.invalidCount(bp) }
    let countStr = String(bp[bp.index(after: bp.startIndex)..<closeIdx])
    let after = String(bp[bp.index(after: closeIdx)...])
    let count: Int = countStr == "?" ? -1 : try parseCountValue(countStr)

    if count == 0 && !after.hasPrefix("{") && !after.hasPrefix(":") {
        return ([] as [Any], 1)
    }

    // Inline.
    if after.hasPrefix(": ") || after == ":" {
        let valsStr = after.hasPrefix(": ") ? String(after.dropFirst(2)) : ""
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
    if after.hasPrefix("{") {
        guard let braceEnd = findClosingBrace(after) else { throw GCFError.invalidFieldDeclaration(after) }
        let declStr = String(after[after.startIndex...after.index(after.startIndex, offsetBy: braceEnd)])
        let fields = try splitFieldDecl(declStr)
        let (rows, consumed) = try parseTabularBody(lines, start: headerLine + 1, depth: depth, fields: fields, expectedCount: count)
        if count >= 0 && rows.count != count { throw GCFError.countMismatch(count, rows.count) }
        return (rows, consumed + 1)
    }

    // Expanded.
    let (items, consumed) = try parseExpandedBody(lines, start: headerLine + 1, depth: depth)
    if count >= 0 && items.count != count { throw GCFError.countMismatch(count, items.count) }
    return (items, consumed + 1)
}

private func parseTabularBody(_ lines: [String], start: Int, depth: Int,
                               fields: [String], expectedCount: Int) throws -> ([Any], Int) {
    let ind = String(repeating: "  ", count: depth)
    var rows: [Any] = []
    var i = start

    while i < lines.count {
        let line = lines[i]
        let content: String
        if depth > 0 {
            guard line.hasPrefix(ind) else { break }
            content = String(line.dropFirst(ind.count))
        } else {
            content = line
        }
        if content.hasPrefix("## ") || content.hasPrefix("##!") { break }
        if !content.isEmpty && content.first == " " {
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(".") { throw GCFError.orphanAttachment(trimmed) }
            break
        }

        var rowData = content
        var rowHasID = false
        if rowData.hasPrefix("@") {
            if let sp = rowData.firstIndex(of: " ") {
                rowData = String(rowData[rowData.index(after: sp)...])
                rowHasID = true
            }
        }

        let vals = splitRespectingQuotes(rowData, delimiter: "|")
        if vals.count != fields.count { throw GCFError.rowWidthMismatch(fields.count, vals.count) }

        var cellValues = NSMutableDictionary()
        var attachmentFields: [String] = []
        var missingFields = Set<String>()
        for (j, f) in fields.enumerated() {
            let parsed = try parseScalar(vals[j], tabularContext: true)
            switch parsed {
            case .missing: missingFields.insert(f)
            case .attachment: attachmentFields.append(f)
            default: cellValues[f] = try scalarToAny(parsed)
            }
        }
        i += 1

        // Parse attachments.
        let attachmentValues = NSMutableDictionary()
        if rowHasID && !attachmentFields.isEmpty {
            let attIndent = ind + "  "
            while i < lines.count {
                let al = lines[i]
                guard al.hasPrefix(attIndent) else { break }
                let ac = String(al.dropFirst(attIndent.count))
                guard ac.hasPrefix(".") else { break }
                let (name, val, consumed) = try parseAttachment(lines, lineIdx: i, rest: String(ac.dropFirst()), depth: depth + 2)
                if attachmentValues[name] != nil { throw GCFError.duplicateAttachment(name) }
                attachmentValues[name] = val
                i += consumed
            }
            for f in attachmentFields {
                if attachmentValues[f] == nil { throw GCFError.missingAttachment(f) }
            }
        }

        // Orphan check.
        if !rowHasID || attachmentFields.isEmpty {
            let attIndent = ind + "  "
            if i < lines.count && lines[i].hasPrefix(attIndent) {
                let peek = String(lines[i].dropFirst(attIndent.count))
                if peek.hasPrefix(".") { throw GCFError.orphanAttachment(peek) }
            }
        }

        // Build row in field order.
        let row = NSMutableDictionary()
        for f in fields {
            if missingFields.contains(f) { continue }
            if let v = cellValues[f] { row[f] = v; continue }
            if let v = attachmentValues[f] { row[f] = v; continue }
        }
        rows.append(row)

        if expectedCount >= 0 && rows.count >= expectedCount { break }
    }
    return (rows, i - start)
}

private func parseAttachment(_ lines: [String], lineIdx: Int, rest: String,
                              depth: Int) throws -> (String, Any, Int) {
    let name: String
    let afterName: String
    if rest.first == "\"" {
        var closeIdx: String.Index? = nil
        var j = rest.index(after: rest.startIndex)
        while j < rest.endIndex {
            if rest[j] == "\\" { j = rest.index(j, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex; continue }
            if rest[j] == "\"" { closeIdx = j; break }
            j = rest.index(after: j)
        }
        guard let ci = closeIdx else { throw GCFError.unterminatedQuote }
        name = try parseQuotedString(String(rest[rest.startIndex...ci]))
        afterName = String(rest[rest.index(after: ci)...]).trimmingCharacters(in: CharacterSet(charactersIn: " "))
    } else {
        guard let sp = rest.firstIndex(of: " ") else { throw GCFError.invalidFieldDeclaration("invalid attachment: \(rest)") }
        name = String(rest[rest.startIndex..<sp])
        afterName = String(rest[sp...]).trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    if afterName.hasPrefix("{}") {
        var nested = NSMutableDictionary()
        let consumed = try parseObjectBody(lines, start: lineIdx + 1, depth: depth, out: &nested)
        return (name, nested, consumed + 1)
    }
    if afterName.hasPrefix("[") {
        let (arr, consumed) = try parseArrayFromHeader(lines, headerLine: lineIdx, depth: depth, bracketPart: afterName)
        return (name, arr, consumed)
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
            guard line.hasPrefix(ind) else { break }
            content = String(line.dropFirst(ind.count))
        } else {
            content = line
        }
        if content.hasPrefix("## ") || content.hasPrefix("##!") { break }
        guard content.hasPrefix("@") else { break }
        guard let sp = content.firstIndex(of: " ") else { break }

        let idStr = String(content[content.index(after: content.startIndex)..<sp])
        if let id = Int(idStr), id != items.count {
            throw GCFError.invalidItemId(items.count, idStr)
        }

        let marker = String(content[content.index(after: sp)...])

        if marker.hasPrefix("=") {
            let val = try scalarToAny(parseScalar(String(marker.dropFirst())))
            items.append(val)
            i += 1
            continue
        }
        if marker.hasPrefix("{}") {
            var nested = NSMutableDictionary()
            i += 1
            let consumed = try parseObjectBody(lines, start: i, depth: depth + 1, out: &nested)
            items.append(nested)
            i += consumed
            continue
        }
        if marker.hasPrefix("[") {
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
        if p.hasPrefix("counts=") { countsStr = String(p.dropFirst(7)); break }
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
        if trimmed.hasPrefix("## ") && trimmed.contains("[?]") {
            if inDeferred { actualCounts.append(currentCount) }
            inDeferred = true; currentCount = 0; continue
        }
        if trimmed.hasPrefix("## ") {
            if inDeferred { actualCounts.append(currentCount); inDeferred = false }
            continue
        }
        if inDeferred && !trimmed.hasPrefix(" ") && !trimmed.hasPrefix(".") {
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
