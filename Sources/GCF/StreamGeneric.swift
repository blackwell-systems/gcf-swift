import Foundation

/// GenericStreamEncoder writes GCF tabular output incrementally as rows arrive.
/// Zero buffering: each row is written immediately. A trailer summary is
/// emitted on close() with the final counts. Thread-safe via NSLock.
///
/// Usage:
///
///     let enc = GenericStreamEncoder(writer: myWriter)
///     enc.beginArray("employees", fields: ["id", "name", "department", "salary"])
///     enc.writeRow([1, "Alice", "Engineering", 95000])
///     enc.writeRow([2, "Bob", "Sales", 72000])
///     enc.endArray()
///     try enc.close()
public class GenericStreamEncoder {
    private let writer: StreamWriter
    private let lock = NSLock()
    private var sections: [(name: String, count: Int)] = []
    private var current: (name: String, fields: [String], count: Int)?
    private var pendingError: GCFError?

    public init(writer: StreamWriter) {
        self.writer = writer
        self.writer.write("GCF profile=generic\n")
    }

    /// Start a tabular array section with deferred count [?].
    ///
    /// The section name and every field name are quoted per Section 2.4 (via
    /// formatKey), matching the buffered tabular header, so a name containing a
    /// delimiter or quote produces a valid, unambiguous header. A field name
    /// containing ">" is a flattened path that a streaming row cannot represent
    /// (Section 8.3, 7.4.6); it is rejected and the error is surfaced at close().
    public func beginArray(_ name: String, fields: [String]) {
        lock.lock()
        defer { lock.unlock() }

        if pendingError != nil {
            return
        }
        if current != nil {
            endArrayLocked()
        }
        for f in fields {
            if f.contains(">") {
                pendingError = .invalidFieldDeclaration(
                    "streaming field name '\(f)' contains '>' (a flattened path is not representable in a streaming row)")
                return
            }
        }
        writer.write("## \(formatKey(name)) [?]{\(formatFieldDecl(fields))}\n")
        current = (name: name, fields: fields, count: 0)
    }

    /// Emit a single pipe-separated row immediately.
    public func writeRow(_ values: [Any?]) {
        lock.lock()
        defer { lock.unlock() }

        guard current != nil else { return }
        let parts = values.map { formatValue($0) }
        writer.write("\(parts.joined(separator: "|"))\n")
        current?.count += 1
    }

    /// Close the current array section and record its count.
    public func endArray() {
        lock.lock()
        defer { lock.unlock() }
        endArrayLocked()
    }

    /// Emit a key=value line immediately.
    public func writeKV(_ key: String, value: Any?) {
        lock.lock()
        defer { lock.unlock() }
        writer.write("\(key)=\(formatValue(value))\n")
    }

    /// Start a nested object section (## key).
    public func writeSection(_ name: String) {
        lock.lock()
        defer { lock.unlock() }

        if current != nil {
            endArrayLocked()
        }
        writer.write("## \(name)\n")
    }

    /// Emit a primitive array inline: name[N]: val1,val2,val3
    public func writeInlineArray(_ name: String, values: [Any?]) {
        lock.lock()
        defer { lock.unlock() }
        let parts = values.map { formatValue($0) }
        writer.write("\(name)[\(values.count)]: \(parts.joined(separator: ","))\n")
    }

    /// Emit the ##! summary trailer with final counts.
    ///
    /// Throws any error recorded during encoding (for example, a field name
    /// rejected by beginArray).
    public func close() throws {
        lock.lock()
        defer { lock.unlock() }

        if let err = pendingError {
            throw err
        }
        if current != nil {
            endArrayLocked()
        }
        guard !sections.isEmpty else { return }

        let counts = sections.map { String($0.count) }
        writer.write("##! summary counts=\(counts.joined(separator: ","))\n")
    }

    private func endArrayLocked() {
        guard let cur = current else { return }
        sections.append((name: cur.name, count: cur.count))
        current = nil
    }
}

/// Quotes each field name per Section 2.4 (via formatKey), matching the buffered
/// tabular header. The streaming header previously joined field names raw, so a
/// name containing a delimiter or quote produced an invalid or ambiguous header
/// (Section 8.3).
private func formatFieldDecl(_ fields: [String]) -> String {
    return fields.map { formatKey($0) }.joined(separator: ",")
}

private func formatValue(_ v: Any?) -> String {
    guard let v = v else { return "-" }

    if let b = v as? Bool {
        return b ? "true" : "false"
    }
    if let n = v as? Int {
        return "\(n)"
    }
    if let n = v as? Int64 {
        return "\(n)"
    }
    if let n = v as? Double {
        // Remove trailing zeros for clean output
        if n == n.rounded() && !n.isInfinite {
            return "\(Int64(n))"
        }
        return "\(n)"
    }
    if let s = v as? String {
        if s.isEmpty {
            return "\"\""
        }
        if s.contains("|") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return s
    }
    return "\(v)"
}
