import Foundation
import CryptoKit

// MARK: - Generic-profile delta encoding (SPEC Section 10a)
//
// Full producer + consumer for keyed-row deltas over the generic profile,
// byte-for-byte interoperable with gcf-go, gcf-python, gcf-typescript, and
// gcf-rust. Delta is opt-in and bilateral; the existing encodeGeneric path is
// unchanged.

/// A keyed record set: the unit generic-profile delta operates on (Section 10a).
/// Rows are order-agnostic (set semantics); `fields` carries the declared column
/// order for the wire form; `key` names the identity column (the `@id` / `key=`);
/// `name` is the tabular section name for a full payload.
public struct GenericSet {
    public var name: String
    public var key: String
    public var fields: [String]
    public var rows: [[String: Any]]

    public init(name: String = "", key: String, fields: [String], rows: [[String: Any]]) {
        self.name = name
        self.key = key
        self.fields = fields
        self.rows = rows
    }
}

/// A diff between two `GenericSet`s (computed by `diffGenericSets` or supplied
/// directly and serialized by `encodeGenericDelta`).
public struct GenericDeltaPayload {
    public var tool: String
    public var key: String
    public var fields: [String]
    public var baseRoot: String
    public var newRoot: String
    public var added: [[String: Any]]
    public var changed: [[String: Any]]
    public var removed: [Any]
    public var deltaTokens: Int
    public var fullTokens: Int

    public init(tool: String = "", key: String, fields: [String], baseRoot: String,
                newRoot: String = "", added: [[String: Any]] = [], changed: [[String: Any]] = [],
                removed: [Any] = [], deltaTokens: Int = 0, fullTokens: Int = 0) {
        self.tool = tool
        self.key = key
        self.fields = fields
        self.baseRoot = baseRoot
        self.newRoot = newRoot
        self.added = added
        self.changed = changed
        self.removed = removed
        self.deltaTokens = deltaTokens
        self.fullTokens = fullTokens
    }
}

public struct GenericDeltaError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Canonicalize one value for the pack-root record (Section 10a.3). Purpose-built
/// and deliberately decoupled from the wire cell encoder (`formatScalar`): it must
/// be collision-free and record-safe, not round-trippable.
///   - Typed literals stay bare so they never collide with the strings that spell
///     them: null is `-` (never a string), booleans are `true`/`false`, numbers are
///     canonical (Section 2.3.1).
///   - Strings are ALWAYS quoted, so (a) they can't collide with a typed literal
///     (`-`, `true`, `123` all become quoted), and (b) a tab or newline inside a
///     value is escaped and cannot break the tab/newline-delimited record.
public func canonicalCell(_ value: Any?) -> String {
    guard let value = value, !(value is NSNull) else { return "-" }
    // Booleans first: a Bool bridges to NSNumber whose CFTypeID is CFBoolean.
    if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
        return n.boolValue ? "true" : "false"
    }
    if let b = value as? Bool { return b ? "true" : "false" }
    if let i = value as? Int { return String(i) }
    if let d = value as? Double { return formatNumber(d) }
    if let s = value as? String { return quoteString(s) }
    return quoteString("\(value)")
}

