import Foundation

/// Errors that can occur during GCF decoding.
public enum DecodeError: Error, Equatable {
    case emptyInput
    case invalidHeader(String)
    case missingTool
    case invalidSymbolLine(String)
    case tooFewSymbolFields(String)
    case invalidScore(String)
    case invalidEdgeLine(String)
    case unknownEdgeID(String)
}

/// Decode parses GCF text back into a Payload.
public func decode(_ input: String) throws -> Payload {
    let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else {
        throw DecodeError.emptyInput
    }

    var p = Payload(tool: "")

    // Parse header.
    let header = lines[0]
    guard header.hasPrefix("GCF ") else {
        throw DecodeError.invalidHeader(header)
    }
    parseHeader(String(header.dropFirst(4)), &p)
    guard !p.tool.isEmpty else {
        throw DecodeError.missingTool
    }

    // Parse body: symbols and edges.
    var symbols: [Symbol] = []
    var symByID: [Int: Int] = [:] // symbol ID -> index in symbols array
    var currentDistance = 0
    var inEdges = false

    for line in lines.dropFirst() {
        let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if trimmed.isEmpty { continue }

        // Group header.
        if trimmed.hasPrefix("## ") {
            let group = String(trimmed.dropFirst(3))
            inEdges = (group == "edges")
            if !inEdges {
                switch group {
                case "targets": currentDistance = 0
                case "related": currentDistance = 1
                case "extended": currentDistance = 2
                default:
                    if group.hasPrefix("distance_"),
                       let d = Int(group.dropFirst(9)) {
                        currentDistance = d
                    }
                }
            }
            continue
        }

        // Comment.
        if trimmed.hasPrefix("# ") { continue }

        if inEdges {
            let edge = try parseEdgeLine(trimmed, symbols: symbols, symByID: symByID)
            p.edges.append(edge)
        } else {
            let (sym, id) = try parseSymbolLine(trimmed, distance: currentDistance)
            symByID[id] = symbols.count
            symbols.append(sym)
        }
    }

    p.symbols = symbols
    return p
}

private func parseHeader(_ fields: String, _ p: inout Payload) {
    for part in fields.split(separator: " ") {
        let kv = part.split(separator: "=", maxSplits: 1)
        guard kv.count == 2 else { continue }
        let key = String(kv[0])
        let val = String(kv[1])
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
    guard line.hasPrefix("@") else {
        throw DecodeError.invalidSymbolLine(line)
    }

    let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard parts.count >= 5 else {
        throw DecodeError.tooFewSymbolFields(line)
    }

    let idStr = String(parts[0].dropFirst()) // strip @
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
    let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard parts.count >= 2 else {
        throw DecodeError.invalidEdgeLine(line)
    }

    let ref = parts[0]
    guard let ltIdx = ref.firstIndex(of: "<") else {
        throw DecodeError.invalidEdgeLine(line)
    }

    let targetIDStr = String(ref[ref.index(after: ref.startIndex)..<ltIdx]) // strip leading @
    let afterLt = ref.index(after: ltIdx)
    let sourceIDStr = String(ref[ref.index(after: afterLt)...]) // strip <@

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
