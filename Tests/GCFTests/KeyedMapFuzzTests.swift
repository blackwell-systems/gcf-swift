import XCTest
@testable import GCF

// Property/fuzz tests for keyed-tabular map encoding (SPEC 7.2a, v3.5).
//
//  A. Random maps-of-objects (adversarial keys/values) round-trip through
//     encodeGeneric -> decodeGeneric, and eligible maps emit the keyed [N:] form.
//  B. A single-member map must NOT key (SPEC 7.2a.1 clause 1).
//  C. A map whose value fields all contain ">" must fall back to Section 7.2.

private struct KMRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

final class KeyedMapFuzzTests: XCTestCase {
    // Adversarial characters exercise the Section 2.4 quoting obligation on both
    // member keys (cell 0) and value fields: delimiters, markers, whitespace,
    // numeric-like, non-ASCII, quotes, and control characters.
    private let keyAlphabet: [Character] = Array("abXY01 .,-~^@#=|\"\\/éñ中🦞>")

    private func randKey(_ rng: inout KMRNG, _ maxlen: Int = 8) -> String {
        let n = Int(rng.next() % UInt64(maxlen + 1))
        var s = ""
        for _ in 0..<n { s.append(keyAlphabet[Int(rng.next() % UInt64(keyAlphabet.count))]) }
        return s
    }

    // A random scalar value: string (possibly collision-prone), int, double, bool, null.
    private func randValue(_ rng: inout KMRNG) -> Any {
        switch rng.next() % 6 {
        case 0: return randKey(&rng, 6)
        case 1: return Int(rng.next() % 1000) - 500
        case 2: return Double(Int(rng.next() % 10000)) / 100.0
        case 3: return (rng.next() & 1) == 0
        case 4: return NSNull()
        default:
            // Collision-prone strings that must be quoted to round-trip.
            let pool = ["true", "false", "-", "~", "123", "@x", "a|b", "", "  x"]
            return pool[Int(rng.next() % UInt64(pool.count))]
        }
    }

    /// Builds a map of `n` members. `fieldPool` names the possible value fields;
    /// each member picks a random non-empty subset so union / absent handling is
    /// exercised. Member keys are unique (a duplicate key is not valid JSON).
    private func randMap(_ rng: inout KMRNG, members n: Int, fieldPool: [String]) -> OrderedDictionary {
        let m = OrderedDictionary()
        var usedKeys = Set<String>()
        var made = 0
        var attempts = 0
        while made < n && attempts < n * 20 {
            attempts += 1
            let k = randKey(&rng)
            if usedKeys.contains(k) { continue }
            usedKeys.insert(k)
            let obj = OrderedDictionary()
            for f in fieldPool where (rng.next() & 1) == 0 {
                obj[f] = randValue(&rng)
            }
            // Ensure every value object is non-empty (an all-empty map is not keyed).
            if obj.isEmpty { obj[fieldPool[0]] = randValue(&rng) }
            m[k] = obj
            made += 1
        }
        return m
    }

    func testKeyedMapRoundTrip() throws {
        var rng = KMRNG(20260806)
        let pools: [[String]] = [
            ["cpu", "mem", "status"],
            ["a", "b"],
            ["key", "val"],          // triggers key-label collision (_key)
            ["x", "y", "z", "note"],
        ]
        var keyedCount = 0
        for _ in 0..<20000 {
            let n = 2 + Int(rng.next() % 5)  // 2..6 members
            let pool = pools[Int(rng.next() % UInt64(pools.count))]
            let map = randMap(&rng, members: n, fieldPool: pool)
            if map.count < 2 { continue }

            let encoded = encodeGeneric(map)
            let decoded = try decodeGeneric(encoded)
            XCTAssertTrue(deepEqual(map, decoded),
                          "round-trip failed\ninput keys=\(map.orderedKeys)\nwire:\n\(encoded)")

            // An eligible map (>=2 members, all non-empty objects, a column-eligible
            // field) MUST emit the keyed [N:] form, not section encoding.
            if keyedMapEligible(map) != nil {
                XCTAssertTrue(encoded.contains(":]{"),
                              "expected keyed form for eligible map\nwire:\n\(encoded)")
                keyedCount += 1
            }
        }
        // Guard against a vacuous run: the pools + member counts should make most
        // maps eligible, so the keyed branch must have been exercised heavily.
        XCTAssertGreaterThan(keyedCount, 1000, "keyed branch under-exercised (\(keyedCount))")
    }

