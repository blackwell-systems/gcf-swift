import XCTest
import Foundation
@testable import GCF

/// Unit tests for generic-profile delta (SPEC Section 10a). Mirrors the Go/Python/
/// TypeScript/Rust suites.
final class GenericDeltaTests: XCTestCase {

    private func ordersBase() -> GenericSet {
        GenericSet(name: "orders", key: "id", fields: ["id", "total", "status", "customer"], rows: [
            ["id": 1001, "total": 59.98, "status": "shipped", "customer": "Alice"],
            ["id": 1002, "total": 29.99, "status": "pending", "customer": "Bob"],
            ["id": 1003, "total": 129.50, "status": "shipped", "customer": "Carol"],
        ])
    }

    private func ordersNext() -> GenericSet {
        GenericSet(name: "orders", key: "id", fields: ["id", "total", "status", "customer"], rows: [
            ["id": 1002, "total": 29.99, "status": "shipped", "customer": "Bob"],
            ["id": 1003, "total": 129.50, "status": "shipped", "customer": "Carol"],
            ["id": 1004, "total": 75.00, "status": "pending", "customer": "Dave"],
        ])
    }

    func testRoundTripByRoot() throws {
        let base = ordersBase(), next = ordersNext()
        let d = try diffGenericSets(base, next)
        XCTAssertEqual(d.added.count, 1)
        XCTAssertEqual(d.changed.count, 1)
        XCTAssertEqual(d.removed.count, 1)
        XCTAssertEqual(d.newRoot, genericPackRoot(next))
        let result = try verifyGenericDelta(base, d, expectedNewRoot: genericPackRoot(next))
        XCTAssertEqual(genericPackRoot(result), genericPackRoot(next))
    }

    func testPackRootRowOrderInvariant() {
        var b = ordersBase()
        b.rows = [b.rows[2], b.rows[0], b.rows[1]]
        XCTAssertEqual(genericPackRoot(ordersBase()), genericPackRoot(b))
    }

    func testCanonicalCellNoCollision() {
        XCTAssertEqual(canonicalCell(nil), "-")
        XCTAssertEqual(canonicalCell(NSNull()), "-")
        XCTAssertEqual(canonicalCell(true), "true")
        XCTAssertEqual(canonicalCell("true"), "\"true\"")
        XCTAssertEqual(canonicalCell("-"), "\"-\"")
        XCTAssertEqual(canonicalCell(59.98), "59.98")
        XCTAssertEqual(canonicalCell("59.98"), "\"59.98\"")
        XCTAssertEqual(canonicalCell("a\tb"), "\"a\\tb\"")
    }

    func testInvariants() throws {
        let base = ordersBase()
        let baseRoot = genericPackRoot(base)

        var dup = ordersBase()
        dup.rows.append(["id": 1001, "total": 1.0, "status": "x", "customer": "y"])
        XCTAssertThrowsError(try diffGenericSets(dup, ordersNext())) {
            XCTAssertTrue("\($0)".contains("duplicate identity"))
        }

        var sc = ordersNext()
        sc.fields = ["id", "total", "status"]
        XCTAssertThrowsError(try diffGenericSets(base, sc)) {
            XCTAssertTrue("\($0)".contains("schema change"))
        }

        let addExisting = GenericDeltaPayload(key: "id", fields: base.fields, baseRoot: baseRoot,
            added: [["id": 1001, "total": 1.0, "status": "s", "customer": "c"]])
        XCTAssertThrowsError(try verifyGenericDelta(base, addExisting, expectedNewRoot: "sha256:x")) {
            XCTAssertTrue("\($0)".contains("already exists"))
        }

        let changeMissing = GenericDeltaPayload(key: "id", fields: base.fields, baseRoot: baseRoot,
            changed: [["id": 9999, "total": 1.0, "status": "s", "customer": "c"]])
        XCTAssertThrowsError(try verifyGenericDelta(base, changeMissing, expectedNewRoot: "sha256:x")) {
            XCTAssertTrue("\($0)".contains("not in base"))
        }

        let removeMissing = GenericDeltaPayload(key: "id", fields: base.fields, baseRoot: baseRoot,
            removed: [9999])
        XCTAssertThrowsError(try verifyGenericDelta(base, removeMissing, expectedNewRoot: "sha256:x")) {
            XCTAssertTrue("\($0)".contains("not in base"))
        }

        let wrongBase = GenericDeltaPayload(key: "id", fields: base.fields, baseRoot: "sha256:wrong")
        XCTAssertThrowsError(try verifyGenericDelta(base, wrongBase, expectedNewRoot: baseRoot)) {
            XCTAssertTrue("\($0)".contains("base_mismatch"))
        }

        let d = try diffGenericSets(base, ordersNext())
        XCTAssertThrowsError(try verifyGenericDelta(base, d, expectedNewRoot: "sha256:deadbeef")) {
            XCTAssertTrue("\($0)".contains("root_mismatch"))
        }
    }

    func testFullWireRoundTrip() throws {
        let base = ordersBase()
        let (got, pr) = try decodeGenericFull(encodeGenericFull(base, tool: "orders_query"))
        XCTAssertEqual(genericPackRoot(got), genericPackRoot(base))
        XCTAssertEqual(pr, genericPackRoot(base))
    }

    func testEndToEnd() throws {
        let base = ordersBase(), next = ordersNext()
        let (held, _) = try decodeGenericFull(encodeGenericFull(base, tool: "orders_query"))
        let d = try diffGenericSets(base, next)
        let parsed = try decodeGenericDelta(encodeGenericDelta(d))
        let result = try verifyGenericDelta(held, parsed, expectedNewRoot: genericPackRoot(next))
        XCTAssertEqual(genericPackRoot(result), genericPackRoot(next))
    }

    func testNullsAndStringKeys() throws {
        let nulls = GenericSet(name: "items", key: "id", fields: ["id", "total", "status", "customer"], rows: [
            ["id": 2001, "total": 10.0, "status": NSNull(), "customer": "Amy"],
            ["id": 2002, "total": NSNull(), "status": "open", "customer": NSNull()],
        ])
        let (got, _) = try decodeGenericFull(encodeGenericFull(nulls, tool: ""))
        XCTAssertEqual(genericPackRoot(got), genericPackRoot(nulls))

        let sku = GenericSet(name: "parts", key: "sku", fields: ["sku", "name", "qty"], rows: [
            ["sku": "1001", "name": "Widget", "qty": 5],
            ["sku": "A-200", "name": "Gadget", "qty": 3],
        ])
        let (got2, _) = try decodeGenericFull(encodeGenericFull(sku, tool: ""))
        XCTAssertEqual(genericPackRoot(got2), genericPackRoot(sku))
    }

    func testDecodeMalformedFailsClosed() {
        let cases = [
            "",
            "GCF profile=graph delta=true base_root=a new_root=b key=id\n",
            "GCF profile=generic pack_root=r key=id\n## t [1]{@id}\n1\n",
            "GCF profile=generic delta=true base_root=a new_root=b key=id\n## added [2]{@id,x}\n1|2\n",
            "GCF profile=generic delta=true base_root=a new_root=b key=id\n## added [1]{@id,x}\n1\n",
            "GCF profile=generic delta=true base_root=a new_root=b key=id\n## bogus [1]{@id}\n1\n",
            "GCF profile=generic delta=true base_root=a new_root=b key=id\n## added [01]{@id,x}\n1|2\n",
        ]
        for wire in cases {
            XCTAssertThrowsError(try decodeGenericDelta(wire), "expected error for \(wire.debugDescription)")
        }
    }
}
