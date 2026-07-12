import XCTest
import Foundation
@testable import GCF

/// Runs the shared cross-SDK conformance fixtures (gcf/tests/conformance) against
/// the Swift implementation, mirroring the TypeScript/Go/Rust/Python/Kotlin runners.
/// Skips only session/delta/pack-root/delta-verify and binary inputs (as the others do).
final class ConformanceV2Test: XCTestCase {

    /// The shared fixtures live in the sibling gcf repo. Resolve relative to this
    /// source file so it works regardless of the test's working directory; skip if
    /// the sibling checkout is absent (e.g. CI without the gcf repo).
    private static func fixtureDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GCFTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // gcf-swift
            .deletingLastPathComponent()  // parent
            .appendingPathComponent("gcf/tests/conformance")
    }

    func testConformance() throws {
        let dir = Self.fixtureDir()
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("conformance fixtures not found at \(dir.path)")
        }

        var files: [URL] = []
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            if url.pathExtension == "json" { files.append(url) }
        }
        files.sort { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty, "no fixtures found in \(dir.path)")

        var ran = 0, skipped = 0
        for url in files {
            let rel = url.path.replacingOccurrences(of: dir.path + "/", with: "")
            guard let data = try? Data(contentsOf: url),
                  let fx = (try? parseJSONOrdered(data)) as? OrderedDictionary
            else {
                XCTFail("cannot parse fixture \(rel)")
                continue
            }
            let op = fx["operation"] as? String ?? ""
            if ["session", "delta", "pack-root", "delta-verify"].contains(op) || fx["inputBase64"] != nil {
                skipped += 1
                continue
            }
            do {
                try runFixture(rel: rel, op: op, fx: fx)
                ran += 1
            } catch let skip as XCTSkip {
                _ = skip
                skipped += 1
            } catch {
                XCTFail("\(rel): \(error)")
            }
        }
        print("Conformance: \(ran) ran, \(skipped) skipped, of \(files.count) fixtures")
        XCTAssertGreaterThan(ran, 0)
    }

    private func runFixture(rel: String, op: String, fx: OrderedDictionary) throws {
        switch op {
        case "encode":
            let expected = fx["expected"] as? String ?? ""
            if expected.hasPrefix("GCF profile=graph") {
                let got = encode(toPayload(fx["input"]))
                XCTAssertEqual(got, expected, rel)
            } else {
                let input = fx["input"] ?? NSNull()
                let got = encodeGeneric(input)
                // The v3 encoder produces different (still lossless) bytes for these
                // dirs; they are round-trip-checked but not byte-matched (as in the TS runner).
                // scalar/022 is a deliberate Swift-only divergence: the encoder quotes any
                // non-ASCII scalar (grapheme-cluster safety; see needsQuote), so an emoji
                // string is quoted where other SDKs leave it bare. Still round-trips.
                let v3Affected = rel.hasPrefix("attachments/") || rel.hasPrefix("arrays/")
                    || rel == "scalar/022_string_surrogate_pair.json"
                if !v3Affected { XCTAssertEqual(got, expected, rel) }
                let decoded = try decodeGeneric(got)
                XCTAssertTrue(deepEqual(input, decoded), "round-trip \(rel)")
            }
        case "decode":
            let input = fx["input"] as? String ?? ""
            let got = try decodeGeneric(input)
            XCTAssertTrue(subset(serializable(fx["expected"] ?? NSNull()), serializable(got)),
                          "decode subset \(rel)")
        case "roundtrip":
            let expected = fx["expected"] as? String ?? ""
            let input = fx["input"] ?? NSNull()
            let got = encodeGeneric(input)
            XCTAssertEqual(got, expected, rel)
            let decoded = try decodeGeneric(got)
            XCTAssertTrue(deepEqual(input, decoded), "round-trip \(rel)")
        case "error":
            let input = fx["input"] as? String ?? ""
            XCTAssertThrowsError(try decodeGeneric(input), rel)
        case "generic-pack-root":
            XCTAssertEqual(genericPackRoot(toSet(fx["input"])), fx["expected"] as? String ?? "", rel)
        case "generic-delta":
            XCTAssertEqual(encodeGenericDelta(toDelta(fx["input"])), fx["expected"] as? String ?? "", rel)
        case "generic-delta-verify", "generic-delta-decode":
            let inp = fx["input"] as? OrderedDictionary
            let base = toSet(inp?["base"])
            let expNewRoot = inp?["expectedNewRoot"] as? String ?? ""
            let apply: () throws -> GenericSet
            if op == "generic-delta-verify" {
                let d = toDelta(inp?["delta"])
                apply = { try verifyGenericDelta(base, d, expectedNewRoot: expNewRoot) }
            } else {
                let wire = inp?["wire"] as? String ?? ""
                apply = { try verifyGenericDelta(base, try decodeGenericDelta(wire), expectedNewRoot: expNewRoot) }
            }
            if let expErr = fx["expectedError"] as? String {
                XCTAssertThrowsError(try apply(), rel) { err in
                    XCTAssertTrue("\(err)".contains(expErr), "\(rel): expected '\(expErr)', got \(err)")
                }
            } else {
                XCTAssertEqual(genericPackRoot(try apply()), fx["expected"] as? String ?? "", rel)
            }
        case "generic-delta-session":
            try runGenericDeltaSession(rel: rel, fx: fx)
        case "graph-stream-encode":
            let expected = fx["expected"] as? String ?? ""
            let payload = toPayload(fx["input"])
            let sink = StringSink()
            let opts = StreamOptions(tokenBudget: payload.tokenBudget,
                                     tokensUsed: payload.tokensUsed,
                                     packRoot: payload.packRoot)
            let enc = StreamEncoder(writer: sink, tool: payload.tool, options: opts)
            for sym in payload.symbols { enc.writeSymbol(sym) }
            for edge in payload.edges { enc.writeEdge(edge) }
            enc.close()
            XCTAssertEqual(sink.text, expected, rel)
        default:
            throw XCTSkip("unsupported operation: \(op)")
        }
    }

    /// Drives a `GenericDeltaSession` through the fixture's updates and checks the
    /// initial full plus every (isFull, wire) emission: the producer-side
    /// re-anchor cadence contract, byte-identical across SDKs.
    private func runGenericDeltaSession(rel: String, fx: OrderedDictionary) throws {
        let inp = fx["input"] as? OrderedDictionary
        let base = toSet(inp?["base"])
        let tool = inp?["tool"] as? String ?? ""

        let policyOD = inp?["policy"] as? OrderedDictionary
        let mode = policyOD?["mode"] as? String ?? ""
        let policy: ReanchorPolicy
        if mode == "sizeGuard" {
            policy = .sizeGuard
        } else {
            policy = .fixed((policyOD?["n"] as? NSNumber)?.intValue ?? 0)
        }

        let updates = (inp?["updates"] as? [Any] ?? []).map { toSet($0) }

        let exp = fx["expected"] as? OrderedDictionary
        let initialFull = exp?["initialFull"] as? String ?? ""
        let emissions = exp?["emissions"] as? [Any] ?? []

        let s = GenericDeltaSession(base: base, tool: tool, policy: policy)
        XCTAssertEqual(s.currentFull(), initialFull, "\(rel): initial full")

        for (i, up) in updates.enumerated() {
            let (wire, isFull) = try s.next(up)
            guard i < emissions.count, let em = emissions[i] as? OrderedDictionary else {
                XCTFail("\(rel) turn \(i + 1): no expected emission")
                continue
            }
            XCTAssertEqual(isFull, (em["isFull"] as? Bool) ?? false, "\(rel) turn \(i + 1): isFull")
            XCTAssertEqual(wire, em["wire"] as? String ?? "", "\(rel) turn \(i + 1): wire")
        }
    }

    // MARK: - Generic-delta fixture builders

    private func toRow(_ v: Any?) -> [String: Any] {
        guard let od = v as? OrderedDictionary else { return [:] }
        var m: [String: Any] = [:]
        for (k, val) in od.orderedPairs { m[k] = val }
        return m
    }

    private func toRows(_ v: Any?) -> [[String: Any]] {
        (v as? [Any])?.map { toRow($0) } ?? []
    }

    private func toFields(_ v: Any?) -> [String] {
        (v as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private func toSet(_ v: Any?) -> GenericSet {
        let od = v as? OrderedDictionary
        return GenericSet(name: od?["name"] as? String ?? "",
                          key: od?["key"] as? String ?? "",
                          fields: toFields(od?["fields"]),
                          rows: toRows(od?["rows"]))
    }

    private func toDelta(_ v: Any?) -> GenericDeltaPayload {
        let od = v as? OrderedDictionary
        return GenericDeltaPayload(
            tool: od?["tool"] as? String ?? "",
            key: od?["key"] as? String ?? "",
            fields: toFields(od?["fields"]),
            baseRoot: od?["baseRoot"] as? String ?? "",
            newRoot: od?["newRoot"] as? String ?? "",
            added: toRows(od?["added"]),
            changed: toRows(od?["changed"]),
            removed: (od?["removed"] as? [Any]) ?? [],
            deltaTokens: (od?["deltaTokens"] as? Int) ?? 0,
            fullTokens: (od?["fullTokens"] as? Int) ?? 0)
    }

    // MARK: - Helpers

    /// Build a graph Payload from a fixture input (core fields only, matching the
    /// other SDK runners; defaulted fields fill the rest).
    private func toPayload(_ v: Any?) -> Payload {
        guard let od = v as? OrderedDictionary else { return Payload(tool: "") }
        func s(_ x: Any?) -> String { x as? String ?? "" }
        func i(_ x: Any?) -> Int { (x as? NSNumber)?.intValue ?? 0 }
        func d(_ x: Any?) -> Double { (x as? NSNumber)?.doubleValue ?? 0 }
        var symbols: [Symbol] = []
        for case let sym as OrderedDictionary in (od["symbols"] as? [Any] ?? []) {
            symbols.append(Symbol(qualifiedName: s(sym["qualifiedName"]), kind: s(sym["kind"]),
                                  score: d(sym["score"]), provenance: s(sym["provenance"]),
                                  distance: i(sym["distance"])))
        }
        var edges: [Edge] = []
        for case let edge as OrderedDictionary in (od["edges"] as? [Any] ?? []) {
            edges.append(Edge(source: s(edge["source"]), target: s(edge["target"]),
                              edgeType: s(edge["edgeType"]), status: s(edge["status"])))
        }
        return Payload(tool: s(od["tool"]), tokensUsed: i(od["tokensUsed"]),
                       tokenBudget: i(od["tokenBudget"]), packRoot: s(od["packRoot"]),
                       symbols: symbols, edges: edges)
    }

    /// Convert OrderedDictionary/array/scalar into JSON-serializable Swift values.
    private func serializable(_ v: Any) -> Any {
        if let od = v as? OrderedDictionary {
            var out: [String: Any] = [:]
            for (k, val) in od.orderedPairs { out[k] = serializable(val) }
            return out
        }
        if let arr = v as? [Any] { return arr.map { serializable($0) } }
        return v
    }

    /// Sorted-key JSON string for order-insensitive structural comparison.
    private func norm(_ v: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: serializable(v), options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "<unserializable>" }
        return str
    }

    /// Every key/element present in `expected` must be present and equal in `got`.
    private func subset(_ expected: Any, _ got: Any) -> Bool {
        if expected is NSNull { return got is NSNull }
        if let ed = expected as? [String: Any] {
            guard let gd = got as? [String: Any] else { return false }
            return ed.allSatisfy { subset($0.value, gd[$0.key] ?? NSNull()) }
        }
        if let ea = expected as? [Any] {
            guard let ga = got as? [Any], ga.count == ea.count else { return false }
            return zip(ea, ga).allSatisfy { subset($0, $1) }
        }
        if let en = expected as? NSNumber, let gn = got as? NSNumber { return en == gn }
        return "\(expected)" == "\(got)"
    }
}

/// In-memory StreamWriter that accumulates the streaming encoder output so a
/// conformance fixture can compare the full string against its expected value.
private final class StringSink: StreamWriter {
    private(set) var text = ""
    func write(_ string: String) { text += string }
}
