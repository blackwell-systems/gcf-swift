import Foundation

/// Options for the streaming encoder.
public struct StreamOptions {
    public var tokenBudget: Int
    public var tokensUsed: Int
    public var packRoot: String
    public var session: Bool

    public init(tokenBudget: Int = 0, tokensUsed: Int = 0, packRoot: String = "", session: Bool = false) {
        self.tokenBudget = tokenBudget
        self.tokensUsed = tokensUsed
        self.packRoot = packRoot
        self.session = session
    }
}

/// Protocol for streaming output. Any object that can receive string chunks.
public protocol StreamWriter {
    func write(_ string: String)
}

/// StreamEncoder writes GCF output incrementally as symbols and edges arrive.
/// Zero buffering: each symbol/edge is written immediately. A trailer summary
/// is emitted on close() with the final counts. Thread-safe via NSLock.
public class StreamEncoder {
    private let writer: StreamWriter
    private let lock = NSLock()
    private var symIndex: [String: Int] = [:]
    private var nextID = 0
    private var currentGroup = ""
    private var groupCounts: [(String, Int)] = []
    private var edgeCount = 0
    private var edgesStarted = false

    public init(writer: StreamWriter, tool: String, options: StreamOptions = StreamOptions()) {
        self.writer = writer

        var parts = ["GCF profile=graph tool=\(tool)"]
        if options.tokenBudget > 0 { parts.append("budget=\(options.tokenBudget)") }
        if options.tokensUsed > 0 { parts.append("tokens=\(options.tokensUsed)") }
        if !options.packRoot.isEmpty { parts.append("pack_root=\(options.packRoot)") }
        if options.session { parts.append("session=true") }
        writer.write(parts.joined(separator: " ") + "\n")
    }

    /// Emit a symbol line immediately. Group headers are auto-managed.
    public func writeSymbol(_ s: Symbol) {
        lock.lock()
        defer { lock.unlock() }

        let groupNames = ["targets", "related", "extended"]
        let groupName = s.distance < groupNames.count ? groupNames[s.distance] : "distance_\(s.distance)"

        if groupName != currentGroup {
            writer.write("## \(groupName)\n")
            currentGroup = groupName
        }

        let id = nextID
        symIndex[s.qualifiedName] = id
        nextID += 1

        let kind = kindAbbrev[s.kind] ?? s.kind
        writer.write("@\(id) \(kind) \(s.qualifiedName) \(String(format: "%.2f", s.score)) \(s.provenance)\n")

        if let idx = groupCounts.firstIndex(where: { $0.0 == groupName }) {
            groupCounts[idx].1 += 1
        } else {
            groupCounts.append((groupName, 1))
        }
    }

    /// Emit an edge line immediately. Edges section header auto-emitted on first edge.
    public func writeEdge(_ e: Edge) {
        lock.lock()
        defer { lock.unlock() }

        guard let srcIdx = symIndex[e.source], let tgtIdx = symIndex[e.target] else { return }

        if !edgesStarted {
            writer.write("## edges [?]\n")
            edgesStarted = true
        }

        var line = "@\(tgtIdx)<@\(srcIdx) \(e.edgeType)"
        if !e.status.isEmpty && e.status != "unchanged" {
            line += " \(e.status)"
        }
        writer.write(line + "\n")
        edgeCount += 1
    }

    /// Emit a bare reference (session mode).
    public func writeBareRef(_ qname: String, distance: Int) {
        lock.lock()
        defer { lock.unlock() }

        let groupNames = ["targets", "related", "extended"]
        let groupName = distance < groupNames.count ? groupNames[distance] : "distance_\(distance)"

        if groupName != currentGroup {
            writer.write("## \(groupName)\n")
            currentGroup = groupName
        }

        let id = nextID
        symIndex[qname] = id
        nextID += 1
        writer.write("@\(id)  # previously transmitted\n")

        if let idx = groupCounts.firstIndex(where: { $0.0 == groupName }) {
            groupCounts[idx].1 += 1
        } else {
            groupCounts.append((groupName, 1))
        }
    }

    /// Emit ##! summary trailer with final counts.
    public func close() {
        lock.lock()
        defer { lock.unlock() }

        var counts: [String] = groupCounts.filter { $0.1 > 0 }.map { String($0.1) }
        if edgeCount > 0 {
            counts.append(String(edgeCount))
        }
        writer.write("##! summary symbols=\(nextID) edges=\(edgeCount) counts=\(counts.joined(separator: ","))\n")
    }

    /// Number of symbols written so far.
    public var symbolCount: Int { nextID }

    /// Number of edges written so far.
    public var edgeCountValue: Int { edgeCount }
}
