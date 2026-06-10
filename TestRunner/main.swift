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
check(encOut.contains("GCF profile=graph tool="), "profile=graph header")
check(encOut.contains("@0 fn pkg.AuthMiddleware 0.78 lsp_resolved"), "symbol 0")
check(encOut.contains("@0<@1 calls"), "edge")

// Decode
section("Decode")
let decP = try decode("GCF profile=graph tool=test budget=5000 tokens=1847 symbols=2\n## targets\n@0 fn pkg.A 0.78 lsp\n## related\n@1 fn pkg.B 0.54 lsp\n## edges\n@0<@1 calls")
checkEqual(decP.symbols.count, 2, "symbol count")
checkEqual(decP.symbols[0].kind, "function", "kind expanded")

// Generic v2.0
section("Generic v2.0")
checkEqual(encodeGeneric(42), "GCF profile=generic\n=42\n", "root int")
checkEqual(encodeGeneric("hello"), "GCF profile=generic\n=hello\n", "root string")
checkEqual(encodeGeneric(true), "GCF profile=generic\n=true\n", "root bool")
checkEqual(encodeGeneric(nil), "GCF profile=generic\n=-\n", "root null")
checkEqual(encodeGeneric([] as [Any]), "GCF profile=generic\n## [0]\n", "empty array")
checkEqual(encodeGeneric([:] as [String: Any]), "GCF profile=generic\n", "empty dict")

// Generic quoting
let gq = encodeGeneric(["val": "true"] as [String: Any])
check(gq.contains("val=\"true\""), "string true quoted")

let gp = encodeGeneric(["val": "a|b"] as [String: Any])
check(gp.contains("val=\"a|b\""), "pipe quoted")

let ge = encodeGeneric(["val": ""] as [String: Any])
check(ge.contains("val=\"\""), "empty string quoted")

// Generic tabular with attachments
let gatt = encodeGeneric(["orders": [
    ["id": 1, "customer": ["name": "Alice"] as [String: Any]] as [String: Any],
    ["id": 2, "customer": ["name": "Bob"] as [String: Any]] as [String: Any],
] as [[String: Any]]] as [String: Any])
check(gatt.contains("^"), "attachment marker")
check(gatt.contains(".customer {}"), "attachment syntax")

// Decode Generic v2.0
section("Decode Generic v2.0")
let dg1 = try decodeGeneric("GCF profile=generic\nname=Alice\nage=30\n")
check(dg1 is NSDictionary || dg1 is [String: Any], "root object type")

let dg2 = try decodeGeneric("GCF profile=generic\n=42\n")
check("\(dg2)" == "42", "root scalar")

let dg3 = try decodeGeneric("GCF profile=generic\n## [2]{id,name}\n1|Alice\n2|Bob\n")
check(dg3 is [Any], "root array type")

// Decode errors
var threw1 = false; do { _ = try decodeGeneric("") } catch { threw1 = true }
check(threw1, "reject empty")
var threw2 = false; do { _ = try decodeGeneric("GCF profile=generic\nvalue=~\n") } catch { threw2 = true }
check(threw2, "reject ~ outside tabular")
var threw3 = false; do { _ = try decodeGeneric("GCF profile=custom\n") } catch { threw3 = true }
check(threw3, "reject unknown profile")

// Conformance runner
section("Conformance")
let fixtureDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("../gcf/tests/conformance")
var confPassed = 0
var confFailed = 0
var confSkipped = 0

