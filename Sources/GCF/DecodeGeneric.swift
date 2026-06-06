import Foundation

/// Decode GCF tabular text into a generic value tree.
///
/// Returns dictionaries, arrays, and primitives (`String`, `Int`, `Double`,
/// `Bool`, or `NSNull`) matching the original structure.
///
/// Handles tabular arrays, key-value pairs, nested sections, inline primitive
/// arrays, nested fields in tabular rows, empty arrays, and value parsing
/// (`-` = null, `true`/`false` = bool, numbers, quoted strings).
///
/// If the input starts with `GCF ` (graph profile), falls back to `decode()`
/// and returns the Payload as a dictionary.
public func decodeGeneric(_ input: String) throws -> Any {
    let trimmed = input.trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
    if trimmed.isEmpty {
        return NSNull()
    }

    let lines = trimmed.components(separatedBy: "\n")

    // Graph profile fallback.
    if !lines.isEmpty && lines[0].hasPrefix("GCF ") {
        let p = try decode(input)
        return payloadToDict(p)
    }

    var result: [String: Any] = [:]
    _ = parseObject(lines, start: 0, depth: 0, out: &result)
    return result
}

/// Parse key=value, ## section, tabular array, and inline array lines at the
/// given indentation depth. Returns the number of lines consumed.
@discardableResult
private func parseObject(_ lines: [String], start: Int, depth: Int, out: inout [String: Any]) -> Int {
    let indent = String(repeating: "  ", count: depth)
    var i = start

    while i < lines.count {
        let trimmed = lines[i].hasSuffix("\r") ? String(lines[i].dropLast()) : lines[i]

        if trimmed.isEmpty || trimmed.hasPrefix("# ") {
            i += 1
            continue
        }

        // Check indentation.
        if depth > 0 && !trimmed.hasPrefix(indent) {
            break
        }

        let content = depth > 0 ? String(trimmed.dropFirst(indent.count)) : trimmed

        // Skip _summary lines.
        if content.hasPrefix("## _summary") {
            i += 1
            continue
        }

        // Tabular array: ## name [count]{fields}
        if content.hasPrefix("## ") {
            let header = String(content.dropFirst(3))

            if let bracketIdx = header.range(of: " [") {
                let name = String(header[..<bracketIdx.lowerBound])
                let rest = String(header[bracketIdx.upperBound...])
                if let closeBracket = rest.firstIndex(of: "]") {
                    let afterBracket = String(rest[rest.index(after: closeBracket)...])
                    if afterBracket.hasPrefix("{") {
                        // Tabular with field declaration.
                        if let fieldEnd = afterBracket.firstIndex(of: "}") {
                            let fieldsStr = afterBracket[afterBracket.index(after: afterBracket.startIndex)..<fieldEnd]
                            let fields = fieldsStr.components(separatedBy: ",")
                            i += 1
                            let (rows, consumed) = parseTabularRows(lines, start: i, depth: depth, fields: fields)
                            out[name] = rows
                            i += consumed
                            continue
                        }
                    } else {
                        // Count-only header.
                        let countStr = String(rest[..<closeBracket])
                        if countStr == "0" {
                            out[name] = [Any]()
                            i += 1
                            continue
                        }
                        // Non-uniform array with @N items.
                        i += 1
                        let (items, consumed) = parseNonUniformArray(lines, start: i, depth: depth)
                        out[name] = items
                        i += consumed
                        continue
                    }
                }
            }

            // Plain section header: ## key (nested object).
            var name = header
            if let idx = name.range(of: " [") {
                name = String(name[..<idx.lowerBound])
            }
            i += 1
            var nested: [String: Any] = [:]
            let consumed = parseObject(lines, start: i, depth: depth + 1, out: &nested)
            out[name] = nested
            i += consumed
            continue
        }

        // Inline primitive array: name[N]: val1,val2,...
        if let bracketIdx = content.firstIndex(of: "["),
           bracketIdx > content.startIndex,
           let colonRange = content.range(of: "]: "),
           colonRange.lowerBound > bracketIdx {
            let name = String(content[..<bracketIdx])
            let valsStr = String(content[colonRange.upperBound...])
            let vals = valsStr.components(separatedBy: ",").map { parseValue($0.trimmingCharacters(in: .whitespaces)) }
            out[name] = vals
            i += 1
            continue
        }

        // Key=value pair.
        if let eqIdx = content.firstIndex(of: "="), eqIdx > content.startIndex {
            let key = String(content[..<eqIdx])
            let val = String(content[content.index(after: eqIdx)...])
            out[key] = parseValue(val)
            i += 1
            continue
        }

        // Unrecognized line, skip.
        i += 1
    }

    return i - start
}

