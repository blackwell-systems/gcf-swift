import Foundation

/// Encode serializes a Payload into GCF text format.
public func encode(_ payload: Payload) -> String {
    var b = ""

    // Build symbol index for edge references.
    var symIndex: [String: Int] = [:]
    for (i, s) in payload.symbols.enumerated() {
        symIndex[s.qualifiedName] = i
    }

    // Count valid edges (both endpoints in symbol index).
    let validEdges = payload.edges.filter { symIndex[$0.source] != nil && symIndex[$0.target] != nil }.count

    // Header line.
    b += "GCF profile=graph tool=\(payload.tool) budget=\(payload.tokenBudget) tokens=\(payload.tokensUsed) symbols=\(payload.symbols.count) edges=\(validEdges)"
    if !payload.packRoot.isEmpty {
        b += " pack_root=\(payload.packRoot)"
    }
    b += "\n"

    // Group symbols by distance.
    let groups = groupByDistance(payload.symbols)
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
    var groups: [DistanceGroup] = []
    var current: DistanceGroup?
    for s in symbols {
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