/// Sort strings by UTF-8 byte order (matching Go's `sort.Strings` / Rust `str`
/// ordering). Swift's default `String` comparison is Unicode-normalized, not
/// byte-wise, so it is not used here.
private func byteSorted(_ xs: [String]) -> [String] {
    xs.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

private func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Compute the canonical pack root for a keyed set using the gcf-pack-root-v1
/// algorithm, generic profile (Section 10a.3). Two implementations given the same
/// logical set MUST produce the same result.
public func genericPackRoot(_ s: GenericSet) -> String {
    let sortedFields = byteSorted(s.fields)
    var records: [String] = s.rows.map { row in
        var r = "R"
        for f in sortedFields {
            r += "\t" + f + "\t" + canonicalCell(row[f])
        }
        return r + "\n"
    }
    records = byteSorted(records)
    return "sha256:" + sha256Hex(records.joined())
}

/// Build an identity -> row map, rejecting duplicate identities (Section 10a.1).
private func indexByKey(_ s: GenericSet) throws -> [String: [String: Any]] {
    var m: [String: [String: Any]] = [:]
    m.reserveCapacity(s.rows.count)
    for row in s.rows {
        let id = canonicalCell(row[s.key])
        if m[id] != nil {
            throw GenericDeltaError("delta_invalid: duplicate identity \(id) for key \"\(s.key)\"")
        }
        m[id] = row
    }
    return m
}

private func keyOf(_ row: [String: Any], _ key: String) -> String {
    canonicalCell(row[key])
}

private func rowsEqual(_ a: [String: Any], _ b: [String: Any], _ fields: [String]) -> Bool {
    fields.allSatisfy { canonicalCell(a[$0]) == canonicalCell(b[$0]) }
}

/// Compute the delta from `base` to `next`. This is the blessed producer path: it
/// is the single place that enforces the keyed-diff invariants (identity
/// uniqueness, added-not-in-base, changed-must-exist, whole-row replacement,
/// unchanged rows omitted). Added/changed/removed are sorted by identity for
/// reproducible output (Section 10a.6). Schema change or a missing key throws: the
/// caller must then send a full payload (Section 10a.7).
public func diffGenericSets(_ base: GenericSet, _ next: GenericSet) throws -> GenericDeltaPayload {
    if next.key.isEmpty {
        throw GenericDeltaError("delta_invalid: no identity key")
    }
    if next.key != base.key || base.fields != next.fields {
        throw GenericDeltaError("delta_invalid: schema change (send full)")
    }
    let baseIdx = try indexByKey(base)
    let nextIdx = try indexByKey(next)

    var added: [[String: Any]] = []
    var changed: [[String: Any]] = []
    var removed: [Any] = []

    for (id, row) in nextIdx {
        if let brow = baseIdx[id] {
            if !rowsEqual(brow, row, next.fields) { changed.append(row) }
        } else {
            added.append(row)
        }
        // equal rows are omitted (silence = "keep it", Section 10a.5)
    }
    for (id, brow) in baseIdx where nextIdx[id] == nil {
        removed.append(brow[next.key] ?? NSNull())
    }

    added.sort { keyOf($0, next.key).utf8.lexicographicallyPrecedes(keyOf($1, next.key).utf8) }
    changed.sort { keyOf($0, next.key).utf8.lexicographicallyPrecedes(keyOf($1, next.key).utf8) }
    removed.sort { canonicalCell($0).utf8.lexicographicallyPrecedes(canonicalCell($1).utf8) }

    return GenericDeltaPayload(
        key: next.key, fields: next.fields,
        baseRoot: genericPackRoot(base), newRoot: genericPackRoot(next),
        added: added, changed: changed, removed: removed)
}

// MARK: - Producer-side wire encoding

private func fieldDecl(_ fields: [String], _ key: String) -> String {
    fields.map { $0 == key ? "@" + formatKey($0) : formatKey($0) }.joined(separator: ",")
}

private func encodeRow(_ row: [String: Any], _ fields: [String]) -> String {
    fields.map { formatScalar(row[$0], delimiter: "|") }.joined(separator: "|")
}

/// Emit a delta-participating full base payload: `key=` in the header, an
/// `@`-prefixed identity field in the declaration, pipe-separated rows.
public func encodeGenericFull(_ s: GenericSet, tool: String) -> String {
    let name = s.name.isEmpty ? "rows" : s.name
    var b = "GCF profile=generic"
    if !tool.isEmpty { b += " tool=\(tool)" }
    b += " pack_root=\(genericPackRoot(s)) key=\(s.key)\n"
    b += "## \(name) [\(s.rows.count)]{\(fieldDecl(s.fields, s.key))}\n"
    for row in s.rows {
        b += encodeRow(row, s.fields) + "\n"
    }
    return b
}

/// Serialize a delta payload (Section 10a.2). Sections are emitted in the
/// deterministic order added / changed / removed (Section 10a.6).
public func encodeGenericDelta(_ d: GenericDeltaPayload) -> String {
    var b = "GCF profile=generic"
    if !d.tool.isEmpty { b += " tool=\(d.tool)" }
    b += " delta=true base_root=\(d.baseRoot) new_root=\(d.newRoot) key=\(d.key)"
    if d.fullTokens > 0 {
        let savings = 100.0 * (1.0 - Double(d.deltaTokens) / Double(d.fullTokens))
        b += String(format: " savings=%.0f%%", savings)
    }
    b += "\n"

    if !d.added.isEmpty {
        b += "## added [\(d.added.count)]{\(fieldDecl(d.fields, d.key))}\n"
        for row in d.added { b += encodeRow(row, d.fields) + "\n" }
    }
    if !d.changed.isEmpty {
        b += "## changed [\(d.changed.count)]{\(fieldDecl(d.fields, d.key))}\n"
        for row in d.changed { b += encodeRow(row, d.fields) + "\n" }
    }
    if !d.removed.isEmpty {
        b += "## removed [\(d.removed.count)]{@\(d.key)}\n"
        for idv in d.removed { b += formatScalar(idv, delimiter: "|") + "\n" }
    }
    return b
}

/// Apply a delta to a base set and verify the result hashes to `expectedNewRoot`
/// (Section 10a.5). Atomic: the whole payload is validated before any state
/// changes, and a mismatch leaves the base untouched.
public func verifyGenericDelta(_ base: GenericSet, _ d: GenericDeltaPayload,
                               expectedNewRoot: String) throws -> GenericSet {
    if genericPackRoot(base) != d.baseRoot {
        throw GenericDeltaError("base_mismatch: base root does not equal delta base_root")
    }
    let baseIdx = try indexByKey(base)

    // Validate the entire payload against the original base before mutating.
    for idv in d.removed where baseIdx[canonicalCell(idv)] == nil {
        throw GenericDeltaError("delta_invalid: removing identity \(canonicalCell(idv)) not in base")
    }
    for row in d.added where baseIdx[keyOf(row, d.key)] != nil {
        throw GenericDeltaError("delta_invalid: adding identity \(keyOf(row, d.key)) that already exists")
    }
    for row in d.changed where baseIdx[keyOf(row, d.key)] == nil {
        throw GenericDeltaError("delta_invalid: changing identity \(keyOf(row, d.key)) not in base")
    }

    // Apply to a working copy.
    var work = baseIdx
    for idv in d.removed { work[canonicalCell(idv)] = nil }
    for row in d.added { work[keyOf(row, d.key)] = row }
    for row in d.changed { work[keyOf(row, d.key)] = row }

    let result = GenericSet(name: base.name, key: base.key, fields: base.fields,
                            rows: Array(work.values))
    let got = genericPackRoot(result)
    if got != expectedNewRoot {
        throw GenericDeltaError("root_mismatch: computed \(got), expected \(expectedNewRoot)")
    }
    return result
}

// MARK: - Consumer-side wire parsing (Section 10a)

private func scalarToAny(_ r: ScalarResult) throws -> Any {
    switch r {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .missing, .attachment, .inlineAttachment:
        throw GenericDeltaError("delta_invalid: non-scalar cell not allowed in delta row")
    }
}

private func parseHeaderFields(_ header: String) -> [String: String] {
    var m: [String: String] = [:]
    for tok in header.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
        if let eq = tok.firstIndex(of: "="), eq != tok.startIndex {
            m[String(tok[tok.startIndex..<eq])] = String(tok[tok.index(after: eq)...])
        }
    }
    return m
}

