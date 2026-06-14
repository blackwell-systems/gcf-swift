import XCTest
@testable import GCF

final class GCFTests: XCTestCase {

    // MARK: - Encode

    func testEncodeBasic() {
        let p = Payload(
            tool: "context_for_task", tokensUsed: 1847, tokenBudget: 5000,
            symbols: [
                Symbol(qualifiedName: "pkg.AuthMiddleware", kind: "function", score: 0.78, provenance: "lsp_resolved", distance: 0),
                Symbol(qualifiedName: "pkg.NewServer", kind: "function", score: 0.54, provenance: "lsp_resolved", distance: 1),
            ],
            edges: [Edge(source: "pkg.NewServer", target: "pkg.AuthMiddleware", edgeType: "calls")]
        )
        let output = encode(p)
        XCTAssertTrue(output.hasPrefix("GCF profile=graph tool=context_for_task budget=5000 tokens=1847 symbols=2"))
        XCTAssertTrue(output.contains("## targets"))
        XCTAssertTrue(output.contains("@0 fn pkg.AuthMiddleware 0.78 lsp_resolved"))
        XCTAssertTrue(output.contains("## related"))
        XCTAssertTrue(output.contains("@1 fn pkg.NewServer 0.54 lsp_resolved"))
        XCTAssertTrue(output.contains("## edges"))
        XCTAssertTrue(output.contains("@0<@1 calls"))
    }

    func testEncodeScoreFormat() {
        let p = Payload(tool: "test", symbols: [
            Symbol(qualifiedName: "a.B", kind: "function", score: 1.0, provenance: "x", distance: 0),
            Symbol(qualifiedName: "c.D", kind: "type", score: 0.5, provenance: "y", distance: 0),
        ])
        let output = encode(p)
        XCTAssertTrue(output.contains("1.00"))
        XCTAssertTrue(output.contains("0.50"))
    }

    func testEncodeKindAbbreviations() {
        let p = Payload(tool: "test", symbols: [
            Symbol(qualifiedName: "a.B", kind: "interface", score: 0.5, provenance: "x", distance: 0),
            Symbol(qualifiedName: "c.D", kind: "route_handler", score: 0.4, provenance: "x", distance: 0),
            Symbol(qualifiedName: "e.F", kind: "external", score: 0.3, provenance: "x", distance: 0),
        ])
        let output = encode(p)
        XCTAssertTrue(output.contains("iface a.B"))
        XCTAssertTrue(output.contains("route c.D"))
        XCTAssertTrue(output.contains("ext e.F"))
    }

    func testEncodeDistanceGroups() {
        let p = Payload(tool: "test", symbols: [
            Symbol(qualifiedName: "a", kind: "fn", score: 0.9, provenance: "x", distance: 0),
            Symbol(qualifiedName: "b", kind: "fn", score: 0.8, provenance: "x", distance: 1),
            Symbol(qualifiedName: "c", kind: "fn", score: 0.7, provenance: "x", distance: 2),
            Symbol(qualifiedName: "d", kind: "fn", score: 0.6, provenance: "x", distance: 5),
        ])
        let output = encode(p)
        XCTAssertTrue(output.contains("## targets"))
        XCTAssertTrue(output.contains("## related"))
        XCTAssertTrue(output.contains("## extended"))
        XCTAssertTrue(output.contains("## distance_5"))
    }

    // MARK: - Decode

    func testDecodeBasic() throws {
        let input = "GCF tool=context_for_task budget=5000 tokens=1847 symbols=2\n## targets\n@0 fn pkg.AuthMiddleware 0.78 lsp_resolved\n## related\n@1 fn pkg.NewServer 0.54 lsp_resolved\n## edges\n@0<@1 calls"
        let p = try decode(input)
        XCTAssertEqual(p.tool, "context_for_task")
        XCTAssertEqual(p.tokenBudget, 5000)
        XCTAssertEqual(p.symbols.count, 2)
        XCTAssertEqual(p.symbols[0].kind, "function")
        XCTAssertEqual(p.edges.count, 1)
        XCTAssertEqual(p.edges[0].source, "pkg.NewServer")
    }

    func testDecodeKindExpansion() throws {
        let input = "GCF tool=test budget=0 tokens=0 symbols=3\n## targets\n@0 iface a.B 0.50 x\n@1 route c.D 0.40 x\n@2 ext e.F 0.30 x"
        let p = try decode(input)
        XCTAssertEqual(p.symbols[0].kind, "interface")
        XCTAssertEqual(p.symbols[1].kind, "route_handler")
        XCTAssertEqual(p.symbols[2].kind, "external")
    }

    func testDecodeToleratesCarriageReturn() throws {
        let input = "GCF tool=test budget=0 tokens=0 symbols=1\r\n## targets\r\n@0 fn a.B 0.50 x\r\n"
        let p = try decode(input)
        XCTAssertEqual(p.symbols.count, 1)
    }

