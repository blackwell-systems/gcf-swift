import Foundation
import GCF

var passed = 0
var failed = 0
var testErrors: [String] = []

func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        let msg = "FAIL: \(message) (\(file):\(line))"
        testErrors.append(msg)
        print("  \(msg)")
    }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, file: String = #file, line: Int = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        let msg = "FAIL: \(message): got '\(a)', expected '\(b)' (\(file):\(line))"
        testErrors.append(msg)
        print("  \(msg)")
    }
}

func section(_ name: String) { print("--- \(name) ---") }

// Encode
section("Encode Basic")
let encP = Payload(
    tool: "context_for_task", tokensUsed: 1847, tokenBudget: 5000,
    symbols: [
        Symbol(qualifiedName: "pkg.AuthMiddleware", kind: "function", score: 0.78, provenance: "lsp_resolved", distance: 0),
        Symbol(qualifiedName: "pkg.NewServer", kind: "function", score: 0.54, provenance: "lsp_resolved", distance: 1),
    ],
    edges: [Edge(source: "pkg.NewServer", target: "pkg.AuthMiddleware", edgeType: "calls")]
)
let encOut = encode(encP)
check(encOut.contains("@0 fn pkg.AuthMiddleware 0.78 lsp_resolved"), "symbol 0")
check(encOut.contains("@0<@1 calls"), "edge")
check(encode(Payload(tool: "test", symbols: [
    Symbol(qualifiedName: "a.B", kind: "function", score: 1.0, provenance: "x", distance: 0),
])).contains("1.00"), "score 1.00")

// Decode
section("Decode")
let decP = try decode("GCF tool=test budget=5000 tokens=1847 symbols=2\n## targets\n@0 fn pkg.A 0.78 lsp\n## related\n@1 fn pkg.B 0.54 lsp\n## edges\n@0<@1 calls")
checkEqual(decP.symbols.count, 2, "symbol count")
checkEqual(decP.symbols[0].kind, "function", "kind expanded")

// Decode errors
var threw1 = false; do { _ = try decode("NOTGCF tool=test") } catch { threw1 = true }
check(threw1, "reject missing prefix")
var threw2 = false; do { _ = try decode("GCF budget=100") } catch { threw2 = true }
check(threw2, "reject missing tool")
var threw3 = false; do { _ = try decode("GCF tool=t\n## targets\n@0 fn a 0.5") } catch { threw3 = true }
check(threw3, "reject < 5 fields")
var threw4 = false; do { _ = try decode("GCF tool=t\n## targets\n@0 fn a 0.5 x\n## edges\n@5<@0 calls") } catch { threw4 = true }
check(threw4, "reject unknown edge")
var threw5 = false; do { _ = try decode("") } catch { threw5 = true }
check(threw5, "reject empty")

// Roundtrip
section("Roundtrip")
let rtOrig = Payload(tool: "test", tokensUsed: 500, tokenBudget: 2000, packRoot: "deadbeef",
    symbols: [Symbol(qualifiedName: "pkg.Foo", kind: "function", score: 0.95, provenance: "lsp", distance: 0)],
    edges: [])
let rtDec = try decode(encode(rtOrig))
checkEqual(rtDec.tool, rtOrig.tool, "rt tool")
checkEqual(rtDec.packRoot, rtOrig.packRoot, "rt packRoot")

// Session
section("Session")
let sess = Session()
let sp1 = Payload(tool: "test", symbols: [
    Symbol(qualifiedName: "a.Foo", kind: "function", score: 0.9, provenance: "lsp", distance: 0),
])
let so1 = encodeWithSession(sp1, session: sess)
check(so1.contains("session=true"), "session=true")
check(so1.contains("fn a.Foo"), "full decl")
checkEqual(sess.size, 1, "session size 1")

let sp2 = Payload(tool: "test", symbols: [
    Symbol(qualifiedName: "a.Foo", kind: "function", score: 0.9, provenance: "lsp", distance: 0),
    Symbol(qualifiedName: "a.Bar", kind: "type", score: 0.8, provenance: "lsp", distance: 0),
])
let so2 = encodeWithSession(sp2, session: sess)
check(so2.contains("previously transmitted"), "bare ref")
check(so2.contains("type a.Bar"), "new decl")
checkEqual(sess.size, 2, "session size 2")

// Session nil passthrough
let nilOut = encodeWithSession(Payload(tool: "test", symbols: [
    Symbol(qualifiedName: "x.Y", kind: "type", score: 0.5, provenance: "z", distance: 0),
]), session: nil)
check(!nilOut.contains("session=true"), "no session when nil")

// Session reset
let rs = Session()
_ = encodeWithSession(Payload(tool: "test", symbols: [
    Symbol(qualifiedName: "a.B", kind: "fn", score: 0.5, provenance: "x", distance: 0),
]), session: rs)
checkEqual(rs.size, 1, "before reset")
rs.reset()
checkEqual(rs.size, 0, "after reset")

