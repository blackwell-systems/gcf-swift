import XCTest
@testable import GCF

// Targeted fuzz/property coverage for spec v3.6.0 (constant-column factoring §7.4.7
// and value-grouping §7.4.8), mirroring the Go harness constant_grouping_fuzz_test.go.
// Constant-factoring rides the default encoder (so the constant-biased round-trip
// exercises it); value-grouping is opt-in (encodeGenericGrouped) and has its own
// keyed-set round-trip. A mutation harness requires the decoder to error, never crash,
// on corrupted factored/grouped wire, and a discrimination test pins that the v3.6.0
// markers do not reclassify a payload of another shape.

private struct CGRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}

// hazardStrings mimic v3.6.0 syntax tokens (clauses, subheaders, structural markers)
// so the generators can plant them as field names and values. A value or name that
// LOOKS like a grouping clause, a constant entry, a subheader, or another shape's
// marker must still decode as plain data, never reclassify the payload. Includes the
// complete-marker family: a bare "^" and "^{a}"/"^{a,b}" are complete markers; "^{abc"
// and "^{" (no closing "}") are LITERAL scalars that must round-trip.
private let hazardStrings: [String] = [
    "group=dept", "group=", "region=us-east", "= [1]", "k=v [1]",
    "dept=Sales [2]", "}", "{a}", "[2]", "[2:]", "[0]", "[?]",
    "## section", ".field", "@id", "@0", "a|b", "-", "~",
    "^", "^{abc", "^{a}", "^{", "^x", "^{a,b}",
]

final class GenericConstantGroupingFuzzTests: XCTestCase {

    private func iterations(_ n: Int) -> Int {
        if let s = ProcessInfo.processInfo.environment["GCF_FUZZ_ITERATIONS"], let v = Int(s) { return v }
        return n
    }

    // MARK: - adversarial value / name generators

    private func genAdversarialScalar(_ rng: inout CGRNG) -> Any {
        switch rng.int(9) {
        case 0: return Int(rng.int(2001) - 1000)
        case 1: return Double(rng.int(100000)) / 1000.0
        case 2: return (rng.next() & 1) == 0
        case 3: return NSNull()
        case 4: return "plain\(rng.int(100))"
        case 5: return ["true", "false", "123", "-0", "007"][rng.int(5)]
        case 6: return ["  leading", "trailing  ", "", "a,b", "a|b"][rng.int(5)]
        case 7: return ["#x", "@y", ".z", "{braced}", "a}b"][rng.int(5)]
        default: return ["é", "中", "🦞", "x>y"][rng.int(4)]
        }
    }

    private func hazardValue(_ rng: inout CGRNG) -> Any {
        if rng.int(3) == 0 { return hazardStrings[rng.int(hazardStrings.count)] }
        return genAdversarialScalar(&rng)
    }

    private func genScalar(_ rng: inout CGRNG) -> Any {
        switch rng.int(5) {
        case 0: return Int(rng.int(2001) - 1000)
        case 1: return Double(rng.int(100000)) / 1000.0
        case 2: return (rng.next() & 1) == 0
        case 3: return NSNull()
        default: return "s\(rng.int(10000))"
        }
    }

    // genFieldName returns mostly bare keys, sometimes a quoting-required key
    // (including names that contain "=", which must NOT be read as a constant-column
    // separator, and names that mimic other markers). Never returns a used name.
    private func genFieldName(_ rng: inout CGRNG, _ used: inout Set<String>) -> String {
        while true {
            var f: String
            switch rng.int(4) {
            case 0: f = ["a=b", "x", "", "a|b", "k,v", "\"q\""][rng.int(6)]
            case 1: f = hazardStrings[rng.int(hazardStrings.count)]
            default: f = "f\(rng.int(1000))"
            }
            if f.isEmpty { f = "f\(rng.int(1000))" }
            if !used.contains(f) { used.insert(f); return f }
        }
    }

    private func recField(_ rec: Any, _ name: String) -> Any {
        if let od = rec as? OrderedDictionary { return od[name] ?? NSNull() }
        if let d = rec as? [String: Any] { return d[name] ?? NSNull() }
        return NSNull()
    }

    // MARK: - constant-biased generator

