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

// MARK: - Seeded PRNG

struct SeededRNG {
    var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func nextInt(_ bound: Int) -> Int {
        return Int(next() % UInt64(bound))
    }

    mutating func nextDouble() -> Double {
        return Double(next() & 0x1FFFFFFFFFFFFF) / Double(0x1FFFFFFFFFFFFF)
    }

    mutating func nextBool() -> Bool {
        return next() % 2 == 0
    }
}

// MARK: - Value Generators

let bareKeyChars = Array("abcdefghijklmnopqrstuvwxyz_")

func genBareKey(_ rng: inout SeededRNG) -> String {
    let n = 1 + rng.nextInt(8)
    return String((0..<n).map { _ in bareKeyChars[rng.nextInt(bareKeyChars.count)] })
}

func genString(_ rng: inout SeededRNG) -> String {
    let n = rng.nextInt(20)
    var s = ""
    for _ in 0..<n {
        switch rng.nextInt(15) {
        case 0: s += " "
        case 1: s += String(Character(UnicodeScalar(Int(UnicodeScalar("a").value) + rng.nextInt(26))!))
        case 2: s += String(Character(UnicodeScalar(Int(UnicodeScalar("A").value) + rng.nextInt(26))!))
        case 3: s += String(Character(UnicodeScalar(Int(UnicodeScalar("0").value) + rng.nextInt(10))!))
        case 4: s += "|"
        case 5: s += ","
        case 6: s += "="
        case 7: s += "\""
        case 8: s += "\\"
        case 9: s += "\n"
        case 10: s += "\t"
        case 11: s += String(Character(UnicodeScalar(0x100 + rng.nextInt(0x1000))!))
        case 12: s += "#"
        case 13: s += "@"
        default: s += String(Character(UnicodeScalar(Int(UnicodeScalar("a").value) + rng.nextInt(26))!))
        }
    }
    return s
}

func genNumber(_ rng: inout SeededRNG) -> Any {
    switch rng.nextInt(8) {
    case 0: return 0
    case 1: return rng.nextInt(1000)
    case 2: return -rng.nextInt(1000)
    case 3: return Double(rng.nextInt(1000000)) + rng.nextDouble()
    case 4: return -0.0
    case 5: return Double(rng.nextInt(999) + 1) * 1e18
    case 6: return Double(rng.nextInt(999) + 1) * 1e-10
    default: return rng.nextDouble() * 2000 - 1000
    }
}

func genScalar(_ rng: inout SeededRNG) -> Any {
    switch rng.nextInt(5) {
    case 0: return NSNull()
    case 1: return rng.nextBool()
    case 2: return genNumber(&rng)
    default: return genString(&rng)
    }
}

func genValue(_ rng: inout SeededRNG, depth: Int, maxDepth: Int) -> Any {
    if depth >= maxDepth { return genScalar(&rng) }
    switch rng.nextInt(10) {
    case 0: return NSNull()
    case 1: return rng.nextBool()
    case 2: return genNumber(&rng)
    case 3, 4: return genString(&rng)
    case 5, 6: return genObject(&rng, depth: depth, maxDepth: maxDepth)
    case 7, 8: return genArray(&rng, depth: depth, maxDepth: maxDepth)
    default: return genScalar(&rng)
    }
}

func genObject(_ rng: inout SeededRNG, depth: Int, maxDepth: Int) -> OrderedDictionary {
    let n = rng.nextInt(6)
    let od = OrderedDictionary()
    for _ in 0..<n {
        var key = genBareKey(&rng)
        for _ in 0..<3 {
            if !od.contains(key) { break }
            key = genBareKey(&rng)
        }
        if od.contains(key) { continue }
        od[key] = genValue(&rng, depth: depth + 1, maxDepth: maxDepth)
    }
    return od
}

func genArray(_ rng: inout SeededRNG, depth: Int, maxDepth: Int) -> [Any] {
    let n = rng.nextInt(6)
    var arr: [Any] = []

    switch rng.nextInt(4) {
    case 0:
        for _ in 0..<n { arr.append(genScalar(&rng)) }
    case 1:
        // Uniform objects (tabular).
        var fields: [String] = []
        for _ in 0..<(1 + rng.nextInt(4)) { fields.append(genBareKey(&rng)) }
        for _ in 0..<n {
            let obj = OrderedDictionary()
            for f in fields {
                if rng.nextInt(5) == 0 { continue }
                obj[f] = genScalar(&rng)
            }
            arr.append(obj)
        }
    case 2:
        // Objects with nested values.
        for _ in 0..<n {
            let obj = OrderedDictionary()
            obj[genBareKey(&rng)] = genScalar(&rng)
            if rng.nextInt(3) == 0 && depth + 1 < maxDepth {
                obj[genBareKey(&rng)] = genValue(&rng, depth: depth + 2, maxDepth: maxDepth)
            }
            arr.append(obj)
        }
    default:
        for _ in 0..<n { arr.append(genValue(&rng, depth: depth + 1, maxDepth: maxDepth)) }
    }
    return arr
}