    func testSingleMemberNeverKeyed() throws {
        var rng = KMRNG(7)
        for _ in 0..<2000 {
            let obj = OrderedDictionary()
            for f in ["a", "b", "c"] where (rng.next() & 1) == 0 { obj[f] = randValue(&rng) }
            if obj.isEmpty { obj["a"] = 1 }
            let m = OrderedDictionary()
            m[randKey(&rng)] = obj

            XCTAssertNil(keyedMapEligible(m), "single-member map must not be keyed")
            let encoded = encodeGeneric(m)
            XCTAssertFalse(encoded.contains(":]{"), "single-member map emitted keyed form\n\(encoded)")
            XCTAssertTrue(deepEqual(m, try decodeGeneric(encoded)), "single-member round-trip\n\(encoded)")
        }
    }

    func testAllGtValueFieldsFallBack() throws {
        // Every value field contains ">", so none can be a tabular column
        // (SPEC 7.4.6.1.4); the map must fall back to Section 7.2, not key.
        let m = OrderedDictionary()
        let a = OrderedDictionary(); a["x>y"] = 1
        let b = OrderedDictionary(); b["x>y"] = 2
        m["a"] = a
        m["b"] = b

        XCTAssertNil(keyedMapEligible(m), "all-'>' value fields must not be keyed")
        let encoded = encodeGeneric(m)
        XCTAssertFalse(encoded.contains(":]{"), "all-'>' map emitted keyed form\n\(encoded)")
        XCTAssertTrue(deepEqual(m, try decodeGeneric(encoded)), "all-'>' round-trip\n\(encoded)")
    }

    func testStreamingKeyedMapRoundTrip() throws {
        // The streaming encoder's [?:] output decodes back to the same map. Streaming
        // rows are positional over the declared fields (no "absent"), so every row
        // carries every pool field; a missing member field becomes explicit null.
        // The summary trailer count is validated by the decoder (SPEC 8.4, 7.2a.4).
        var rng = KMRNG(555)
        for _ in 0..<2000 {
            let pool = ["cpu", "mem", "status"]
            let n = 2 + Int(rng.next() % 5)
            let map = randMap(&rng, members: n, fieldPool: pool)
            if map.count < 2 { continue }

            let sink = KMStringSink()
            let enc = GenericStreamEncoder(writer: sink)
            enc.beginKeyedMap("m", keyLabel: "key", valueFields: pool)
            let expected = OrderedDictionary()
            for (k, v) in map.orderedPairs {
                let vo = v as! OrderedDictionary
                var row: [Any?] = [k]
                let evo = OrderedDictionary()
                for f in pool {
                    let cell = vo[f]
                    let norm: Any = (cell == nil || cell is NSNull) ? NSNull() : cell!
                    row.append(norm is NSNull ? nil : norm)
                    evo[f] = norm
                }
                enc.writeRow(row)
                expected[k] = evo
            }
            enc.endArray()
            try enc.close()

            let wrapper = OrderedDictionary()
            wrapper["m"] = expected
            let decoded = try decodeGeneric(sink.text)
            XCTAssertTrue(deepEqual(wrapper, decoded),
                          "streaming round-trip failed\nwire:\n\(sink.text)")
        }
    }

    func testNonObjectValueNotKeyed() throws {
        // A map with any non-object value uses Section 7.2 (SPEC 7.2a.1 clause 2).
        let m = OrderedDictionary()
        let a = OrderedDictionary(); a["v"] = 1
        m["a"] = a
        m["b"] = 42  // scalar value
        XCTAssertNil(keyedMapEligible(m))
        XCTAssertTrue(deepEqual(m, try decodeGeneric(encodeGeneric(m))))
    }
}

/// In-memory StreamWriter for exercising the streaming keyed-map encoder.
private final class KMStringSink: StreamWriter {
    private(set) var text = ""
    func write(_ string: String) { text += string }
}
