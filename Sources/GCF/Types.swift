/// Symbol represents a node in a GCF payload.
public struct Symbol: Codable, Equatable {
    /// Fully qualified identifier (e.g., "pkg/auth.Middleware").
    public var qualifiedName: String
    /// Node type: "function", "type", "method", etc.
    public var kind: String
    /// Relevance score (0.0 to 1.0).
    public var score: Double
    /// Discovery method: "lsp_resolved", "ast_inferred", etc.
    public var provenance: String
    /// Hops from query center (0=target, 1=related, 2+=extended).
    public var distance: Int
    /// Optional function/method signature.
    public var signature: String
    /// Optional score breakdown.
    public var components: Components

    public init(
        qualifiedName: String,
        kind: String = "",
        score: Double = 0.0,
        provenance: String = "",
        distance: Int = 0,
        signature: String = "",
        components: Components = Components()
    ) {
        self.qualifiedName = qualifiedName
        self.kind = kind
        self.score = score
        self.provenance = provenance
        self.distance = distance
        self.signature = signature
        self.components = components
    }
}

/// Components holds the score breakdown for a symbol.
public struct Components: Codable, Equatable {
    /// Number of callers (normalized).
    public var blastRadius: Double
    /// Edge provenance confidence.
    public var confidence: Double
    /// Git recency signal.
    public var recency: Double
    /// Graph distance penalty.
    public var distance: Double

    public init(
        blastRadius: Double = 0.0,
        confidence: Double = 0.0,
        recency: Double = 0.0,
        distance: Double = 0.0
    ) {
        self.blastRadius = blastRadius
        self.confidence = confidence
        self.recency = recency
        self.distance = distance
    }
}

/// Edge represents a directed relationship in a GCF payload.
public struct Edge: Codable, Equatable {
    /// Qualified name of source symbol.
    public var source: String
    /// Qualified name of target symbol.
    public var target: String
    /// Edge type (e.g., "calls", "implements").
    public var edgeType: String
    /// Optional: "added", "removed", "unchanged" (for diff responses).
    public var status: String

    public init(
        source: String,
        target: String,
        edgeType: String,
        status: String = ""
    ) {
        self.source = source
        self.target = target
        self.edgeType = edgeType
        self.status = status
    }
}

/// Payload is the input/output structure for GCF encoding/decoding.
public struct Payload: Codable, Equatable {
    /// Producing tool name (e.g., "context_for_task").
    public var tool: String
    /// Actual tokens consumed by this payload.
    public var tokensUsed: Int
    /// Token budget requested by the consumer.
    public var tokenBudget: Int
    /// Content-addressed identity (hex SHA-256), enables delta encoding.
    public var packRoot: String
    /// Symbols ordered by score descending within each distance group.
    public var symbols: [Symbol]
    /// Directed relationships between symbols.
    public var edges: [Edge]

    public init(
        tool: String,
        tokensUsed: Int = 0,
        tokenBudget: Int = 0,
        packRoot: String = "",
        symbols: [Symbol] = [],
        edges: [Edge] = []
    ) {
        self.tool = tool
        self.tokensUsed = tokensUsed
        self.tokenBudget = tokenBudget
        self.packRoot = packRoot
        self.symbols = symbols
        self.edges = edges
    }
}

/// DeltaPayload represents the diff between a prior context pack and the
/// current result. Used for incremental context delivery.
public struct DeltaPayload: Codable, Equatable {
    public var tool: String
    /// pack_root the consumer has.
    public var baseRoot: String
    /// pack_root of the current result.
    public var newRoot: String
    public var removed: [Symbol]
    public var added: [Symbol]
    public var removedEdges: [Edge]
    public var addedEdges: [Edge]
    public var deltaTokens: Int
    public var fullTokens: Int

    public init(
        tool: String,
        baseRoot: String,
        newRoot: String,
        removed: [Symbol] = [],
        added: [Symbol] = [],
        removedEdges: [Edge] = [],
        addedEdges: [Edge] = [],
        deltaTokens: Int = 0,
        fullTokens: Int = 0
    ) {
        self.tool = tool
        self.baseRoot = baseRoot
        self.newRoot = newRoot
        self.removed = removed
        self.added = added
        self.removedEdges = removedEdges
        self.addedEdges = addedEdges
        self.deltaTokens = deltaTokens
        self.fullTokens = fullTokens
    }
}