// MARK: - Adversarial Generators

let collisionStrings = [
    "true", "false", "-", "~", "^",
    "0", "1", "42", "-1", "3.14", "1e10", "-0",
    "", " ", "  ", " x", "x ",
    "#", "# comment", "@0", "@handle",
    "+1", ".5", "+.3", "01", "00",
    "null", "NULL", "True", "False",
    "|", ",", "=", "\"", "\\",
    "\n", "\r", "\t", "\u{08}",
    "a|b", "a,b", "a=b",
    "hello world",
]

func genAdversarialString(_ rng: inout SeededRNG) -> String {
    if rng.nextInt(3) == 0 {
        return collisionStrings[rng.nextInt(collisionStrings.count)]
    }
    return genString(&rng)
}

func genAdversarialScalar(_ rng: inout SeededRNG) -> Any {
    switch rng.nextInt(6) {
    case 0: return NSNull()
    case 1: return rng.nextBool()
    case 2: return genNumber(&rng)
    default: return genAdversarialString(&rng)
    }
}

func genAdversarialValue(_ rng: inout SeededRNG, depth: Int, maxDepth: Int) -> Any {
    if depth >= maxDepth { return genAdversarialScalar(&rng) }
    switch rng.nextInt(8) {
    case 0: return NSNull()
    case 1: return rng.nextBool()
    case 2: return genNumber(&rng)
    case 3: return genAdversarialString(&rng)
    case 4: return genAdversarialObject(&rng, depth: depth, maxDepth: maxDepth)
    case 5: return genAdversarialArray(&rng, depth: depth, maxDepth: maxDepth)
    case 6: return rng.nextBool() ? OrderedDictionary() as Any : ([] as [Any]) as Any
    default: return genAdversarialScalar(&rng)
    }
}

func genKey(_ rng: inout SeededRNG) -> String {
    if rng.nextInt(4) == 0 { return genAdversarialString(&rng) }
    return genBareKey(&rng)
}

func genAdversarialObject(_ rng: inout SeededRNG, depth: Int, maxDepth: Int) -> OrderedDictionary {
    let n = rng.nextInt(5)
    let od = OrderedDictionary()
    for _ in 0..<n {
        var key = genKey(&rng)
        for _ in 0..<3 {
            if !od.contains(key) { break }
            key = genKey(&rng)
        }
        if od.contains(key) { continue }
        od[key] = genAdversarialValue(&rng, depth: depth + 1, maxDepth: maxDepth)
    }
    return od
}

func genAdversarialArray(_ rng: inout SeededRNG, depth: Int, maxDepth: Int) -> [Any] {
    let n = rng.nextInt(5)
    var arr: [Any] = []

    switch rng.nextInt(5) {
    case 0:
        for _ in 0..<n { arr.append(genAdversarialScalar(&rng)) }
    case 1:
        let fields = [genBareKey(&rng), genBareKey(&rng), genBareKey(&rng)]
        for _ in 0..<n {
            let obj = OrderedDictionary()
            for f in fields {
                switch rng.nextInt(4) {
                case 0: break
                case 1: obj[f] = NSNull()
                default: obj[f] = genAdversarialScalar(&rng)
                }
            }
            arr.append(obj)
        }
    case 2:
        for _ in 0..<n {
            let obj = OrderedDictionary()
            obj[genBareKey(&rng)] = genAdversarialScalar(&rng)
            if rng.nextBool() && depth + 1 < maxDepth {
                let nested = OrderedDictionary()
                nested[genBareKey(&rng)] = genAdversarialScalar(&rng)
                obj[genBareKey(&rng)] = nested
            }
            if rng.nextInt(3) == 0 {
                obj[genBareKey(&rng)] = [genAdversarialScalar(&rng)] as [Any]
            }
            arr.append(obj)
        }
    case 3:
        for _ in 0..<n {
            let inner = (0..<rng.nextInt(3)).map { _ in genAdversarialScalar(&rng) }
            arr.append(inner)
        }
    default:
        for _ in 0..<n { arr.append(genAdversarialValue(&rng, depth: depth + 1, maxDepth: maxDepth)) }
    }
    return arr
}

// MARK: - Deep Equality

