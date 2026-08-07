import XCTest
@testable import GCF

// Fuzz/property tests for the generic streaming tabular header (mirrors
// gcf-go stream_fielddecl_test.go). The streaming header must quote the section
// name and every field name per Section 2.4 (via formatKey), matching the
// buffered tabular header, so a field name containing a delimiter or quote
// produces a valid, unambiguous header that round-trips. A field name
// containing ">" is a flattened path a streaming row cannot represent
// (Section 8.3) and is rejected.

private struct StreamFuzzRNG: RandomNumberGenerator {
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

final class StreamFieldDeclTests: XCTestCase {
    // Adversarial name atoms: delimiters, quotes, empty, structural prefixes,
    // spaces, unicode. Deliberately excludes ">" (tested separately: it is
    // rejected, not quoted).
    private let nameAtoms: [String] = [
        "id", "name", "value",
        "a,b", "c|d", "e\"f", "g\\h",
        "", " ", "  leading", "trailing ", "mid space",
        "@at", "#hash", ".dot", "-dash", "=eq", "~tilde", "^caret",
        "0num", "with:colon", "brace{x}", "tab\tx", "newline\nx",
        "café", "naïve", "日本語", "🦞claw",
    ]

    private func randName(_ rng: inout StreamFuzzRNG) -> String {
        return nameAtoms[Int(rng.next() % UInt64(nameAtoms.count))]
    }

    // Random scalar cell values covering the type space the encoder formats.
    // Returns (valueForRow, expectedAfterRoundtrip). nil rows encode as "-"
    // and decode to NSNull.
    private func randValue(_ rng: inout StreamFuzzRNG) -> (Any?, Any) {
        switch rng.next() % 7 {
        case 0: return (nil, NSNull())
        case 1: let n = Int(rng.next() % 1000) - 500; return (n, n)
        case 2: let b = (rng.next() % 2) == 0; return (b, b)
        case 3: return ("plain", "plain")
        case 4: return ("has|pipe", "has|pipe")
        case 5: return ("", "")
        default: let s = "val\(rng.next() % 100)"; return (s, s)
        }
    }

    /// Fuzz: stream an array with adversarial (quoting-needed) field names and
    /// random rows, decode, assert deep round-trip.
    func testFuzzStreamingFieldDeclRoundtrip() throws {
        var rng = StreamFuzzRNG(0xC0FFEE)
        var sawQuotingNeededName = false

        let iterations = 60000
        for iter in 0..<iterations {
            // 1..5 distinct field names (dedup so no duplicate columns).
            let want = 1 + Int(rng.next() % 5)
            var fields: [String] = []
            var seen = Set<String>()
            var guardN = 0
            while fields.count < want && guardN < 50 {
                guardN += 1
                let n = randName(&rng)
                if seen.contains(n) { continue }
                seen.insert(n)
                fields.append(n)
                if !isBareKey(n) { sawQuotingNeededName = true }
            }
            if fields.isEmpty { continue }

            let rawName = randName(&rng)
            // A blank section name would emit "## " (an object section), not an
            // array header, so give it a stable name when the fuzz picks empty.
            let name = rawName.isEmpty ? "rows" : rawName

            // 0..4 rows, one cell per field. Build the expected decoded tree in
            // parallel so we can compare with deepEqual.
            let rowCount = Int(rng.next() % 5)
            var rows: [[Any?]] = []
            var expectedRecords: [Any] = []
            for _ in 0..<rowCount {
                var row: [Any?] = []
                let rec = OrderedDictionary()
                for f in fields {
                    let (v, exp) = randValue(&rng)
                    row.append(v)
                    rec[f] = exp
                }
                rows.append(row)
                expectedRecords.append(rec)
            }

            let sink = CaptureSink()
            let enc = GenericStreamEncoder(writer: sink)
            enc.beginArray(name, fields: fields)
            for row in rows { enc.writeRow(row) }
            enc.endArray()
            try enc.close()

            let wire = sink.text
            let decoded: Any
            do {
                decoded = try decodeGeneric(wire)
            } catch {
                XCTFail("iter \(iter): decode failed: \(error)\nfields=\(fields)\nwire:\n\(wire)")
                return
            }

            let expected = OrderedDictionary([(name, expectedRecords)])
            XCTAssertTrue(deepEqual(expected, decoded),
                          "iter \(iter): round-trip mismatch\nfields=\(fields)\nexpected=\(expectedRecords)\nwire:\n\(wire)")
        }

        // Liveness: the fuzz must actually exercise names that require quoting,
        // otherwise it proves nothing about the header-quoting fix.
        XCTAssertTrue(sawQuotingNeededName,
                      "fuzz never generated a field name that requires quoting")
    }

    /// A field name containing ">" is a flattened path not representable in a
    /// streaming row (Section 8.3): beginArray records the error and close()
    /// surfaces it.
    func testStreamingGtFieldRejected() {
        let sink = CaptureSink()
        let enc = GenericStreamEncoder(writer: sink)
        enc.beginArray("rows", fields: ["id", "a>b"])
        enc.writeRow([1, "x"])
        enc.endArray()
        XCTAssertThrowsError(try enc.close()) { error in
            guard let gcf = error as? GCFError else {
                XCTFail("expected GCFError, got \(error)")
                return
            }
            XCTAssertTrue("\(gcf)".contains(">"),
                          "error should mention the '>' field: \(gcf)")
        }
        // A rejected header must not have been written.
        XCTAssertFalse(sink.text.contains("a>b"), "rejected header should not be emitted")
    }

    /// A clean array with no ">" field closes without throwing.
    func testStreamingCleanCloseDoesNotThrow() throws {
        let sink = CaptureSink()
        let enc = GenericStreamEncoder(writer: sink)
        enc.beginArray("rows", fields: ["id", "name"])
        enc.writeRow([1, "Alice"])
        enc.endArray()
        try enc.close()
        XCTAssertTrue(sink.text.contains("## rows [?]{id,name}"))
    }

    /// A comma-bearing field name is quoted in the header, not split.
    func testCommaFieldQuotedInHeader() throws {
        let sink = CaptureSink()
        let enc = GenericStreamEncoder(writer: sink)
        enc.beginArray("rows", fields: ["id", "a,b"])
        enc.writeRow([1, 99])
        enc.endArray()
        try enc.close()
        XCTAssertTrue(sink.text.contains("## rows [?]{id,\"a,b\"}"),
                      "header should quote the comma field: \(sink.text)")
        let decoded = try decodeGeneric(sink.text)
        let top = try XCTUnwrap(decoded as? OrderedDictionary)
        let arr = try XCTUnwrap(top["rows"] as? [Any])
        let rec = try XCTUnwrap(arr.first as? OrderedDictionary)
        XCTAssertEqual(rec["a,b"] as? Int, 99)
        XCTAssertFalse(rec.contains("a"), "comma field must not split into a column")
    }
}
