import Foundation

/// Encode serializes a Payload into GCF text format.
public func encode(_ payload: Payload) -> String {
    var b = ""

    // Group symbols by distance (sorted by score descending within each group).
    let groups = groupByDistance(payload.symbols)

    // Build symbol index AFTER sorting, so IDs are sequential in output order.
    var symIndex: [String: Int] = [:]
    var nextID = 0
    for g in groups {
        for s in g.symbols {
            symIndex[s.qualifiedName] = nextID
            nextID += 1
        }
    }

    // Count valid edges (both endpoints in symbol index).
    let validEdges = payload.edges.filter { symIndex[$0.source] != nil && symIndex[$0.target] != nil }.count

    // Header line. Zero-valued fields are omitted.
    b += "GCF profile=graph tool=\(payload.tool)"
    if payload.tokenBudget > 0 {
        b += " budget=\(payload.tokenBudget)"
    }
    if payload.tokensUsed > 0 {
        b += " tokens=\(payload.tokensUsed)"
    }
    b += " symbols=\(payload.symbols.count)"
    if validEdges > 0 {
        b += " edges=\(validEdges)"
    }
    if !payload.packRoot.isEmpty {
        b += " pack_root=\(payload.packRoot)"
    }
    b += "\n"

    let groupNames = ["targets", "related", "extended"]

    for g in groups {
        if g.symbols.isEmpty { continue }
        let name: String
        if g.distance < groupNames.count {
            name = groupNames[g.distance]
        } else {
            name = "distance_\(g.distance)"
        }
        b += "## \(name)\n"

        for s in g.symbols {
            let idx = symIndex[s.qualifiedName]!
            let kind = kindAbbrev[s.kind] ?? s.kind
            b += "@\(idx) \(kind) \(s.qualifiedName) \(String(format: "%.2f", s.score)) \(s.provenance)\n"
        }
    }

    // Edges section.
    if !payload.edges.isEmpty {
        b += "## edges [\(validEdges)]\n"
        for e in payload.edges {
            guard let srcIdx = symIndex[e.source],
                  let tgtIdx = symIndex[e.target] else { continue }
            var line = "@\(tgtIdx)<@\(srcIdx) \(e.edgeType)"
            if !e.status.isEmpty && e.status != "unchanged" {
                line += " \(e.status)"
            }
            b += line + "\n"
        }
    }

    return b
}

struct DistanceGroup {
    let distance: Int
    var symbols: [Symbol]
}

func groupByDistance(_ symbols: [Symbol]) -> [DistanceGroup] {
    guard !symbols.isEmpty else { return [] }
    // Sort by distance ascending, then score descending within each group (stable).
    let sorted = symbols.enumerated().sorted { a, b in
        if a.element.distance != b.element.distance {
            return a.element.distance < b.element.distance
        }
        if a.element.score != b.element.score {
            return a.element.score > b.element.score
        }
        return a.offset < b.offset  // stable: preserve original order on ties
    }.map { $0.element }
    var groups: [DistanceGroup] = []
    var current: DistanceGroup?
    for s in sorted {
        if current == nil || current!.distance != s.distance {
            if let c = current {
                groups.append(c)
            }
            current = DistanceGroup(distance: s.distance, symbols: [s])
        } else {
            current!.symbols.append(s)
        }
    }
    if let c = current {
        groups.append(c)
    }
    return groups
}