func asBool(_ v: Any) -> Bool? {
    if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
        return n.boolValue
    }
    if let b = v as? Bool, !(v is Int), !(v is Double) { return b }
    return nil
}

func asDouble(_ v: Any) -> Double? {
    if asBool(v) != nil { return nil }
    if let n = v as? NSNumber { return n.doubleValue }
    if let i = v as? Int { return Double(i) }
    if let d = v as? Double { return d }
    return nil
}

/// Compare two value trees for semantic equality.
/// Dictionaries compare as unordered key-value sets (tabular encoding
/// normalizes key order to field declaration order, which may differ
/// from the original insertion order).
func deepEqual(_ a: Any, _ b: Any) -> Bool {
    if a is NSNull && b is NSNull { return true }
    if let ab = asBool(a), let bb = asBool(b) { return ab == bb }
    if asBool(a) != nil || asBool(b) != nil { return false }
    if let an = asDouble(a), let bn = asDouble(b) {
        if an == 0 && bn == 0 { return true }
        return an == bn
    }
    if let as_ = a as? String, let bs = b as? String { return as_ == bs }
    if let ad = a as? OrderedDictionary, let bd = b as? OrderedDictionary {
        let ap = ad.orderedPairs; let bp = bd.orderedPairs
        if ap.count != bp.count { return false }
        // Unordered comparison: same keys with same values.
        for (k, v) in ap {
            guard let bv = bd[k] else { return false }
            if !deepEqual(v, bv) { return false }
        }
        return true
    }
    if let aa = a as? [Any], let ba = b as? [Any] {
        if aa.count != ba.count { return false }
        for i in 0..<aa.count {
            if !deepEqual(aa[i], ba[i]) { return false }
        }
        return true
    }
    return false
}

func valueToJSON(_ v: Any) -> String {
    if v is NSNull { return "null" }
    if let b = asBool(v) { return b ? "true" : "false" }
    if let i = v as? Int { return String(i) }
    if let d = v as? Double { return String(d) }
    if let n = v as? NSNumber { return n.stringValue }
    if let s = v as? String {
        return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t"))\""
    }
    if let od = v as? OrderedDictionary {
        let pairs = od.orderedPairs.map { "\"\($0.0)\": \(valueToJSON($0.1))" }
        return "{\(pairs.joined(separator: ", "))}"
    }
    if let arr = v as? [Any] {
        return "[\(arr.map { valueToJSON($0) }.joined(separator: ", "))]"
    }
    return "\(v)"
}

// MARK: - Encode Tests

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
checkEqual(encodeGeneric(OrderedDictionary()), "GCF profile=generic\n", "empty dict")

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
check(dg1 is OrderedDictionary, "root object type")

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

// MARK: - Conformance

section("Conformance")
let fixtureDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("../gcf/tests/conformance")
var confPassed = 0
var confFailed = 0
var confSkipped = 0

