import Foundation

/// Errors that can occur during GCF decoding.
public enum DecodeError: Error, Equatable, CustomStringConvertible {
    case emptyInput
    case invalidHeader(String)
    case invalidSymbolLine(String)
    case tooFewSymbolFields(String)
    case invalidScore(String)
    case invalidEdgeLine(String)
    case unknownEdgeID(String)
    case malformedDelta(String)
    case countMismatch(String)

    public var description: String {
        switch self {
        case .emptyInput: return "missing_header: empty input"
        case .invalidHeader(let h): return "missing_header: invalid header \(h)"
        case .invalidSymbolLine(let l): return "invalid_symbol_id: \(l)"
        case .tooFewSymbolFields(let l): return "invalid_node_line: \(l)"
        case .invalidScore(let s): return "invalid_score: \(s)"
        case .invalidEdgeLine(let l): return "invalid_edge_syntax: \(l)"
        case .unknownEdgeID(let l): return "unknown_edge_reference: \(l)"
        case .malformedDelta(let s): return "malformed_delta: \(s)"
        case .countMismatch(let s): return "count_mismatch: \(s)"
        }
    }
}

/// Decode parses GCF text back into a Payload.
public func decode(_ input: String) throws -> Payload {
    // Split on newlines over scalars: a line whose first scalar is
    // grapheme-extending must not cluster with the preceding "\n" and swallow the
    // line break (SPEC 2.4).
    let lines = scalarSplit(input.replacingOccurrences(of: "\r\n", with: "\n"), "\n")
    guard !lines.isEmpty else {
        throw DecodeError.emptyInput
    }

    var p = Payload(tool: "")

    // Parse header.
    let header = lines[0]
    guard scalarHasPrefix(header, "GCF ") else {
        throw DecodeError.invalidHeader(header)
    }
    parseHeader(scalarDropFirst(header, 4), &p)
    // v3.1: tool field is optional (SHOULD be present for MCP tool responses, not required).

    let isDelta = scalarContains(header, "delta=true")
    let validDeltaSections: Set<String> = ["removed", "added", "edges_removed", "edges_added"]

    // Parse body: symbols and edges.
    var symbols: [Symbol] = []
    var symByID: [Int: Int] = [:] // symbol ID -> index in symbols array
    var currentDistance = 0
    var inEdges = false
    var declaredEdges = -1
    var edgesDeclared = false

    for line in lines.dropFirst() {
        let trimmed = scalarHasSuffix(line, "\r") ? String(line.unicodeScalars.dropLast()) : line
        if trimmed.isEmpty { continue }

        // Skip ##! summary trailer.
        if scalarHasPrefix(trimmed, "##! ") { continue }

        // Group header.
        if scalarHasPrefix(trimmed, "## ") {
            var group = scalarDropFirst(trimmed, 3)
            // Strip bracket suffix: "edges [200]" -> "edges", capturing the
            // declared count so it can be enforced per Section 13. Locate the " ["
            // delimiter over scalars so a group name adjacent to a
            // grapheme-extending scalar is not misread (SPEC 2.4).
            var declaredCount = -1
            let gv = group.unicodeScalars
            var gi = gv.startIndex
            while gi < gv.endIndex {
                if gv[gi] == " " {
                    let nxt = gv.index(after: gi)
                    if nxt < gv.endIndex && gv[nxt] == "[" {
                        let groupName = String(gv[gv.startIndex..<gi])
                        // Extract the count between "[" and "]".
                        var ci = gv.index(after: nxt)
                        var cntScalars = String.UnicodeScalarView()
                        while ci < gv.endIndex && gv[ci] != "]" {
                            cntScalars.append(gv[ci])
                            ci = gv.index(after: ci)
                        }
                        let cntStr = String(cntScalars)
                        if cntStr != "?" && !cntStr.isEmpty { // "[?]" is a streaming deferred count (Section 8)
                            if let n = Int(cntStr) {
                                declaredCount = n
                            } else {
                                throw DecodeError.countMismatch("invalid section count \"\(cntStr)\"")
                            }
                        }
                        group = groupName
                        break
                    }
                }
                gi = gv.index(after: gi)
            }
            if isDelta && !validDeltaSections.contains(group) {
                throw DecodeError.malformedDelta("invalid delta section \"\(group)\"")
            }
            inEdges = (group == "edges")
            if inEdges && declaredCount >= 0 {
                declaredEdges = declaredCount
                edgesDeclared = true
            }
            if !inEdges {
                switch group {
                case "targets": currentDistance = 0
                case "related": currentDistance = 1
                case "extended": currentDistance = 2
                default:
                    if scalarHasPrefix(group, "distance_"),
                       let d = Int(scalarDropFirst(group, 9)) {
                        currentDistance = d
                    }
                }
            }
            continue
        }

        // Comment.
        if scalarHasPrefix(trimmed, "# ") { continue }

        if inEdges {
            let edge = try parseEdgeLine(trimmed, symbols: symbols, symByID: symByID)
            p.edges.append(edge)
        } else {
            let (sym, id) = try parseSymbolLine(trimmed, distance: currentDistance)
            symByID[id] = symbols.count
            symbols.append(sym)
        }
    }

    // Section 13: a declared [N] section count MUST match the actual item count.
    // The graph edges section is the graph profile's only [N]-bearing section.
    if edgesDeclared && p.edges.count != declaredEdges {
        throw DecodeError.countMismatch("declared \(declaredEdges) edges, got \(p.edges.count)")
    }

    p.symbols = symbols
    return p
}

