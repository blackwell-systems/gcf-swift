import XCTest
@testable import GCF

/// Mirrors gcf-go's generic_delta_session_test.go: the producer-side re-anchor
/// cadence contract and the load-bearing consumer-stays-in-sync invariant.
final class GenericDeltaSessionTests: XCTestCase {

    // MARK: - scenario builders

    private func sessBase() -> GenericSet {
        GenericSet(name: "orders", key: "id", fields: ["id", "total", "status", "customer"], rows: [
            ["id": 1001.0, "total": 59.98, "status": "shipped", "customer": "Alice"],
            ["id": 1002.0, "total": 29.99, "status": "pending", "customer": "Bob"],
            ["id": 1003.0, "total": 129.50, "status": "shipped", "customer": "Carol"],
        ])
    }

    private func sessUpdates() -> [GenericSet] {
        func mk(_ rows: [[String: Any]]) -> GenericSet {
            GenericSet(name: "orders", key: "id", fields: ["id", "total", "status", "customer"], rows: rows)
        }
        return [
            mk([
                ["id": 1001.0, "total": 59.98, "status": "shipped", "customer": "Alice"],
                ["id": 1002.0, "total": 29.99, "status": "shipped", "customer": "Bob"], // changed
                ["id": 1003.0, "total": 129.50, "status": "shipped", "customer": "Carol"],
            ]),
            mk([ // add 1004
                ["id": 1001.0, "total": 59.98, "status": "shipped", "customer": "Alice"],
                ["id": 1002.0, "total": 29.99, "status": "shipped", "customer": "Bob"],
                ["id": 1003.0, "total": 129.50, "status": "shipped", "customer": "Carol"],
                ["id": 1004.0, "total": 75.00, "status": "pending", "customer": "Dave"],
            ]),
            mk([ // remove 1001
                ["id": 1002.0, "total": 29.99, "status": "shipped", "customer": "Bob"],
                ["id": 1003.0, "total": 129.50, "status": "shipped", "customer": "Carol"],
                ["id": 1004.0, "total": 75.00, "status": "pending", "customer": "Dave"],
            ]),
            mk([ // change 1003
                ["id": 1002.0, "total": 29.99, "status": "shipped", "customer": "Bob"],
                ["id": 1003.0, "total": 140.00, "status": "delivered", "customer": "Carol"],
                ["id": 1004.0, "total": 75.00, "status": "pending", "customer": "Dave"],
            ]),
            mk([ // add 1005
                ["id": 1002.0, "total": 29.99, "status": "shipped", "customer": "Bob"],
                ["id": 1003.0, "total": 140.00, "status": "delivered", "customer": "Carol"],
                ["id": 1004.0, "total": 75.00, "status": "pending", "customer": "Dave"],
                ["id": 1005.0, "total": 12.00, "status": "pending", "customer": "Eve"],
            ]),
        ]
    }

    private func sizeGuardBase() -> GenericSet {
        let names = ["Alice", "Bob", "Carol", "Dave", "Eve", "Frank", "Grace", "Heidi",
                     "Ivan", "Judy", "Mallory", "Niaj", "Olivia", "Peggy", "Rupert", "Sybil",
                     "Trent", "Uma", "Victor", "Walter"]
        var rows: [[String: Any]] = []
        for (i, n) in names.enumerated() {
            rows.append(["id": Double(2000 + i), "total": Double(10 + i), "status": "pending", "customer": n])
        }
        return GenericSet(name: "rows", key: "id", fields: ["id", "total", "status", "customer"], rows: rows)
    }

    private func sizeGuardUpdates() -> [GenericSet] {
        let base = sizeGuardBase()
        var ups: [GenericSet] = []
        for turn in 0..<6 {
            var rows = base.rows
            rows[turn]["status"] = "shipped" // change one distinct row's status each turn
            ups.append(GenericSet(name: base.name, key: base.key, fields: base.fields, rows: rows))
        }
        return ups
    }

