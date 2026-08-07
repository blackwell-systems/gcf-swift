import Foundation

/// Error thrown by graph delta decode/verify. Its `description` carries a stable
/// error code prefix (`malformed_delta`, `delta_invalid`, `root_mismatch`) so
/// callers and conformance fixtures can match on the code.
public struct DeltaError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Expand a kind abbreviation to its full form (identity if unknown).
private func expandKind(_ k: String) -> String {
    kindExpand[k] ?? k
}

/// Encode a DeltaPayload into GCF delta format.
public func encodeDelta(_ delta: DeltaPayload) -> String {
    var b = ""

    // Header.
    var savings = 0.0
    if delta.fullTokens > 0 {
        savings = 100.0 * (1.0 - Double(delta.deltaTokens) / Double(delta.fullTokens))
    }
    b += "GCF profile=graph tool=\(delta.tool) delta=true base_root=\(delta.baseRoot) new_root=\(delta.newRoot) tokens=\(delta.deltaTokens) savings=\(String(format: "%.0f", savings))%\n"

    // Removed symbols: short references (consumer already has the full declaration).
    if !delta.removed.isEmpty {
        b += "## removed\n"
        for s in delta.removed {
            let kind = kindAbbrev[s.kind] ?? s.kind
            b += "\(kind) \(s.qualifiedName)\n"
        }
    }

    // Added symbols: full declarations (consumer doesn't have these).
    if !delta.added.isEmpty {
        b += "## added\n"
        for (i, s) in delta.added.enumerated() {
            let kind = kindAbbrev[s.kind] ?? s.kind
            b += "@\(i) \(kind) \(s.qualifiedName) \(String(format: "%.2f", s.score)) \(s.provenance) \(s.distance)\n"
        }
    }

    // Removed edges.
    if !delta.removedEdges.isEmpty {
        b += "## edges_removed\n"
        for e in delta.removedEdges {
            b += "\(e.source) -> \(e.target) \(e.edgeType)\n"
        }
    }

    // Added edges.
    if !delta.addedEdges.isEmpty {
        b += "## edges_added\n"
        for e in delta.addedEdges {
            b += "\(e.source) -> \(e.target) \(e.edgeType)\n"
        }
    }

    return b
}

/// Parse a `source -> target type` delta edge line.
private func parseDeltaEdge(_ line: String) throws -> Edge {
    // Locate the " -> " separator over unicode scalars: a target beginning with a
    // grapheme-extending scalar would otherwise cluster with the trailing space
    // and be misread (SPEC 2.4).
    guard let lo = scalarRangeStart(line, " -> ") else {
        throw DeltaError("malformed_delta: edge line missing ' -> ': \(line)")
    }
    let lv = line.unicodeScalars
    let source = String(lv[lv.startIndex..<lo])
    let afterSep = lv.index(lo, offsetBy: 4) // past " -> "
    let rest = fields(String(lv[afterSep...]))
    guard rest.count == 2 else {
        throw DeltaError("malformed_delta: edge line \(line) must be 'source -> target type'")
    }
    return Edge(source: source, target: rest[0], edgeType: rest[1])
}

/// Split a line on runs of ASCII whitespace (mirrors Go's strings.Fields).
/// Operates on unicode scalars so a field beginning with a grapheme-extending
/// scalar is not merged with its whitespace delimiter (SPEC 2.4).
private func fields(_ line: String) -> [String] {
    var parts: [String] = []
    var current: [Unicode.Scalar] = []
    for c in line.unicodeScalars {
        if c == " " || c == "\t" {
            if !current.isEmpty { parts.append(String(String.UnicodeScalarView(current))); current = [] }
        } else {
            current.append(c)
        }
    }
    if !current.isEmpty { parts.append(String(String.UnicodeScalarView(current))) }
    return parts
}

/// Returns the scalar-view index where the scalars of `needle` first occur in
/// `s`, or nil. Used to find multi-scalar separators without grapheme clustering.
private func scalarRangeStart(_ s: String, _ needle: String) -> String.UnicodeScalarView.Index? {
    let sv = s.unicodeScalars
    let nv = Array(needle.unicodeScalars)
    if nv.isEmpty { return sv.startIndex }
    var i = sv.startIndex
    while i < sv.endIndex {
        var j = i
        var k = 0
        while k < nv.count, j < sv.endIndex, sv[j] == nv[k] {
            j = sv.index(after: j); k += 1
        }
        if k == nv.count { return i }
        i = sv.index(after: i)
    }
    return nil
}