    // genConstBiasedArray builds a tabular array (>=2 records, scalar leaves only) in
    // which a random subset of fields is held constant across every record, drawing
    // constant values from the adversarial pool so the factored value hits the quoting
    // path. Sometimes every field is constant, exercising the all-constant / last-
    // column-retained edge of §7.4.7.1.
    private func genConstBiasedArray(_ rng: inout CGRNG) -> [Any] {
        let n = 2 + rng.int(6)   // 2..7 records
        let k = 1 + rng.int(5)   // 1..5 fields
        var fields: [String] = []
        var used = Set<String>()
        while fields.count < k { fields.append(genFieldName(&rng, &used)) }
        var constVal: [String: Any] = [:]
        let forceAll = rng.int(8) == 0 // ~12% all-constant
        for f in fields where forceAll || rng.int(2) == 0 { constVal[f] = hazardValue(&rng) }
        var arr: [Any] = []
        for _ in 0..<n {
            let rec = OrderedDictionary()
            for f in fields {
                if let v = constVal[f] { rec[f] = v }
                else if rng.int(4) == 0 { rec[f] = hazardValue(&rng) }
                else { rec[f] = genScalar(&rng) }
            }
            arr.append(rec)
        }
        return arr
    }

    // headerHasFactoredColumn reports whether the first tabular header contains a
    // name=value entry.
    private func headerHasFactoredColumn(_ gcf: String) -> Bool {
        for line in gcf.components(separatedBy: "\n") where scalarHasPrefix(line, "## ") {
            let scalars = Array(line.unicodeScalars)
            guard let open = scalars.firstIndex(of: "{"),
                  let close = scalars.lastIndex(of: "}"), close > open else { continue }
            if scalars[open..<close].contains("=") { return true }
        }
        return false
    }

    func testConstantBiasedRoundTrip() throws {
        let iters = iterations(50_000)
        var rng = CGRNG(0xC0)
        var factored = 0
        for i in 0..<iters {
            let val = genConstBiasedArray(&rng)
            let gcf = encodeGeneric(val)
            if headerHasFactoredColumn(gcf) { factored += 1 }
            let decoded = try decodeGeneric(gcf)
            XCTAssertTrue(deepEqual(val, decoded),
                          "iteration \(i): constant round-trip mismatch\n  gcf:\n\(gcf)")
        }
        XCTAssertGreaterThan(factored, 0, "coverage gap: no factored headers produced in \(iters) iterations")
    }

    // MARK: - value-grouping: keyed-set generator

    // genGroupedSet builds a keyed set suitable for encodeGenericGrouped: a unique key
    // field, a low-cardinality group field (values drawn adversarially, including null,
    // brackets, commas, "="), and 0..3 extra scalar fields some of which may be
    // constant. Key uniqueness is by construction, so the encoder never errors.
    private func genGroupedSet(_ rng: inout CGRNG) -> ([Any], String, String) {
        let keyField = "k", groupField = "g"
        let n = 2 + rng.int(8) // 2..9 records
        let poolSize = 1 + rng.int(4)
        var pool: [Any] = []
        var seen = Set<String>()
        while pool.count < poolSize {
            let v = hazardValue(&rng)
            let kkey = "\(type(of: v))/\(formatScalar(v))"
            if seen.contains(kkey) { continue }
            seen.insert(kkey)
            pool.append(v)
        }
        let extraN = rng.int(4)
        var extras: [String] = []
        var used: Set<String> = ["k", "g"]
        while extras.count < extraN { extras.append(genFieldName(&rng, &used)) }
        var extraConst: [String: Any] = [:]
        for f in extras where rng.int(2) == 0 { extraConst[f] = hazardValue(&rng) }
        var arr: [Any] = []
        for i in 0..<n {
            let rec = OrderedDictionary()
            rec[keyField] = String(format: "k%04d", i)
            rec[groupField] = pool[rng.int(pool.count)]
            for f in extras {
                if let v = extraConst[f] { rec[f] = v }
                else if rng.int(4) == 0 { rec[f] = hazardValue(&rng) }
                else { rec[f] = genScalar(&rng) }
            }
            arr.append(rec)
        }
        return (arr, keyField, groupField)
    }

    private func sortByKey(_ arr: [Any], _ keyField: String) -> [Any] {
        arr.sorted { formatScalar(recField($0, keyField)) < formatScalar(recField($1, keyField)) }
    }

    func testGroupedRoundTrip() throws {
        let iters = iterations(50_000)
        var rng = CGRNG(0x6C)
        for i in 0..<iters {
            let (val, kf, gf) = genGroupedSet(&rng)
            let gcf: String
            do {
                gcf = try encodeGenericGrouped(val, keyField: kf, groupField: gf)
            } catch {
                XCTFail("iteration \(i): encodeGenericGrouped failed on a valid keyed set: \(error)")
                continue
            }
            let decodedAny = try decodeGeneric(gcf)
            guard let decoded = decodedAny as? [Any] else {
                XCTFail("iteration \(i): grouped decode did not yield an array")
                continue
            }
            XCTAssertEqual(decoded.count, val.count, "iteration \(i): record count\n  gcf:\n\(gcf)")
            // Compare as a set keyed by kf: sort both by key, then deep-equal.
            let inSorted = sortByKey(val, kf)
            let outSorted = sortByKey(decoded, kf)
            XCTAssertTrue(deepEqual(inSorted, outSorted),
                          "iteration \(i): grouped round-trip mismatch\n  gcf:\n\(gcf)")
        }
    }

