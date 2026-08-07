import XCTest
@testable import GCF

// Fuzz/property tests for streaming tabular row VALUE quoting. A streaming cell
// that is a STRING colliding with a non-string token must be quoted so it
// decodes back as a string, matching the buffered tabular encoder (Section 2.4).
// The previous bespoke formatter only quoted empty strings and strings with "|"
// or newline, so a string like "true", "123", "-", or a leading "@"/"#"/"."
// was emitted bare and decoded back as the wrong type, breaking round-trip.

private struct ValueFuzzRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// In-memory StreamWriter accumulating streaming output for decoding.
private final class CaptureSink: StreamWriter {
    private(set) var text = ""
    func write(_ string: String) { text += string }
}

final class StreamValueQuoteTests: XCTestCase {
    // Adversarial STRING values: each collides with a non-string wire token and
    // must survive as a string. Plus benign control strings and escapes.
    private let collisionStrings: [String] = [
        "true", "false",           // Bool tokens
        "null", "nil",             // benign words (must stay strings)
        "123", "-7", "0", "4.5", "1e3", "-0.0",  // number tokens
        "-", "~", "^",             // null / missing / attachment markers
        "@x", "#x", ".dot",        // structural leading chars
        "+3", "0755",              // numeric-like leading
        "",                        // empty
        "a|b", "a,b",              // delimiter collisions
        "he\"llo", "back\\slash",  // quote / backslash
        "café", "日本語",            // non-ASCII
        "plain", "value 42",       // benign
    ]

    /// One random cell: returns (valueForRow, expectedAfterRoundtrip, isCollisionString).
    /// The bool flag marks a string that requires quoting, for liveness.
    private func randValue(_ rng: inout ValueFuzzRNG) -> (Any?, Any, Bool) {
        switch rng.next() % 8 {
        case 0: return (nil, NSNull(), false)
        case 1: let n = Int(rng.next() % 2000) - 1000; return (n, n, false)
        case 2: let b = (rng.next() % 2) == 0; return (b, b, false)
        case 3:
            // Real double that is not integer-valued (keeps a fractional part).
            let d = Double(rng.next() % 10000) / 100.0 + 0.5
            return (d, d, false)
        default:
            let s = collisionStrings[Int(rng.next() % UInt64(collisionStrings.count))]
            // A string that requires quoting is our liveness signal. Plain
            // strings ("plain", "null", etc.) do not, and that is fine.
            return (s, s, needsQuote(s))
        }
    }

    /// Fuzz: stream rows whose cell values mix adversarial strings with real
    /// bools/ints/doubles/null, decode, assert deep round-trip.
    func testFuzzStreamingValueQuoteRoundtrip() throws {
        var rng = ValueFuzzRNG(0xBADF00D)
        var sawCollisionString = false

        let iterations = 40000
        for iter in 0..<iterations {
            let cols = 1 + Int(rng.next() % 5)
            let fields = (0..<cols).map { "f\($0)" }

            let rowCount = 1 + Int(rng.next() % 4)
            var rows: [[Any?]] = []
            var expectedRecords: [Any] = []
            for _ in 0..<rowCount {
                var row: [Any?] = []
                let rec = OrderedDictionary()
                for f in fields {
                    let (v, exp, live) = randValue(&rng)
                    if live { sawCollisionString = true }
                    row.append(v)
                    rec[f] = exp
                }
                rows.append(row)
                expectedRecords.append(rec)
            }

            let sink = CaptureSink()
            let enc = GenericStreamEncoder(writer: sink)
            enc.beginArray("rows", fields: fields)
            for row in rows { enc.writeRow(row) }
            enc.endArray()
            try enc.close()

            // Decode the encoder's raw output directly: it emits the
            // "GCF profile=generic" header itself. Do NOT prepend anything.
            let wire = sink.text
            let decoded: Any
            do {
                decoded = try decodeGeneric(wire)
            } catch {
                XCTFail("iter \(iter): decode failed: \(error)\nwire:\n\(wire)")
                return
            }

            let expected = OrderedDictionary([("rows", expectedRecords)])
            XCTAssertTrue(deepEqual(expected, decoded),
                          "iter \(iter): round-trip mismatch\nexpected=\(expectedRecords)\nwire:\n\(wire)")
        }

        // Liveness: the fuzz must actually exercise value-collision strings,
        // otherwise it proves nothing about the value-quoting fix.
        XCTAssertTrue(sawCollisionString,
                      "fuzz never generated a value-collision string")
    }

    /// The canonical assertion: a STRING "true" must decode back to the String
    /// "true", not the Bool true. This is the exact bug the fix closes.
    func testStringTrueStaysString() throws {
        let sink = CaptureSink()
        let enc = GenericStreamEncoder(writer: sink)
        enc.beginArray("rows", fields: ["flag", "real"])
        // Cell 1: the STRING "true". Cell 2: the real Bool true.
        enc.writeRow(["true", true])
        enc.endArray()
        try enc.close()

        let decoded = try decodeGeneric(sink.text)
        let top = try XCTUnwrap(decoded as? OrderedDictionary)
        let arr = try XCTUnwrap(top["rows"] as? [Any])
        let rec = try XCTUnwrap(arr.first as? OrderedDictionary)

        // The string cell must come back as a String, never a Bool.
        XCTAssertEqual(rec["flag"] as? String, "true",
                       "string \"true\" must decode as String, got \(String(describing: rec["flag"]))")
        XCTAssertNil(rec["flag"] as? Bool,
                     "string \"true\" must not decode as Bool")

        // The real Bool cell must stay a Bool.
        XCTAssertEqual(rec["real"] as? Bool, true)
    }

    /// A numeric-looking string and marker strings must stay strings.
    func testNumericAndMarkerStringsStayStrings() throws {
        let sink = CaptureSink()
        let enc = GenericStreamEncoder(writer: sink)
        enc.beginArray("rows", fields: ["s", "m", "n"])
        enc.writeRow(["123", "-", "4.5"])
        enc.endArray()
        try enc.close()

        let decoded = try decodeGeneric(sink.text)
        let top = try XCTUnwrap(decoded as? OrderedDictionary)
        let arr = try XCTUnwrap(top["rows"] as? [Any])
        let rec = try XCTUnwrap(arr.first as? OrderedDictionary)

        XCTAssertEqual(rec["s"] as? String, "123")
        XCTAssertEqual(rec["m"] as? String, "-")
        XCTAssertEqual(rec["n"] as? String, "4.5")
        // "-" as a string must not decode to null.
        XCTAssertFalse(rec["m"] is NSNull, "string \"-\" must not decode as null")
    }

    /// Real null (nil) stays null: the fix must not break the "-" null path.
    func testRealNullStillNull() throws {
        let sink = CaptureSink()
        let enc = GenericStreamEncoder(writer: sink)
        enc.beginArray("rows", fields: ["v"])
        enc.writeRow([nil])
        enc.endArray()
        try enc.close()

        let decoded = try decodeGeneric(sink.text)
        let top = try XCTUnwrap(decoded as? OrderedDictionary)
        let arr = try XCTUnwrap(top["rows"] as? [Any])
        let rec = try XCTUnwrap(arr.first as? OrderedDictionary)
        XCTAssertTrue(rec["v"] is NSNull, "nil must decode as null")
    }
}