/// Parse a GCF graph delta wire payload (as produced by encodeDelta) back into a
/// DeltaPayload. Kind abbreviations on removed/added lines are expanded to their
/// full form so the result matches a base snapshot's symbol identities. Mirrors
/// the Go reference `DecodeDelta`.
func decodeDelta(_ wire: String) throws -> DeltaPayload {
    // Split on newlines and detect structural markers over unicode scalars so a
    // line or field adjacent to a grapheme-extending scalar is not misread (SPEC 2.4).
    var tv = Array(wire.unicodeScalars)
    while let last = tv.last, last == "\n" { tv.removeLast() }
    let trimmed = String(String.UnicodeScalarView(tv))
    let lines = scalarSplit(trimmed, "\n")
    guard let first = lines.first, !first.isEmpty else {
        throw DeltaError("missing_header: empty delta payload")
    }
    let header = scalarHasSuffix(first, "\r") ? String(first.unicodeScalars.dropLast()) : first
    guard scalarHasPrefix(header, "GCF profile=graph") else {
        throw DeltaError("missing_profile: delta header must begin with 'GCF profile=graph'")
    }

    var tool = "", baseRoot = "", newRoot = ""
    for field in fields(header) {
        guard let eq = scalarFirstIndex(field, "=") else { continue }
        let fv = field.unicodeScalars
        let key = String(fv[fv.startIndex..<eq])
        let value = String(fv[fv.index(after: eq)...])
        switch key {
        case "tool": tool = value
        case "base_root": baseRoot = value
        case "new_root": newRoot = value
        default: break
        }
    }

    var removed: [Symbol] = [], added: [Symbol] = []
    var removedEdges: [Edge] = [], addedEdges: [Edge] = []

    var section = ""
    for raw in lines.dropFirst() {
        let line = scalarHasSuffix(raw, "\r") ? String(raw.unicodeScalars.dropLast()) : raw
        if line.isEmpty { continue }
        if scalarHasPrefix(line, "## ") {
            section = scalarDropFirst(line, 3).trimmingCharacters(in: .whitespaces)
            switch section {
            case "removed", "added", "edges_removed", "edges_added": break
            default: throw DeltaError("malformed_delta: unknown section \(section)")
            }
            continue
        }
        switch section {
        case "removed":
            let parts = fields(line)
            guard parts.count == 2 else {
                throw DeltaError("malformed_delta: removed line \(line) must be 'kind qname'")
            }
            removed.append(Symbol(qualifiedName: parts[1], kind: expandKind(parts[0])))
        case "added":
            let parts = fields(line)
            guard parts.count == 6 else {
                throw DeltaError("malformed_delta: added line \(line) must be '@id kind qname score provenance distance'")
            }
            guard let score = Double(parts[3]) else {
                throw DeltaError("malformed_delta: invalid added score \(parts[3])")
            }
            guard let dist = Int(parts[5]) else {
                throw DeltaError("malformed_delta: invalid added distance \(parts[5])")
            }
            added.append(Symbol(qualifiedName: parts[2], kind: expandKind(parts[1]),
                                score: score, provenance: parts[4], distance: dist))
        case "edges_removed":
            removedEdges.append(try parseDeltaEdge(line))
        case "edges_added":
            addedEdges.append(try parseDeltaEdge(line))
        default:
            throw DeltaError("malformed_delta: data line \(line) before any section header")
        }
    }

    return DeltaPayload(tool: tool, baseRoot: baseRoot, newRoot: newRoot,
                        removed: removed, added: added,
                        removedEdges: removedEdges, addedEdges: addedEdges)
}

/// Verify that applying a delta to a base snapshot produces the expected new_root.
/// Returns the resulting symbols and edges if verification succeeds; throws a
/// DeltaError (`delta_invalid` / `root_mismatch`) otherwise. Mirrors the Go
/// reference `VerifyDelta`.
func verifyDelta(
    baseSymbols: [Symbol], baseEdges: [Edge],
    removed removedSymbols: [Symbol], added addedSymbols: [Symbol],
    removedEdges: [Edge], addedEdges: [Edge],
    expectedNewRoot: String
) throws -> (symbols: [Symbol], edges: [Edge]) {
    // Symbol identity is (kind, qualifiedName).
    struct SymKey: Hashable { let kind: String; let qname: String }
    var symMap: [SymKey: Symbol] = [:]
    for s in baseSymbols { symMap[SymKey(kind: s.kind, qname: s.qualifiedName)] = s }

    for s in removedSymbols {
        let key = SymKey(kind: s.kind, qname: s.qualifiedName)
        guard symMap[key] != nil else {
            throw DeltaError("delta_invalid: removing symbol \(s.kind) \(s.qualifiedName) that does not exist in base")
        }
        symMap[key] = nil
    }
    for s in addedSymbols {
        let key = SymKey(kind: s.kind, qname: s.qualifiedName)
        guard symMap[key] == nil else {
            throw DeltaError("delta_invalid: adding symbol \(s.kind) \(s.qualifiedName) that already exists")
        }
        symMap[key] = s
    }
    let resultSymbols = Array(symMap.values)

    // Edge identity is (source, target, edgeType).
    struct EdgeKey: Hashable { let source: String; let target: String; let edgeType: String }
    var edgeMap: [EdgeKey: Edge] = [:]
    for e in baseEdges { edgeMap[EdgeKey(source: e.source, target: e.target, edgeType: e.edgeType)] = e }

    for e in removedEdges {
        let key = EdgeKey(source: e.source, target: e.target, edgeType: e.edgeType)
        guard edgeMap[key] != nil else {
            throw DeltaError("delta_invalid: removing edge \(e.source) -> \(e.target) \(e.edgeType) that does not exist")
        }
        edgeMap[key] = nil
    }
    for e in addedEdges {
        let key = EdgeKey(source: e.source, target: e.target, edgeType: e.edgeType)
        guard edgeMap[key] == nil else {
            throw DeltaError("delta_invalid: adding edge \(e.source) -> \(e.target) \(e.edgeType) that already exists")
        }
        edgeMap[key] = e
    }
    let resultEdges = Array(edgeMap.values)

    let computed = packRoot(symbols: resultSymbols, edges: resultEdges)
    guard computed == expectedNewRoot else {
        throw DeltaError("root_mismatch: computed \(computed), expected \(expectedNewRoot)")
    }
    return (resultSymbols, resultEdges)
}