// Thread safety
section("Session Thread Safety")
let ts = Session()
let grp = DispatchGroup()
for i in 0..<10 {
    grp.enter()
    DispatchQueue.global().async {
        _ = encodeWithSession(Payload(tool: "t", symbols: [
            Symbol(qualifiedName: "s.\(i)", kind: "function", score: 0.1, provenance: "l", distance: 0),
        ]), session: ts)
        grp.leave()
    }
}
grp.wait()
checkEqual(ts.size, 10, "concurrent 10")

// Delta
section("Delta")
let d1 = encodeDelta(DeltaPayload(
    tool: "test", baseRoot: "aaa", newRoot: "bbb",
    removed: [Symbol(qualifiedName: "pkg.Old", kind: "function")],
    added: [Symbol(qualifiedName: "pkg.New", kind: "function", score: 0.85, provenance: "rwr")],
    deltaTokens: 30, fullTokens: 200
))
check(d1.contains("delta=true"), "delta header")
check(d1.contains("savings=85%"), "savings")
check(d1.contains("fn pkg.Old"), "removed")
check(d1.contains("@0 fn pkg.New 0.85 rwr"), "added")

// Generic
section("Generic")
checkEqual(encodeGeneric(42), "42", "int")
checkEqual(encodeGeneric("hello"), "hello", "string")
checkEqual(encodeGeneric(true), "true", "true")
checkEqual(encodeGeneric(false), "false", "false")
checkEqual(encodeGeneric(nil), "", "nil")

let gTab = encodeGeneric(["employees": [
    ["department": "Engineering", "id": 1, "name": "Alice", "salary": 95000],
    ["department": "Sales", "id": 2, "name": "Bob", "salary": 72000],
] as [[String: Any]]] as [String: Any])
check(gTab.contains("## employees [2]{department,id,name,salary}"), "tabular header")
check(gTab.contains("Engineering|1|Alice|95000"), "tab row 0")
check(gTab.contains("Sales|2|Bob|72000"), "tab row 1")

let gNest = encodeGeneric(["config": ["debug": true, "level": 5] as [String: Any], "name": "test"] as [String: Any])
check(gNest.contains("name=test"), "name=test")
check(gNest.contains("## config"), "## config")

let gNull = encodeGeneric(["items": [["a": 1, "b": NSNull()], ["a": 2, "b": 3]] as [[String: Any]]] as [String: Any])
check(gNull.contains("1|-"), "null dash")
check(gNull.contains("2|3"), "non-null row")

let gPipe = encodeGeneric(["val": "a|b"] as [String: Any])
check(gPipe.contains("val=\"a|b\""), "pipe quoted")

let gES = encodeGeneric(["val": ""] as [String: Any])
check(gES.contains("val=\"\""), "empty string")

let gArr = encodeGeneric([["id": 1, "name": "x"], ["id": 2, "name": "y"]] as [[String: Any]])
check(gArr.contains("## root [2]{"), "root array")

let gNU = encodeGeneric(["items": [1, "two", true] as [Any]] as [String: Any])
check(gNU.contains("## items [3]"), "non-uniform")
check(gNU.contains("@0 1"), "item 0")

let gQP = encodeGeneric(["val": "say \"hello|world\""] as [String: Any])
check(gQP.contains("val=\"say \\\"hello|world\\\"\""), "escaped quotes")

let gNA = encodeGeneric(["users": [
    ["name": "Alice", "tags": ["admin", "user"] as [Any]] as [String: Any],
    ["name": "Bob", "tags": ["user"] as [Any]] as [String: Any],
] as [[String: Any]]] as [String: Any])
check(gNA.contains("@0 Alice"), "@0 Alice")
check(gNA.contains("@1 Bob"), "@1 Bob")
check(gNA.contains("## tags"), "tags")

checkEqual(encodeGeneric([] as [Any]), "", "empty array")
checkEqual(encodeGeneric([:] as [String: Any]), "", "empty dict")

// Kind Maps
section("Kind Maps")
checkEqual(kindAbbrev["function"]!, "fn", "fn")
checkEqual(kindAbbrev["interface"]!, "iface", "iface")
checkEqual(kindExpand["fn"]!, "function", "fn->function")
checkEqual(kindExpand["iface"]!, "interface", "iface->interface")
for (full, abbrev) in kindAbbrev {
    checkEqual(kindExpand[abbrev]!, full, "expand[\(abbrev)]")
}

// Summary
print("\n========================================")
print("Results: \(passed) passed, \(failed) failed")
if !testErrors.isEmpty {
    for e in testErrors { print("  - \(e)") }
}
print("========================================")
if failed > 0 { exit(1) }
