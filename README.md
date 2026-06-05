<p align="center">
  <a href="https://github.com/blackwell-systems"><img src="https://raw.githubusercontent.com/blackwell-systems/blackwell-docs-theme/main/badge-trademark.svg" alt="Blackwell Systems"></a>
  <a href="https://github.com/blackwell-systems/gcf-swift/actions"><img src="https://github.com/blackwell-systems/gcf-swift/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
</p>

# gcf-swift

Swift implementation of [GCF (Graph Compact Format)](https://gcformat.com/) -- the most token-efficient wire format for LLMs. A drop-in alternative to JSON and TOON for any structured data.

**79% fewer input tokens than JSON. 75% fewer output tokens. 52% smaller than TOON. 100% LLM comprehension at 500 symbols, where JSON fails at 66.7%.**

Docs: [gcformat.com](https://gcformat.com/) · [Playground](https://gcformat.com/playground.html) · [GCF vs TOON](https://gcformat.com/guide/vs-toon.html)

## Install

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/blackwell-systems/gcf-swift.git", from: "0.1.0"),
]
```

Then add `"GCF"` to your target's dependencies:

```swift
.target(name: "MyApp", dependencies: ["GCF"]),
```

Zero dependencies. Single module. Supports macOS 12+ and iOS 15+. Don't want to change code? Use the [MCP proxy](https://github.com/blackwell-systems/gcf-proxy) for zero-code adoption.

## Quick Start

```swift
import GCF

let p = Payload(
    tool: "context_for_task",
    tokensUsed: 1847,
    tokenBudget: 5000,
    symbols: [
        Symbol(qualifiedName: "pkg.AuthMiddleware", kind: "function", score: 0.78, provenance: "lsp_resolved", distance: 0),
        Symbol(qualifiedName: "pkg.NewServer", kind: "function", score: 0.54, provenance: "lsp_resolved", distance: 1),
    ],
    edges: [
        Edge(source: "pkg.NewServer", target: "pkg.AuthMiddleware", edgeType: "calls"),
    ]
)

let output = encode(p)
```

Output:
```
GCF tool=context_for_task budget=5000 tokens=1847 symbols=2
## targets
@0 fn pkg.AuthMiddleware 0.78 lsp_resolved
## related
@1 fn pkg.NewServer 0.54 lsp_resolved
## edges
@0<@1 calls
```

## Decode

```swift
let p = try decode(input)
print(p.tool, p.symbols.count, "symbols", p.edges.count, "edges")
```

## Session Deduplication

Track transmitted symbols across multiple tool responses. Previously-sent symbols become bare references instead of full declarations:

```swift
let session = Session()

let out1 = encodeWithSession(payload1, session: session) // full declarations
let out2 = encodeWithSession(payload2, session: session) // reused symbols as "@N  # previously transmitted"
```

By the 5th call in a session: 92.7% token savings vs JSON.

## Delta Encoding

When the consumer already has a prior context pack, send only what changed:

```swift
let delta = DeltaPayload(
    tool: "context_for_task",
    baseRoot: "aaa111",
    newRoot: "bbb222",
    removed: [Symbol(qualifiedName: "pkg.OldFunc", kind: "function")],
    added: [Symbol(qualifiedName: "pkg.NewFunc", kind: "function", score: 0.85, provenance: "rwr")],
    deltaTokens: 30,
    fullTokens: 200
)

let output = encodeDelta(delta)
```

81.2% savings on re-queries where the pack changed slightly.

## Generic Encoding

Encode any Swift value (not just graph payloads) into GCF tabular format:

```swift
let data: [String: Any] = [
    "employees": [
        ["id": 1, "name": "Alice", "department": "Engineering", "salary": 95000],
        ["id": 2, "name": "Bob", "department": "Sales", "salary": 72000],
    ] as [[String: Any]]
]
let output = encodeGeneric(data)
```

Output:
```
## employees [2]{department,id,name,salary}
Engineering|1|Alice|95000
Sales|2|Bob|72000
```

Works on dictionaries, arrays, and primitives. Arrays of uniform objects get tabular rows. Nested objects use `## key` section headers.

## API

| Function | Description |
|----------|-------------|
| `encode(_ payload: Payload) -> String` | Encode a graph payload to GCF text |
| `encodeGeneric(_ data: Any?) -> String` | Encode any value to GCF tabular format |
| `decode(_ input: String) throws -> Payload` | Parse GCF text back to a Payload |
| `encodeWithSession(_ payload: Payload, session: Session?) -> String` | Encode with session deduplication |
| `encodeDelta(_ delta: DeltaPayload) -> String` | Encode a delta (added/removed only) |
| `Session()` | Create a new session tracker (thread-safe) |

## Types

| Type | Purpose |
|------|---------|
| `Payload` | Full GCF payload: tool, budget, symbols, edges, pack root |
| `Symbol` | Graph node: qualified name, kind, score, provenance, distance |
| `Edge` | Directed relationship: source, target, edge type |
| `DeltaPayload` | Diff between two packs: added/removed symbols and edges |
| `Session` | Thread-safe tracker for multi-call deduplication |
| `kindAbbrev` / `kindExpand` | Bidirectional kind abbreviation maps |

## Links

- [Documentation](https://gcformat.com/)
- [Playground](https://gcformat.com/playground.html)
- [Specification](https://github.com/blackwell-systems/gcf)
- [Go library](https://github.com/blackwell-systems/gcf-go)
- [TypeScript library](https://github.com/blackwell-systems/gcf-typescript)
- [Rust library](https://github.com/blackwell-systems/gcf-rust)
- [Python library](https://github.com/blackwell-systems/gcf-python)
- [MCP Proxy](https://github.com/blackwell-systems/gcf-proxy) (zero-code adoption)
- [GCF vs TOON](https://gcformat.com/guide/vs-toon.html)

## License

MIT