private func parseCount(_ s: String) throws -> Int {
    if s == "0" { return 0 }
    if s.isEmpty || s.first == "0" { throw GenericDeltaError("delta_invalid: invalid count \(s)") }
    guard let n = Int(s), String(n) == s else {
        throw GenericDeltaError("delta_invalid: invalid count \(s)")
    }
    return n
}

/// Find the index of the first `[` not inside a quoted string.
private func findBracketStart(_ s: String) -> String.Index? {
    var inQuote = false
    var escaped = false
    var idx = s.startIndex
    while idx < s.endIndex {
        let c = s[idx]
        if escaped {
            escaped = false
        } else if c == "\\" && inQuote {
            escaped = true
        } else if c == "\"" {
            inQuote.toggle()
        } else if c == "[" && !inQuote {
            return idx
        }
        idx = s.index(after: idx)
    }
    return nil
}

/// Parse a delta/full field declaration `{@id,total,...}`, returning the ordered
/// fields and the key field (the one that was `@`-marked) (Section 10a.1).
private func splitDeltaFieldDecl(_ decl: String) throws -> (fields: [String], keyField: String) {
    guard decl.count >= 2, decl.hasPrefix("{"), decl.hasSuffix("}") else {
        throw GenericDeltaError("delta_invalid: invalid field declaration: \(decl)")
    }
    let inner = String(decl.dropFirst().dropLast())
    if inner.isEmpty { return ([], "") }
    var fields: [String] = []
    var keyField = ""
    for raw in splitRespectingQuotes(inner, delimiter: ",") {
        var f = raw.trimmingCharacters(in: .whitespaces)
        var isKey = false
        if f.hasPrefix("@") { f = String(f.dropFirst()); isKey = true }
        if f.count >= 2 && f.hasPrefix("\"") && f.hasSuffix("\"") { f = try parseQuotedString(f) }
        if isKey { keyField = f }
        fields.append(f)
    }
    return (fields, keyField)
}

