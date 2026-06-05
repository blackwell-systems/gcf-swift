import Foundation

/// Encode a DeltaPayload into GCF delta format.
public func encodeDelta(_ delta: DeltaPayload) -> String {
    var b = ""

    // Header.
    var savings = 0.0
    if delta.fullTokens > 0 {
        savings = 100.0 * (1.0 - Double(delta.deltaTokens) / Double(delta.fullTokens))
    }
    b += "GCF tool=\(delta.tool) delta=true base_root=\(delta.baseRoot) new_root=\(delta.newRoot) tokens=\(delta.deltaTokens) savings=\(String(format: "%.0f", savings))%\n"

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
            b += "@\(i) \(kind) \(s.qualifiedName) \(String(format: "%.2f", s.score)) \(s.provenance)\n"
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
