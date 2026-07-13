import Foundation
import CryptoKit

/// Sort strings by UTF-8 byte order (matching Go's `sort.Strings` / Rust `str`
/// ordering). Swift's default `String` comparison is Unicode-normalized, not
/// byte-wise, so it is not used here.
private func byteSortedRecords(_ xs: [String]) -> [String] {
    xs.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

private func packRootSHA256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Compute the canonical pack root for a graph snapshot using the
/// gcf-pack-root-v1 algorithm, graph profile (SPEC Section 10.2). Mirrors the Go
/// reference (`PackRoot`) exactly; two implementations given the same logical
/// graph MUST produce the same result, byte-for-byte before hashing.
func packRoot(symbols: [Symbol], edges: [Edge]) -> String {
    // Resolve a kind to its short abbreviation, falling back to the raw kind.
    func abbrev(_ kind: String) -> String {
        if let a = kindAbbrev[kind], !a.isEmpty { return a }
        return kind
    }

    // Build canonical symbol records: "S\t{kind}\t{qname}\t{score}\t{prov}\t{dist}\n".
    // score uses the CANONICAL shortest-decimal number format (not the wire's 2-decimal form).
    var symRecords: [String] = symbols.map { s in
        "S\t\(abbrev(s.kind))\t\(s.qualifiedName)\t\(formatNumber(s.score))\t\(s.provenance)\t\(s.distance)\n"
    }

    // Map qualifiedName -> kindAbbrev over all symbols, to resolve edge endpoint kinds.
    var symKindMap: [String: String] = [:]
    symKindMap.reserveCapacity(symbols.count)
    for s in symbols {
        symKindMap[s.qualifiedName] = abbrev(s.kind)
    }

    // Build canonical edge records: "E\t{srcKind}\t{src}\t{tgtKind}\t{tgt}\t{edgeType}\n".
    var edgeRecords: [String] = edges.map { e in
        let srcKind = symKindMap[e.source] ?? ""
        let tgtKind = symKindMap[e.target] ?? ""
        return "E\t\(srcKind)\t\(e.source)\t\(tgtKind)\t\(e.target)\t\(e.edgeType)\n"
    }

    // Sort symbol and edge records independently by UTF-8 byte order.
    symRecords = byteSortedRecords(symRecords)
    edgeRecords = byteSortedRecords(edgeRecords)

    // canonicalBytes = all symbols then all edges.
    let canonical = symRecords.joined() + edgeRecords.joined()
    return "sha256:" + packRootSHA256Hex(canonical)
}