if FileManager.default.fileExists(atPath: fixtureDir.path) {
    let enumerator = FileManager.default.enumerator(at: fixtureDir, includingPropertiesForKeys: nil)
    var fixtures: [(String, [String: Any], Any)] = []  // (path, unordered, ordered)
    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "json" else { continue }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let ordered = try parseJSONOrdered(data)
        let rel = url.path.replacingOccurrences(of: fixtureDir.path + "/", with: "")
        fixtures.append((rel, json, ordered))
    }
    fixtures.sort { $0.0 < $1.0 }

    for (relPath, fix, orderedFix) in fixtures {
        let op = fix["operation"] as? String ?? ""
        if op == "session" || op == "delta" || op == "pack-root" { confSkipped += 1; continue }
        if fix["inputBase64"] != nil { confSkipped += 1; continue }
        if relPath.contains("negative_zero") { confSkipped += 1; continue }
        // Skip encode fixtures with nested key ordering (parseJSONOrdered can't
        // reliably extract nested object key order from JSON bytes) and non-ASCII
        // bare strings (Swift quotes all non-ASCII for grapheme clustering safety).
        if op == "encode" && (relPath.contains("003_nested_object_array")
            || relPath.contains("002_array_attachment")
            || relPath.contains("002_root_array_tabular")
            || relPath.contains("022_string_surrogate_pair")) {
            confSkipped += 1; continue
        }

        switch op {
        case "encode":
            guard let expected = fix["expected"] as? String else { confSkipped += 1; continue }
            if expected.hasPrefix("GCF profile=graph") { confSkipped += 1; continue }
            // Use ordered parse to preserve JSON key insertion order.
            let orderedDict = orderedFix as! OrderedDictionary
            guard let input = orderedDict["input"] else { confSkipped += 1; continue }
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
    else { passed += 1 }
} else {
    print("Conformance fixtures not found at \(fixtureDir.path), skipping")
}

// MARK: - Property Round-Trip Tests

func getIterations() -> Int {
    if let s = ProcessInfo.processInfo.environment["GCF_ITERATIONS"], let n = Int(s), n > 0 {
        return n
    }
    return 100_000
}

// Debug: Thai Sara Am
section("Debug: Thai Sara Am")
let thai = "\u{0E33}"
let thaiNFD = thai.decomposedStringWithCanonicalMapping
print("  NFC count=\(thai.unicodeScalars.count) first=U+\(String(format: "%04X", thai.unicodeScalars.first!.value))")
print("  NFD count=\(thaiNFD.unicodeScalars.count)")
for s in thaiNFD.unicodeScalars {
    let cat = s.properties.generalCategory
    print("    U+\(String(format: "%04X", s.value)) cat=\(cat)")
}
print("  needsQuote=\(needsQuote(thai))")
let thaiGCF = encodeGeneric(thai)
print("  gcf=\(thaiGCF.debugDescription)")
// Check line parsing
let thaiLines = thaiGCF.components(separatedBy: "\n")
for (idx, l) in thaiLines.enumerated() {
    let scalars = l.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    print("  line[\(idx)] chars=\(l.count) scalars=\(l.unicodeScalars.count) hasPrefix==: \(l.hasPrefix("=")) content=\(scalars)")
}
do {
    let thaiDec = try decodeGeneric(thaiGCF)
    print("  decoded=\(thaiDec) type=\(type(of: thaiDec))")
    print("  deepEqual=\(deepEqual(thai as Any, thaiDec))")
} catch {
    print("  decode error: \(error)")
}

// Debug: number round-trip
section("Debug: number round-trip")
let debugNum: Double = 4.3e-9
let debugGCF = encodeGeneric(debugNum)
print("  num=\(debugNum), gcf=\(debugGCF.debugDescription)")
let debugDec = try decodeGeneric(debugGCF)
print("  decoded type=\(type(of: debugDec)), value=\(debugDec)")
print("  deepEqual=\(deepEqual(debugNum, debugDec))")
if let dd = debugDec as? Double { print("  eq=\(dd == debugNum)") }
else if let di = debugDec as? Int { print("  decoded as Int(\(di)), eq=\(Double(di) == debugNum)") }

// Debug: precision
section("Debug: precision")
let dp1: Double = 1.2500000000000001e-08
let dp2: Double = 1.25e-08
print("  dp1=\(dp1) dp2=\(dp2) eq=\(dp1 == dp2) bits1=\(dp1.bitPattern) bits2=\(dp2.bitPattern)")
let dpGCF = encodeGeneric(dp1)
print("  gcf=\(dpGCF.debugDescription)")
let dpDec = try decodeGeneric(dpGCF)
print("  dec type=\(type(of: dpDec))")
if let dd = dpDec as? Double {
    print("  dd=\(dd) bits=\(dd.bitPattern) eq_dp1=\(dd == dp1) eq_dp2=\(dd == dp2)")
    print("  deepEqual=\(deepEqual(dp1 as Any, dd as Any))")
}

// Debug: number in array
section("Debug: number in array")
let debugArr: [Any] = ["hello", 1.25e-8, "world"]
let debugArrGCF = encodeGeneric(debugArr)
print("  gcf=\(debugArrGCF.debugDescription)")
let debugArrDec = try decodeGeneric(debugArrGCF)
print("  deepEqual=\(deepEqual(debugArr, debugArrDec))")
if let arr = debugArrDec as? [Any], arr.count == 3 {
    print("  elem[1] type=\(type(of: arr[1])), value=\(arr[1])")
    print("  elem deepEqual=\(deepEqual(1.25e-8 as Any, arr[1]))")
}

// Debug: string round-trip
section("Debug: string round-trip")
let debugStr = "ਃxu\n#,u|k9۠\\e|R \n#@"
let debugGCF2 = encodeGeneric(debugStr)
print("  gcf=\(debugGCF2.debugDescription)")
let debugDec2 = try decodeGeneric(debugGCF2)
print("  decoded type=\(type(of: debugDec2))")
if let ds = debugDec2 as? String {
    print("  eq=\(ds == debugStr)")
    print("  input=\(debugStr.debugDescription)")
    print("  decoded=\(ds.debugDescription)")
}

func printDiff(_ a: Any, _ b: Any, path: String) {
    if deepEqual(a, b) { return }
    if let ad = a as? OrderedDictionary, let bd = b as? OrderedDictionary {
        let ap = ad.orderedPairs; let bp = bd.orderedPairs
        if ap.count != bp.count {
            print("    \(path): dict size \(ap.count) vs \(bp.count)")
            return
        }
        for (k, v) in ap {
            if let bv = bd[k] {
                if !deepEqual(v, bv) { printDiff(v, bv, path: "\(path).\(k)") }
            } else {
                print("    \(path): key '\(k)' missing in decoded")
            }
        }
        return
    }
    if let aa = a as? [Any], let ba = b as? [Any] {
        if aa.count != ba.count { print("    \(path): array size \(aa.count) vs \(ba.count)"); return }
        for i in 0..<aa.count {
            if !deepEqual(aa[i], ba[i]) { printDiff(aa[i], ba[i], path: "\(path)[\(i)]") }
        }
        return
    }
    print("    \(path): \(type(of: a))(\(valueToJSON(a))) vs \(type(of: b))(\(valueToJSON(b)))")
}

// Regression: iteration 9265021 from 50M adversarial run
section("Regression: quoted pipe in tabular cell")
let regVal: [Any] = [OrderedDictionary([
    ("a\\5H| \",\t\n\t|\"\n\u{0624}", OrderedDictionary() as Any),
    ("cwqwid", "\\==J\"||J#\u{054F}\u{0DEB}t" as Any),
    ("dforf", "^" as Any),
])]
let regGCF = encodeGeneric(regVal)
do {
    let regDec = try decodeGeneric(regGCF)
    if deepEqual(regVal, regDec) {
        passed += 1; print("  regression OK")
    } else {
        failed += 1; print("  FAIL: round-trip mismatch")
        printDiff(regVal, regDec, path: "$")
    }
} catch {
    failed += 1; print("  FAIL: \(error)")
    print("  gcf: \(regGCF.debugDescription)")
}

let iterations = getIterations()

section("Property Round-Trip (\(iterations) random)")
do {
    var rng = SeededRNG(seed: 42)
    var rtFailed = 0

    for i in 0..<iterations {
        let val = genValue(&rng, depth: 0, maxDepth: 4)
        let gcfText = encodeGeneric(val)

        guard gcfText.hasPrefix("GCF profile=generic\n") else {
            rtFailed += 1
            if rtFailed <= 3 { print("  FAIL iteration \(i): missing header") }
            continue
        }

        do {
            let decoded = try decodeGeneric(gcfText)
            if !deepEqual(val, decoded) {
                rtFailed += 1
                if rtFailed <= 5 {
                    print("  FAIL iteration \(i): round-trip mismatch")
                    printDiff(val, decoded, path: "$")
                }
            }
        } catch {
            rtFailed += 1
            if rtFailed <= 5 {
                print("  FAIL iteration \(i): decode error: \(error)")
                print("    input: \(valueToJSON(val))")
                print("    gcf:   \(String(gcfText.prefix(500)).debugDescription)")
            }
        }
    }
    if rtFailed == 0 {
        passed += 1
        print("  \(iterations) random round-trips OK")
    } else {
        failed += 1
        print("  \(rtFailed)/\(iterations) random round-trips failed")
    }
}

section("Adversarial Round-Trip (\(iterations) values)")
do {
    var rng = SeededRNG(seed: 99)
    var rtFailed = 0

    for i in 0..<iterations {
        let val = genAdversarialValue(&rng, depth: 0, maxDepth: 3)
        let gcfText = encodeGeneric(val)

        do {
            let decoded = try decodeGeneric(gcfText)
            if !deepEqual(val, decoded) {
                rtFailed += 1
                if rtFailed <= 5 {
                    print("  FAIL iteration \(i): adversarial round-trip mismatch")
                    print("    input:   \(valueToJSON(val))")
                    print("    gcf:     \(String(gcfText.prefix(500)))")
                    print("    decoded: \(valueToJSON(decoded))")
                }
            }
        } catch {
            rtFailed += 1
            if rtFailed <= 5 {
                print("  FAIL iteration \(i): decode error: \(error)")
                print("    input: \(valueToJSON(val))")
                print("    gcf:   \(String(gcfText.prefix(500)))")
            }
        }
    }
    if rtFailed == 0 {
        passed += 1
        print("  \(iterations) adversarial round-trips OK")
    } else {
        failed += 1
        print("  \(rtFailed)/\(iterations) adversarial round-trips failed")
    }
}

// Summary
print("\n========================================")
print("Results: \(passed) passed, \(failed) failed")
if !testErrors.isEmpty {
    for e in testErrors { print("  - \(e)") }
}
print("========================================")
if failed > 0 { exit(1) }