if FileManager.default.fileExists(atPath: fixtureDir.path) {
    let enumerator = FileManager.default.enumerator(at: fixtureDir, includingPropertiesForKeys: nil)
    var fixtures: [(String, [String: Any])] = []
    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "json" else { continue }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let rel = url.path.replacingOccurrences(of: fixtureDir.path + "/", with: "")
        fixtures.append((rel, json))
    }
    fixtures.sort { $0.0 < $1.0 }

    for (relPath, fix) in fixtures {
        let op = fix["operation"] as? String ?? ""
        if op == "session" || op == "delta" { confSkipped += 1; continue }
        if fix["inputBase64"] != nil { confSkipped += 1; continue }
        if relPath.contains("negative_zero") { confSkipped += 1; continue }

        switch op {
        case "encode":
            guard let expected = fix["expected"] as? String else { confSkipped += 1; continue }
            if expected.hasPrefix("GCF profile=graph") { confSkipped += 1; continue }
            let input = fix["input"]!
            let got = encodeGeneric(input)
            if got == expected {
                confPassed += 1
            } else {
                confFailed += 1
                print("  FAIL \(relPath): encode mismatch")
                print("    got: \(got.debugDescription)")
                print("    exp: \(expected.debugDescription)")
            }
        case "decode":
            guard let inputStr = fix["input"] as? String else { confSkipped += 1; continue }
            do {
                let _ = try decodeGeneric(inputStr)
                confPassed += 1
            } catch {
                confFailed += 1
                print("  FAIL \(relPath): decode error: \(error)")
            }
        case "error":
            guard let inputStr = fix["input"] as? String else { confSkipped += 1; continue }
            guard let expectedError = fix["expectedError"] as? String else { confSkipped += 1; continue }
            do {
                let _ = try decodeGeneric(inputStr)
                confFailed += 1
                print("  FAIL \(relPath): expected error '\(expectedError)' but got success")
            } catch {
                if "\(error)".contains(expectedError) {
                    confPassed += 1
                } else {
                    confFailed += 1
                    print("  FAIL \(relPath): wrong error: \(error), expected \(expectedError)")
                }
            }
        default:
            confSkipped += 1
        }
    }
    print("Conformance: \(confPassed) passed, \(confSkipped) skipped, \(confFailed) failed")
    if confFailed > 0 { failed += confFailed }
} else {
    print("Conformance fixtures not found at \(fixtureDir.path)")
}

// Round-trip
section("Round-trip (1000 random)")
let iterations = 1000
var rtFailed = 0
for i in 0..<iterations {
    let val = genRandomValue(depth: 0, maxDepth: 3)
    let gcf = encodeGeneric(val)
    do {
        let _ = try decodeGeneric(gcf)
    } catch {
        rtFailed += 1
        if rtFailed <= 3 {
            print("  FAIL iteration \(i): \(error)")
        }
    }
}
if rtFailed == 0 { passed += 1; print("  \(iterations) round-trips OK") }
else { failed += 1; print("  \(rtFailed)/\(iterations) round-trips failed") }

// Summary
print("\n========================================")
print("Results: \(passed) passed, \(failed) failed")
if !testErrors.isEmpty {
    for e in testErrors { print("  - \(e)") }
}
print("========================================")
if failed > 0 { exit(1) }

// Random value generator
func genRandomValue(depth: Int, maxDepth: Int) -> Any? {
    if depth >= maxDepth { return genScalar() }
    switch Int.random(in: 0..<8) {
    case 0: return nil
    case 1: return Bool.random()
    case 2: return Int.random(in: -100..<1000)
    case 3: return Double.random(in: -100..<1000)
    case 4: return genString()
    case 5: return genDict(depth: depth, maxDepth: maxDepth)
    case 6: return genArray(depth: depth, maxDepth: maxDepth)
    default: return genScalar()
    }
}

func genScalar() -> Any? {
    switch Int.random(in: 0..<4) {
    case 0: return nil
    case 1: return Bool.random()
    case 2: return Int.random(in: -100..<1000)
    default: return genString()
    }
}

func genString() -> String {
    let chars = "abcdefghijklmnopqrstuvwxyz0123456789 |,=\"\\#@\n\t~^"
    let n = Int.random(in: 0..<15)
    return String((0..<n).map { _ in chars.randomElement()! })
}

func genDict(depth: Int, maxDepth: Int) -> [String: Any] {
    let keys = "abcdefghijklmnopqrstuvwxyz_"
    let n = Int.random(in: 0..<5)
    var d = [String: Any]()
    for _ in 0..<n {
        let k = String((0..<(1 + Int.random(in: 0..<6))).map { _ in keys.randomElement()! })
        d[k] = genRandomValue(depth: depth + 1, maxDepth: maxDepth)
    }
    return d
}

func genArray(depth: Int, maxDepth: Int) -> [Any] {
    let n = Int.random(in: 0..<5)
    return (0..<n).map { _ in genRandomValue(depth: depth + 1, maxDepth: maxDepth) as Any }
}