/// Parse pipe-separated rows following a tabular header.
private func parseTabularRows(_ lines: [String], start: Int, depth: Int, fields: [String]) -> ([Any], Int) {
    let indent = String(repeating: "  ", count: depth)
    var rows: [Any] = []
    var i = start

    while i < lines.count {
        let line = lines[i].hasSuffix("\r") ? String(lines[i].dropLast()) : lines[i]
        if line.isEmpty {
            i += 1
            continue
        }

        let content: String
        if depth > 0 {
            guard line.hasPrefix(indent) else { break }
            content = String(line.dropFirst(indent.count))
        } else {
            content = line
        }

        // Stop at next section header or _summary.
        if content.hasPrefix("## ") { break }

        // Skip comments.
        if content.hasPrefix("# ") {
            i += 1
            continue
        }

        // Strip @N prefix if present.
        var rowData = content
        var hasNested = false
        if rowData.hasPrefix("@") {
            if let spaceIdx = rowData.firstIndex(of: " ") {
                rowData = String(rowData[rowData.index(after: spaceIdx)...])
                hasNested = true
            }
        }

        // Parse pipe-separated values.
        let vals = rowData.components(separatedBy: "|")
        var row: [String: Any] = [:]
        for (j, f) in fields.enumerated() {
            if j < vals.count {
                row[f] = parseValue(vals[j])
            } else {
                row[f] = NSNull()
            }
        }

        i += 1

        // Parse nested fields (.fieldname).
        if hasNested {
            let nestedIndent = indent + "  "
            while i < lines.count {
                let nestedLine = lines[i].hasSuffix("\r") ? String(lines[i].dropLast()) : lines[i]
                guard nestedLine.hasPrefix(nestedIndent) else { break }
                let nestedContent = String(nestedLine.dropFirst(nestedIndent.count))

                if nestedContent.hasPrefix(".") {
                    let fieldName = String(nestedContent.dropFirst())
                    i += 1
                    var nested: [String: Any] = [:]
                    let consumed = parseObject(lines, start: i, depth: depth + 2, out: &nested)
                    row[fieldName] = nested
                    i += consumed
                } else {
                    break
                }
            }
        }

        rows.append(row)
    }

    return (rows, i - start)
}

/// Parse @N items in a non-uniform array section.
private func parseNonUniformArray(_ lines: [String], start: Int, depth: Int) -> ([Any], Int) {
    let indent = String(repeating: "  ", count: depth)
    var items: [Any] = []
    var i = start

    while i < lines.count {
        let line = lines[i].hasSuffix("\r") ? String(lines[i].dropLast()) : lines[i]
        if line.isEmpty {
            i += 1
            continue
        }

        let content: String
        if depth > 0 {
            guard line.hasPrefix(indent) else { break }
            content = String(line.dropFirst(indent.count))
        } else {
            content = line
        }

        if content.hasPrefix("## ") { break }

        if content.hasPrefix("@") {
            if let spaceIdx = content.firstIndex(of: " ") {
                let val = String(content[content.index(after: spaceIdx)...])
                items.append(parseValue(val))
            }
            i += 1
        } else {
            break
        }
    }

    return (items, i - start)
}

/// Convert a single GCF value string to a typed Swift value.
private func parseValue(_ s: String) -> Any {
    if s == "-" { return NSNull() }
    if s == "true" { return true }
    if s == "false" { return false }
    if s == "\"\"" { return "" }

    // Quoted string.
    if s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") {
        var inner = String(s.dropFirst().dropLast())
        inner = inner.replacingOccurrences(of: "\\\"", with: "\"")
        inner = inner.replacingOccurrences(of: "\\\\", with: "\\")
        return inner
    }

    // Try integer.
    if let n = Int(s) { return n }

    // Try float.
    if let f = Double(s) { return f }

    return s
}

/// Convert a Payload to a generic dictionary for uniform return type.
private func payloadToDict(_ p: Payload) -> [String: Any] {
    let syms: [[String: Any]] = p.symbols.map { s in
        [
            "qualifiedName": s.qualifiedName,
            "kind": s.kind,
            "score": s.score,
            "provenance": s.provenance,
            "distance": s.distance,
        ]
    }
    let edges: [[String: Any]] = p.edges.map { e in
        var m: [String: Any] = [
            "source": e.source,
            "target": e.target,
            "edgeType": e.edgeType,
        ]
        if !e.status.isEmpty {
            m["status"] = e.status
        }
        return m
    }
    return [
        "tool": p.tool,
        "tokenBudget": p.tokenBudget,
        "tokensUsed": p.tokensUsed,
        "packRoot": p.packRoot,
        "symbols": syms,
        "edges": edges,
    ]
}