    // MARK: - decoder robustness (mutation)

    private func mutate(_ rng: inout CGRNG, _ bytes: [UInt8]) -> [UInt8] {
        var b = bytes
        if b.isEmpty { return [UInt8(rng.int(128))] }
        switch rng.int(6) {
        case 0: // flip a bit
            let i = rng.int(b.count); b[i] ^= UInt8(1 << rng.int(8))
        case 1: // delete a byte
            b.remove(at: rng.int(b.count))
        case 2: // insert a structural byte
            let structural = Array("|{}[]=@#.-~\"\n ".utf8)
            b.insert(structural[rng.int(structural.count)], at: rng.int(b.count + 1))
        case 3: // truncate
            b = Array(b.prefix(rng.int(b.count)))
        case 4: // duplicate a fragment
            let i = rng.int(b.count); b.insert(contentsOf: b[i...], at: i)
        default: // random byte
            b[rng.int(b.count)] = UInt8(rng.int(128))
        }
        return b
    }

    // Mutates valid factored/grouped wire and requires the decoder to error cleanly
    // (Swift throws), never crash, on the result. In Swift a trapping crash would abort
    // the process; a thrown error or clean success are both acceptable.
    func testMutationRobustness() throws {
        let iters = iterations(50_000)
        var rng = CGRNG(0xF0)
        for _ in 0..<iters {
            let wire: String
            if rng.int(2) == 0 {
                wire = encodeGeneric(genConstBiasedArray(&rng))
            } else {
                let (arr, kf, gf) = genGroupedSet(&rng)
                guard let w = try? encodeGenericGrouped(arr, keyField: kf, groupField: gf) else { continue }
                wire = w
            }
            var bytes = Array(wire.utf8)
            var m = 1 + rng.int(4)
            while m > 0 { bytes = mutate(&rng, bytes); m -= 1 }
            let input = String(decoding: bytes, as: UTF8.self)
            // An error is fine; a crash is not. decodeGeneric either returns or throws.
            _ = try? decodeGeneric(input)
        }
    }

    // MARK: - shape discrimination

    // Pins that the v3.6.0 markers do not reclassify a payload of another shape: an
    // @-marked field without a group= clause stays invalid (not silently grouped), a
    // keyed map stays a map (not read as grouped), and a flat tabular array stays flat.
    func testShapeDiscrimination() throws {
        // @-key field without group= must be rejected with an invalid-field-name error.
        do {
            _ = try decodeGeneric("GCF profile=generic\n## [2]{@id,x}\nu1|1\nu2|2\n")
            XCTFail("@-marked field without group= should be rejected")
        } catch {
            XCTAssertTrue("\(error)".contains("invalid field name"),
                          "unexpected error category for @-without-group: \(error)")
        }
        // Keyed map [N:] decodes to an object, not an array; group= must not intercept.
        let got = try decodeGeneric("GCF profile=generic\n## [2:]{key,x}\na|1\nb|2\n")
        XCTAssertTrue(got is OrderedDictionary, "keyed map [N:] decoded as \(type(of: got)), want OrderedDictionary")

        // A flat tabular array with no constant column stays flat and round-trips.
        let flat: [Any] = [
            { let o = OrderedDictionary(); o["id"] = "u1"; o["r"] = "a"; return o }(),
            { let o = OrderedDictionary(); o["id"] = "u2"; o["r"] = "b"; return o }(),
        ]
        let wire = encodeGeneric(flat)
        XCTAssertFalse(headerHasFactoredColumn(wire), "flat array with varying columns should not factor: \(wire)")
        XCTAssertTrue(deepEqual(flat, try decodeGeneric(wire)), "flat round-trip failed: \(wire)")
    }

    // Seed-corpus style panic-freedom: a handful of hand-picked wires plus the hazard
    // family as both group values and row cells, asserting no crash.
    func testHazardSeedsDecodeCleanly() throws {
        let seeds = [
            "GCF profile=generic\n## [2]{id,region=us-east,level}\nu1|3\nu2|1\n",
            "GCF profile=generic\n## [2]{a=1,b}\n2\n2\n",
            "GCF profile=generic\n## [2]{@id,dept,x} group=dept\ndept=Sales [2]\nu1|1\nu2|2\n",
            "GCF profile=generic\n## [1]{@id,g,x} group=g\ng=- [1]\nu1|1\n",
            "GCF profile=generic\n## [2]{X=^{abc,y}\n1\n2\n",
            "GCF profile=generic\n## [2]{X=^,y}\n1\n2\n",
        ]
        for s in seeds { _ = try? decodeGeneric(s) }
    }
}
