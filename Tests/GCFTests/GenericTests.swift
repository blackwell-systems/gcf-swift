import XCTest
@testable import GCF

final class GenericTests: XCTestCase {

    func testNoFlattenOption() {
        let data: [String: Any] = [
            "orders": [
                ["id": "ORD-1", "customer": ["name": "Alice", "email": "alice@co.com"], "total": 99.99],
                ["id": "ORD-2", "customer": ["name": "Bob", "email": "bob@co.com"], "total": 49.99],
            ] as [[String: Any]]
        ]

        let withFlatten = encodeGeneric(data)
        XCTAssertTrue(withFlatten.contains("customer>"), "Expected path columns with default")

        let noFlatten = encodeGeneric(data, opts: GenericOptions(noFlatten: true))
        XCTAssertFalse(noFlatten.contains("customer>"), "Expected no path columns with noFlatten")
        XCTAssertTrue(noFlatten.contains(".customer"), "Expected attachment syntax with noFlatten")
    }

    func testGtFieldEdgeCases() throws {
        let cases: [(String, Any)] = [
            ("literal > key", [[">": 1], [">": 2]] as [[String: Any]]),
            ("> at start", [[">foo": "a", "id": 1], [">foo": "b", "id": 2]] as [[String: Any]]),
            ("> at end", [["foo>": "a", "id": 1], ["foo>": "b", "id": 2]] as [[String: Any]]),
            ("double >>", [["a>>b": "x"], ["a>>b": "y"]] as [[String: Any]]),
            ("multiple > in key", [["a>b>c": "x"], ["a>b>c": "y"]] as [[String: Any]]),
            ("> field with null", [["a>b": NSNull(), "id": 1], ["a>b": "hello", "id": 2]] as [[String: Any]]),
            ("> field with object", [["a>b": ["x": 1], "id": 1], ["a>b": ["x": 2], "id": 2]] as [[String: Any]]),
            ("> field with array", [["a>b": [1, 2], "id": 1], ["a>b": [3], "id": 2]] as [[String: Any]]),
            ("all fields have >", [[">": 1, "a>b": 2], [">": 3, "a>b": 4]] as [[String: Any]]),
            ("mix of > literal and flattened", [
                ["id": 1, "x>y": "lit", "nested": ["a": "v1", "b": "v2"]],
                ["id": 2, "x>y": "lit2", "nested": ["a": "v3", "b": "v4"]],
            ] as [[String: Any]]),
            ("key looks like flattened path", [
                ["id": 1, "customer>name": "Alice"],
                ["id": 2, "customer>name": "Bob"],
            ] as [[String: Any]]),
        ]

        for (name, data) in cases {
            for noFlatten in [false, true] {
                let encoded = encodeGeneric(data, opts: GenericOptions(noFlatten: noFlatten))
                let decoded = try decodeGeneric(encoded)
                let a = jsonNormalize(data)
                let b = jsonNormalize(decoded)
                XCTAssertEqual(a, b, "\(name) (noFlatten=\(noFlatten)): round-trip mismatch\n  gcf: \(encoded)")
            }
        }
    }

    /// Normalize through JSON for comparison (handles key ordering, NSNull, etc).
    private func jsonNormalize(_ v: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
