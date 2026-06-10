import XCTest
@testable import GCF
import Foundation

/// Seeded pseudo-random number generator for deterministic tests.
struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        // xorshift64
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

func genScalar(_ rng: inout SeededRNG) -> Any {
    switch rng.nextInt(5) {
    case 0: return NSNull()
    case 1: return rng.nextBool()
    case 2: return genNumber(&rng)
    default: return genString(&rng)
    }
}

func genNumber(_ rng: inout SeededRNG) -> Any {
    switch rng.nextInt(8) {
    case 0: return 0
    case 1: return rng.nextInt(1000)
    case 2: return -rng.nextInt(1000)
    case 3: return Double(rng.nextInt(1000000)) + rng.nextDouble()
    case 4: return -0.0  // negative zero
    case 5: return Double(rng.nextInt(999) + 1) * 1e18  // large
    case 6: return Double(rng.nextInt(999) + 1) * 1e-10  // small
    default: return rng.nextDouble() * 2000 - 1000
    }
}

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

func genKey(_ rng: inout SeededRNG) -> String {
    if rng.nextInt(4) == 0 {
        return genAdversarialString(&rng)
    }
    return genBareKey(&rng)
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
        // All primitives.
        for _ in 0..<n { arr.append(genScalar(&rng)) }
    case 1:
        // All objects (uniform, tabular).
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
        // Objects with some nested values.
        for _ in 0..<n {
            let obj = OrderedDictionary()
            obj[genBareKey(&rng)] = genScalar(&rng)
            if rng.nextInt(3) == 0 && depth + 1 < maxDepth {
                obj[genBareKey(&rng)] = genValue(&rng, depth: depth + 2, maxDepth: maxDepth)
            }
            arr.append(obj)
        }
    default:
        // Mixed.
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

func genAdversarialScalar(_ rng: inout SeededRNG) -> Any {
    switch rng.nextInt(6) {
    case 0: return NSNull()
    case 1: return rng.nextBool()
    case 2: return genNumber(&rng)
    default: return genAdversarialString(&rng)
    }
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
        // Uniform objects with missing/null mix.
        let fields = [genBareKey(&rng), genBareKey(&rng), genBareKey(&rng)]
        for _ in 0..<n {
            let obj = OrderedDictionary()
            for f in fields {
                switch rng.nextInt(4) {
                case 0: break  // missing
                case 1: obj[f] = NSNull()
                default: obj[f] = genAdversarialScalar(&rng)
                }
            }
            arr.append(obj)
        }
    case 2:
        // Objects with nested values (tests ^ attachments).
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
        // Nested arrays.
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

/// Compare two value trees for semantic equality.
/// Handles OrderedDictionary, NSNull, NSNumber, Int/Double normalization.
func deepEqual(_ a: Any, _ b: Any) -> Bool {
    // Null.
    if a is NSNull && b is NSNull { return true }

    // Bool (check before numeric to avoid true == 1).
    if let ab = asBool(a), let bb = asBool(b) { return ab == bb }
    // One is bool, other is not.
    if asBool(a) != nil || asBool(b) != nil { return false }

    // Numeric.
    if let an = asDouble(a), let bn = asDouble(b) {
        // Both zero: don't distinguish -0 from 0 after round-trip
        // (JSON itself doesn't preserve -0 reliably).
        if an == 0 && bn == 0 { return true }
        return an == bn
    }

    // String.
    if let as_ = a as? String, let bs = b as? String { return as_ == bs }

    // OrderedDictionary (unordered comparison: tabular encoding normalizes
    // key order to field declaration order, which may differ from insertion order).
    if let ad = a as? OrderedDictionary, let bd = b as? OrderedDictionary {
        let ap = ad.orderedPairs
        if ap.count != bd.orderedPairs.count { return false }
        for (k, v) in ap {
            guard let bv = bd[k] else { return false }
            if !deepEqual(v, bv) { return false }
        }
        return true
    }

    // Array.
    if let aa = a as? [Any], let ba = b as? [Any] {
        if aa.count != ba.count { return false }
        for i in 0..<aa.count {
            if !deepEqual(aa[i], ba[i]) { return false }
        }
        return true
    }

    return false
}

private func asBool(_ v: Any) -> Bool? {
    if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
        return n.boolValue
    }
    if let b = v as? Bool, !(v is Int), !(v is Double) {
        return b
    }
    return nil
}

private func asDouble(_ v: Any) -> Double? {
    if asBool(v) != nil { return nil }
    if let n = v as? NSNumber { return n.doubleValue }
    if let i = v as? Int { return Double(i) }
    if let d = v as? Double { return d }
    return nil
}

func valueToJSON(_ v: Any) -> String {
    if v is NSNull { return "null" }
    if let b = asBool(v) { return b ? "true" : "false" }
    if let n = v as? NSNumber { return n.stringValue }
    if let i = v as? Int { return String(i) }
    if let d = v as? Double { return String(d) }
    if let s = v as? String { return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
    if let od = v as? OrderedDictionary {
        let pairs = od.orderedPairs.map { "\"\($0.0)\": \(valueToJSON($0.1))" }
        return "{\(pairs.joined(separator: ", "))}"
    }
    if let arr = v as? [Any] {
        return "[\(arr.map { valueToJSON($0) }.joined(separator: ", "))]"
    }
    return "\(v)"
}

// MARK: - Tests

final class RoundTripTests: XCTestCase {

    func getIterations() -> Int {
        if let s = ProcessInfo.processInfo.environment["GCF_ITERATIONS"], let n = Int(s), n > 0 {
            return n
        }
        return 100_000
    }

    func testPropertyRoundTrip() throws {
        let iterations = getIterations()
        var rng = SeededRNG(seed: 42)

        for i in 0..<iterations {
            let val = genValue(&rng, depth: 0, maxDepth: 4)
            let gcfText = encodeGeneric(val)

            XCTAssertTrue(gcfText.hasPrefix("GCF profile=generic\n"),
                          "iteration \(i): missing header")

            let decoded: Any
            do {
                decoded = try decodeGeneric(gcfText)
            } catch {
                XCTFail("iteration \(i): decode failed: \(error)\n  input: \(valueToJSON(val))\n  gcf: \(String(gcfText.prefix(500)))")
                return
            }

            if !deepEqual(val, decoded) {
                XCTFail("iteration \(i): round-trip mismatch\n  input:   \(valueToJSON(val))\n  gcf:     \(String(gcfText.prefix(500)))\n  decoded: \(valueToJSON(decoded))")
                return
            }
        }
        print("PASS: \(iterations) random values round-tripped successfully")
    }

    func testPropertyRoundTripAdversarial() throws {
        let iterations = getIterations()
        var rng = SeededRNG(seed: 99)

        for i in 0..<iterations {
            let val = genAdversarialValue(&rng, depth: 0, maxDepth: 3)
            let gcfText = encodeGeneric(val)

            let decoded: Any
            do {
                decoded = try decodeGeneric(gcfText)
            } catch {
                XCTFail("iteration \(i): decode failed: \(error)\n  input: \(valueToJSON(val))\n  gcf: \(String(gcfText.prefix(500)))")
                return
            }

            if !deepEqual(val, decoded) {
                XCTFail("iteration \(i): round-trip mismatch\n  input:   \(valueToJSON(val))\n  gcf:     \(String(gcfText.prefix(500)))\n  decoded: \(valueToJSON(decoded))")
                return
            }
        }
        print("PASS: \(iterations) adversarial values round-tripped successfully")
    }
}