    func testDecodeErrors() throws {
        XCTAssertThrowsError(try decode("NOTGCF tool=test"))
        // v3.1: tool field is optional, so missing tool should succeed
        let noTool = try decode("GCF profile=graph budget=100 tokens=50 symbols=0")
        XCTAssertEqual(noTool.tool, "")
        XCTAssertThrowsError(try decode("GCF tool=test budget=0 tokens=0 symbols=1\n## targets\n@0 fn a.B 0.50"))
        XCTAssertThrowsError(try decode("GCF tool=test budget=0 tokens=0 symbols=1\n## targets\n@0 fn a.B 0.50 x\n## edges\n@5<@0 calls"))
        XCTAssertThrowsError(try decode(""))
    }

    // MARK: - Roundtrip

    func testRoundtrip() throws {
        let original = Payload(
            tool: "context_for_task", tokensUsed: 500, tokenBudget: 2000, packRoot: "deadbeef",
            symbols: [
                Symbol(qualifiedName: "pkg.Foo", kind: "function", score: 0.95, provenance: "lsp_resolved", distance: 0),
                Symbol(qualifiedName: "pkg.Bar", kind: "type", score: 0.80, provenance: "ast_inferred", distance: 1),
            ],
            edges: [Edge(source: "pkg.Foo", target: "pkg.Bar", edgeType: "calls")]
        )
        let decoded = try decode(encode(original))
        XCTAssertEqual(decoded.tool, original.tool)
        XCTAssertEqual(decoded.tokenBudget, original.tokenBudget)
        XCTAssertEqual(decoded.packRoot, original.packRoot)
        XCTAssertEqual(decoded.symbols.count, original.symbols.count)
        XCTAssertEqual(decoded.edges.count, original.edges.count)
    }

    // MARK: - Session

    func testSessionDedup() {
        let session = Session()
        let p1 = Payload(tool: "test", symbols: [
            Symbol(qualifiedName: "a.Foo", kind: "function", score: 0.9, provenance: "lsp", distance: 0),
        ])
        let out1 = encodeWithSession(p1, session: session)
        XCTAssertTrue(out1.contains("session=true"))
        XCTAssertTrue(out1.contains("fn a.Foo"))
        XCTAssertFalse(out1.contains("previously transmitted"))

        let p2 = Payload(tool: "test", symbols: [
            Symbol(qualifiedName: "a.Foo", kind: "function", score: 0.9, provenance: "lsp", distance: 0),
            Symbol(qualifiedName: "a.Bar", kind: "type", score: 0.8, provenance: "lsp", distance: 0),
        ])
        let out2 = encodeWithSession(p2, session: session)
        XCTAssertTrue(out2.contains("previously transmitted"))
        XCTAssertTrue(out2.contains("type a.Bar"))
        XCTAssertEqual(session.size, 2)
    }

    func testSessionReset() {
        let session = Session()
        _ = encodeWithSession(Payload(tool: "test", symbols: [
            Symbol(qualifiedName: "a.B", kind: "fn", score: 0.5, provenance: "x", distance: 0),
        ]), session: session)
        XCTAssertEqual(session.size, 1)
        session.reset()
        XCTAssertEqual(session.size, 0)
    }

    // MARK: - Delta

    func testEncodeDelta() {
        let output = encodeDelta(DeltaPayload(
            tool: "test", baseRoot: "aaa", newRoot: "bbb",
            removed: [Symbol(qualifiedName: "pkg.Old", kind: "function")],
            added: [Symbol(qualifiedName: "pkg.New", kind: "function", score: 0.85, provenance: "rwr")],
            deltaTokens: 30, fullTokens: 200
        ))
        XCTAssertTrue(output.contains("delta=true"))
        XCTAssertTrue(output.contains("savings=85%"))
        XCTAssertTrue(output.contains("fn pkg.Old"))
        XCTAssertTrue(output.contains("@0 fn pkg.New 0.85 rwr"))
    }

    // MARK: - Generic

    func testGenericTabular() {
        let output = encodeGeneric(["employees": [
            ["department": "Engineering", "id": 1, "name": "Alice", "salary": 95000],
            ["department": "Sales", "id": 2, "name": "Bob", "salary": 72000],
        ] as [[String: Any]]] as [String: Any])
        XCTAssertTrue(output.contains("## employees [2]{department,id,name,salary}"))
        XCTAssertTrue(output.contains("Engineering|1|Alice|95000"))
    }

    func testGenericPrimitive() {
        XCTAssertTrue(encodeGeneric(42).contains("=42"))
        XCTAssertTrue(encodeGeneric("hello").contains("=hello"))
        XCTAssertTrue(encodeGeneric(true).contains("=true"))
        XCTAssertTrue(encodeGeneric(false).contains("=false"))
        XCTAssertTrue(encodeGeneric(nil).contains("=-"))
    }

    func testGenericStringWithPipe() {
        let output = encodeGeneric(["val": "a|b"] as [String: Any])
        XCTAssertTrue(output.contains("val=\"a|b\""))
    }

    // MARK: - Kind Maps

    func testKindMapsAreInverses() {
        for (full, abbrev) in kindAbbrev {
            XCTAssertEqual(kindExpand[abbrev], full)
        }
        for (abbrev, full) in kindExpand {
            XCTAssertEqual(kindAbbrev[full], abbrev)
        }
    }
}
