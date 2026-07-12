import XCTest
@testable import GCF

// Fuzz/property tests for generic-profile delta (mirrors gcf-go FuzzGeneric*):
//  A. decodeGenericDelta / decodeGenericFull never crash on arbitrary / mutated input.
//  B. arbitrary string cells survive the full-wire round-trip with the pack root preserved.

private struct FuzzRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

final class GenericDeltaFuzzTests: XCTestCase {
    private let alphabet: [Character] = Array("abcXYZ0129 .,-~^@#=|\t\n\r\"\\/éñ中🦞")

    private func randStr(_ rng: inout FuzzRNG, _ maxlen: Int = 20) -> String {
        let n = Int(rng.next() % UInt64(maxlen + 1))
        var s = ""
        for _ in 0..<n { s.append(alphabet[Int(rng.next() % UInt64(alphabet.count))]) }
        return s
    }

    func testFuzzStringCellRoundtrip() throws {
        var rng = FuzzRNG(1234)
        for _ in 0..<20000 {
            let a = randStr(&rng)
            let b = randStr(&rng)
            let s = GenericSet(name: "t", key: "id", fields: ["id", "a", "b"], rows: [
                ["id": 1, "a": a, "b": b],
                ["id": 2, "a": b, "b": a],
            ])
            let (got, _) = try decodeGenericFull(encodeGenericFull(s, tool: ""))
            XCTAssertEqual(genericPackRoot(got), genericPackRoot(s),
                           "a=\(a.debugDescription) b=\(b.debugDescription)")
        }
    }

    func testFuzzDecodeNeverCrashes() {
        var rng = FuzzRNG(99)
        let seeds = [
            "GCF profile=generic delta=true base_root=a new_root=b key=id\n## added [1]{@id,x}\n1|2\n",
            "GCF profile=generic pack_root=r key=id\n## t [2]{@id,x}\n1|2\n3|4\n",
            "## removed [1]{@id}\n99\n",
            "",
        ]
        for _ in 0..<20000 {
            let data: String
            if (rng.next() % 1000) < 500 {
                data = randStr(&rng, 80)
            } else {
                var chars = Array(seeds[Int(rng.next() % UInt64(seeds.count))])
                let m = Int(rng.next() % 6)
                for _ in 0..<m where !chars.isEmpty {
                    chars[Int(rng.next() % UInt64(chars.count))] = alphabet[Int(rng.next() % UInt64(alphabet.count))]
                }
                data = String(chars)
            }
            _ = try? decodeGenericDelta(data)
            _ = try? decodeGenericFull(data)
        }
    }
}