private func parseHeader(_ fields: String, _ p: inout Payload) {
    // Split header fields and each key=value on scalars: a tool name, pack_root,
    // or other value beginning with a grapheme-extending scalar would otherwise
    // cluster with the space or '=' delimiter (SPEC 2.4).
    for part in scalarSplitNonEmpty(fields, " ") {
        guard let eq = scalarFirstIndex(part, "=") else { continue }
        let pv = part.unicodeScalars
        let key = String(pv[pv.startIndex..<eq])
        let val = String(pv[pv.index(after: eq)...])
        switch key {
        case "tool": p.tool = val
        case "budget": p.tokenBudget = Int(val) ?? 0
        case "tokens": p.tokensUsed = Int(val) ?? 0
        case "pack_root": p.packRoot = val
        case "symbols": break // informational
        default: break
        }
    }
}

private func parseSymbolLine(_ line: String, distance: Int) throws -> (Symbol, Int) {
    guard scalarHasPrefix(line, "@") else {
        throw DecodeError.invalidSymbolLine(line)
    }

    // Split on the space delimiter over unicode scalars: a qualifiedName or
    // provenance beginning with a grapheme-extending scalar would otherwise
    // cluster with the preceding space, collapsing two fields into one
    // (SPEC 2.4: scalars are code points).
    let parts = scalarSplitNonEmpty(line, " ")
    guard parts.count >= 5 else {
        throw DecodeError.tooFewSymbolFields(line)
    }

    let idStr = scalarDropFirst(parts[0], 1) // strip @
    guard let id = Int(idStr) else {
        throw DecodeError.invalidSymbolLine(line)
    }

    var kind = parts[1]
    if let expanded = kindExpand[kind] {
        kind = expanded
    }

    let qname = parts[2]

    guard let score = Double(parts[3]) else {
        throw DecodeError.invalidScore(parts[3])
    }

    let provenance = parts[4]

    return (Symbol(
        qualifiedName: qname,
        kind: kind,
        score: score,
        provenance: provenance,
        distance: distance
    ), id)
}

private func parseEdgeLine(_ line: String, symbols: [Symbol], symByID: [Int: Int]) throws -> Edge {
    // Split on scalars so an edge_type or status field adjacent to a
    // grapheme-extending scalar is not merged with its delimiter (SPEC 2.4).
    let parts = scalarSplitNonEmpty(line, " ")
    guard parts.count >= 2 else {
        throw DecodeError.invalidEdgeLine(line)
    }

    let ref = parts[0]
    let rv = ref.unicodeScalars
    guard let ltIdx = scalarFirstIndex(ref, "<") else {
        throw DecodeError.invalidEdgeLine(line)
    }

    let targetIDStr = String(rv[rv.index(after: rv.startIndex)..<ltIdx]) // strip leading @
    let afterLt = rv.index(after: ltIdx)
    let sourceIDStr = String(rv[rv.index(after: afterLt)...]) // strip <@

    guard let targetID = Int(targetIDStr),
          let sourceID = Int(sourceIDStr) else {
        throw DecodeError.invalidEdgeLine(line)
    }

    guard let targetIdx = symByID[targetID],
          let sourceIdx = symByID[sourceID] else {
        throw DecodeError.unknownEdgeID(line)
    }

    let edgeType = parts[1]
    let status = parts.count >= 3 ? parts[2] : ""

    return Edge(
        source: symbols[sourceIdx].qualifiedName,
        target: symbols[targetIdx].qualifiedName,
        edgeType: edgeType,
        status: status
    )
}
