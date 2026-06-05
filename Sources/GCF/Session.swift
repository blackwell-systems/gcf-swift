import Foundation

/// Session tracks symbols that have been transmitted to a client, enabling
/// subsequent responses to reference them by ID without full retransmission.
/// This makes multi-call workflows progressively cheaper.
///
/// Thread-safe: multiple tool handlers may encode concurrently within a session.
public class Session {
    private let lock = NSLock()
    private var symbols: [String: Int] = [:]
    private var nextID: Int = 0

    public init() {}

    /// Returns true if the symbol has been sent in a previous response.
    public func transmitted(_ qname: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return symbols[qname] != nil
    }

    /// Returns the session-global ID for a previously transmitted symbol.
    /// Returns -1 if not found.
    public func getID(_ qname: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return symbols[qname] ?? -1
    }

    /// Marks symbols as transmitted and assigns session-global IDs.
    /// Call this after a successful encode to register newly-sent symbols.
    public func record(_ symbols: [Symbol]) {
        lock.lock()
        defer { lock.unlock() }
        for sym in symbols {
            if self.symbols[sym.qualifiedName] == nil {
                self.symbols[sym.qualifiedName] = nextID
                nextID += 1
            }
        }
    }

    /// Returns the number of symbols tracked in this session.
    public var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return symbols.count
    }

    /// Clears the session state.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        symbols.removeAll()
        nextID = 0
    }
}

/// Encode a payload using GCF with session deduplication.
/// Symbols that were already transmitted in prior responses are emitted as
/// bare references (`@N  # previously transmitted`) instead of full declarations.
/// After encoding, newly-sent symbols are recorded in the session.
public func encodeWithSession(_ payload: Payload, session: Session?) -> String {
    guard let session = session else {
        return encode(payload)
    }

    var b = ""

    // Header with session=true marker.
    b += "GCF tool=\(payload.tool) budget=\(payload.tokenBudget) tokens=\(payload.tokensUsed) symbols=\(payload.symbols.count) session=true"
    if !payload.packRoot.isEmpty {
        b += " pack_root=\(payload.packRoot)"
    }
    b += "\n"

    // Build local ID mapping for this response.
    var localIndex: [String: Int] = [:]
    for (i, s) in payload.symbols.enumerated() {
        localIndex[s.qualifiedName] = i
    }

    // Group by distance.
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
            let idx = localIndex[s.qualifiedName]!
            if session.transmitted(s.qualifiedName) {
                // Bare reference: symbol was sent in a prior response.
                b += "@\(idx)  # previously transmitted\n"
            } else {
                // Full declaration.
                let kind = kindAbbrev[s.kind] ?? s.kind
                b += "@\(idx) \(kind) \(s.qualifiedName) \(String(format: "%.2f", s.score)) \(s.provenance)\n"
            }
        }
    }

    // Edges section.
    if !payload.edges.isEmpty {
        b += "## edges\n"
        for e in payload.edges {
            guard let srcIdx = localIndex[e.source],
                  let tgtIdx = localIndex[e.target] else { continue }
            var line = "@\(tgtIdx)<@\(srcIdx) \(e.edgeType)"
            if !e.status.isEmpty && e.status != "unchanged" {
                line += " \(e.status)"
            }
            b += line + "\n"
        }
    }

    // Record all new symbols in the session.
    var newSymbols: [Symbol] = []
    for s in payload.symbols {
        if !session.transmitted(s.qualifiedName) {
            newSymbols.append(s)
        }
    }
    session.record(newSymbols)

    return b
}