/// Parse the content after `## ` of a delta/full section, e.g.
/// `added [1]{@id,total,status,customer}` or `orders [3]{@id,...}` or `removed [1]{@id}`.
private func parseSectionHeader(_ content: String)
    throws -> (name: String, count: Int, fields: [String], keyField: String) {
    guard let bi = findBracketStart(content) else {
        throw GenericDeltaError("delta_invalid: section header without count: \(content)")
    }
    let name = String(content[content.startIndex..<bi]).trimmingCharacters(in: .whitespaces)
    let rest = String(content[bi...]) // "[N]{...}"
    guard rest.hasPrefix("[") else {
        throw GenericDeltaError("delta_invalid: malformed section header: \(content)")
    }
    guard let close = rest.firstIndex(of: "]") else {
        throw GenericDeltaError("delta_invalid: unterminated count: \(content)")
    }
    let countStr = String(rest[rest.index(after: rest.startIndex)..<close])
    let count = try parseCount(countStr)
    let (fields, keyField) = try splitDeltaFieldDecl(String(rest[rest.index(after: close)...]))
    return (name, count, fields, keyField)
}

private func parseRow(_ line: String, _ fields: [String]) throws -> [String: Any] {
    let cells = splitRespectingQuotes(line, delimiter: "|")
    guard cells.count == fields.count else {
        throw GenericDeltaError("delta_invalid: row has \(cells.count) cells, expected \(fields.count): \(line)")
    }
    var row: [String: Any] = [:]
    for (i, f) in fields.enumerated() {
        row[f] = try scalarToAny(parseScalar(cells[i], tabularContext: true))
    }
    return row
}

/// Parse a delta-participating full base payload into a `GenericSet`, and return
/// the declared `pack_root` (Section 10a).
public func decodeGenericFull(_ text: String) throws -> (set: GenericSet, packRoot: String) {
    var trimmed = text
    while trimmed.hasSuffix("\n") { trimmed = String(trimmed.dropLast()) }
    let lines = trimmed.components(separatedBy: "\n")
    let hdr = parseHeaderFields(lines[0])
    guard hdr["profile"] == "generic" else {
        throw GenericDeltaError("not a generic payload")
    }
    var set = GenericSet(key: hdr["key"] ?? "", fields: [], rows: [])
    var i = 1
    while i < lines.count {
        let line = lines[i]
        if !line.hasPrefix("## ") { i += 1; continue }
        let (name, count, fields, keyField) = try parseSectionHeader(String(line.dropFirst(3)))
        set.name = name
        set.fields = fields
        if set.key.isEmpty { set.key = keyField }
        i += 1
        for _ in 0..<count {
            if i >= lines.count {
                throw GenericDeltaError("delta_invalid: fewer rows than declared count")
            }
            set.rows.append(try parseRow(lines[i], fields))
            i += 1
        }
    }
    return (set, hdr["pack_root"] ?? "")
}

/// Parse a delta payload into a `GenericDeltaPayload` (Section 10a.2). The result
/// can be applied with `verifyGenericDelta`.
public func decodeGenericDelta(_ text: String) throws -> GenericDeltaPayload {
    var trimmed = text
    while trimmed.hasSuffix("\n") { trimmed = String(trimmed.dropLast()) }
    let lines = trimmed.components(separatedBy: "\n")
    let hdr = parseHeaderFields(lines[0])
    guard hdr["profile"] == "generic" else {
        throw GenericDeltaError("not a generic payload")
    }
    guard hdr["delta"] == "true" else {
        throw GenericDeltaError("not a delta payload")
    }
    var d = GenericDeltaPayload(
        tool: hdr["tool"] ?? "", key: hdr["key"] ?? "", fields: [],
        baseRoot: hdr["base_root"] ?? "", newRoot: hdr["new_root"] ?? "")
    var fieldsSet = false
    var i = 1
    while i < lines.count {
        let line = lines[i]
        if !line.hasPrefix("## ") { i += 1; continue }
        let (name, count, fields, keyField) = try parseSectionHeader(String(line.dropFirst(3)))
        if d.key.isEmpty && !keyField.isEmpty { d.key = keyField }
        if !fieldsSet && (name == "added" || name == "changed") {
            d.fields = fields
            fieldsSet = true
        }
        i += 1
        switch name {
        case "added", "changed":
            var rows: [[String: Any]] = []
            for _ in 0..<count {
                if i >= lines.count {
                    throw GenericDeltaError("delta_invalid: fewer rows than declared count in ## \(name)")
                }
                rows.append(try parseRow(lines[i], fields))
                i += 1
            }
            if name == "added" { d.added = rows } else { d.changed = rows }
        case "removed":
            for _ in 0..<count {
                if i >= lines.count {
                    throw GenericDeltaError("delta_invalid: fewer identities than declared count in ## removed")
                }
                d.removed.append(try scalarToAny(parseScalar(lines[i], tabularContext: true)))
                i += 1
            }
        default:
            throw GenericDeltaError("delta_invalid: unknown delta section \(name)")
        }
    }
    return d
}