    // MARK: - unit tests

    func testSessionFixedNPattern() throws {
        let s = GenericDeltaSession(base: sessBase(), tool: "orders_query", policy: .fixed(3))
        let wantFull = [false, false, true, false, false] // re-anchor on turn 3
        for (i, up) in sessUpdates().enumerated() {
            let (_, isFull) = try s.next(up)
            XCTAssertEqual(isFull, wantFull[i], "turn \(i + 1)")
        }
    }

    func testSessionSizeGuardTriggers() throws {
        let s = GenericDeltaSession(base: sizeGuardBase(), tool: "", policy: .sizeGuard)
        var anchors = 0
        for up in sizeGuardUpdates() {
            let (_, isFull) = try s.next(up)
            if isFull { anchors += 1 }
        }
        XCTAssertGreaterThan(anchors, 0, "SizeGuard never re-anchored across 6 turns; scenario should trigger at least one")
    }

    func testSessionSchemaChangeReanchors() throws {
        let s = GenericDeltaSession(base: sessBase(), tool: "orders_query", policy: .fixed(15))
        var changed = sessBase()
        changed.fields = ["id", "total", "status"] // drop a column
        changed.rows = [["id": 1001.0, "total": 59.98, "status": "shipped"]]
        let (_, isFull) = try s.next(changed)
        XCTAssertTrue(isFull, "schema change must force a full re-anchor")
    }

    /// With N=15 over 30 update turns, exactly two emissions are full re-anchors
    /// (turns 15 and 30); the other 28 are deltas.
    func testSessionFixedN15Over30Turns() throws {
        let s = GenericDeltaSession(base: sessBase(), tool: "orders_query", policy: .fixed(15))
        _ = s.currentFull() // bootstrap full (turn 0), not counted below

        var fulls = 0, deltas = 0
        var fullTurns: [Int] = []
        var prev = sessBase()
        for turn in 1...30 {
            var rows: [[String: Any]] = []
            for (j, r) in prev.rows.enumerated() {
                var nr = r
                if j == turn % prev.rows.count { nr["total"] = Double(turn) + 0.5 }
                rows.append(nr)
            }
            let next = GenericSet(name: prev.name, key: prev.key, fields: prev.fields, rows: rows)
            let (_, isFull) = try s.next(next)
            if isFull { fulls += 1; fullTurns.append(turn) } else { deltas += 1 }
            prev = next
        }
        XCTAssertEqual(fulls, 2, "fulls")
        XCTAssertEqual(deltas, 28, "deltas")
        XCTAssertEqual(fullTurns, [15, 30], "full re-anchor turns")
    }

    /// The load-bearing test: a consumer that applies each emission (full ->
    /// decode, delta -> decode+verify) stays byte-for-byte in sync with the
    /// producer's state at every turn, under both policies.
    func testSessionConsumerStaysInSync() throws {
        let cases: [(name: String, base: GenericSet, ups: [GenericSet], tool: String, policy: ReanchorPolicy)] = [
            ("fixedN3", sessBase(), sessUpdates(), "orders_query", .fixed(3)),
            ("sizeGuard", sizeGuardBase(), sizeGuardUpdates(), "", .sizeGuard),
        ]
        for tc in cases {
            let s = GenericDeltaSession(base: tc.base, tool: tc.tool, policy: tc.policy)
            var held = try decodeGenericFull(s.currentFull()).set
            for (i, up) in tc.ups.enumerated() {
                let (wire, isFull) = try s.next(up)
                if isFull {
                    held = try decodeGenericFull(wire).set
                } else {
                    let d = try decodeGenericDelta(wire)
                    held = try verifyGenericDelta(held, d, expectedNewRoot: d.newRoot)
                }
                XCTAssertEqual(genericPackRoot(held), genericPackRoot(up),
                               "\(tc.name) turn \(i + 1): consumer root != producer root (isFull=\(isFull))")
            }
        }
    }
}
