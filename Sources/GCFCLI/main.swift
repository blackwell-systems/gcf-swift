import Foundation
import GCF

// MARK: - Helpers

/// Convert OrderedDictionary (and nested structures) back to types
/// that JSONSerialization can handle.
func toSerializable(_ value: Any) -> Any {
    if let od = value as? OrderedDictionary {
        // Use NSDictionary to preserve the ordered pairs for serialization.
        // JSONSerialization with .sortedKeys would reorder, so we build
        // an array of key-value fragments and join manually.
        let pairs = od.orderedPairs
        if pairs.isEmpty { return NSDictionary() }
        // Build JSON object string manually to preserve key order.
        // Return as-is NSDictionary for JSONSerialization (order not guaranteed
        // by Foundation, but best effort). For strict order we serialize manually.
        let nsDict = NSMutableDictionary()
        for (k, v) in pairs {
            nsDict[k] = toSerializable(v)
        }
        return nsDict
    }
    if let arr = value as? [Any] {
        return arr.map { toSerializable($0) }
    }
    return value
}

/// Serialize a value to JSON, preserving OrderedDictionary key order
/// by doing manual JSON construction for objects.
func serializeJSON(_ value: Any, indent: Int = 0) -> String {
    if let od = value as? OrderedDictionary {
        let pairs = od.orderedPairs
        if pairs.isEmpty { return "{}" }
        let indentStr = String(repeating: "  ", count: indent + 1)
        let closingIndent = String(repeating: "  ", count: indent)
        let items = pairs.map { (k, v) -> String in
            let keyJSON = serializeJSONScalar(k)
            let valJSON = serializeJSON(v, indent: indent + 1)
            return "\(indentStr)\(keyJSON): \(valJSON)"
        }
        return "{\n\(items.joined(separator: ",\n"))\n\(closingIndent)}"
    }
    if let arr = value as? [Any] {
        if arr.isEmpty { return "[]" }
        let indentStr = String(repeating: "  ", count: indent + 1)
        let closingIndent = String(repeating: "  ", count: indent)
        let items = arr.map { "\(indentStr)\(serializeJSON($0, indent: indent + 1))" }
        return "[\n\(items.joined(separator: ",\n"))\n\(closingIndent)]"
    }
    if let s = value as? String {
        return serializeJSONScalar(s)
    }
    if let n = value as? NSNumber {
        // Distinguish booleans from numbers
        if CFBooleanGetTypeID() == CFGetTypeID(n) {
            return n.boolValue ? "true" : "false"
        }
        // Integer check
        if n.doubleValue == Double(n.intValue) && !"\(n)".contains(".") {
            return "\(n.intValue)"
        }
        return "\(n)"
    }
    if value is NSNull {
        return "null"
    }
    // Fallback: try JSONSerialization for the scalar
    if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return "\(value)"
}

func serializeJSONScalar(_ s: String) -> String {
    var out = "\""
    for c in s {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.append(c)
        }
    }
    out += "\""
    return out
}

// MARK: - Commands

func encodeGenericCommand() throws {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let parsed = try parseJSONOrdered(data)
    let gcf = encodeGeneric(parsed)
    print(gcf, terminator: "")
}

func decodeGenericCommand() throws {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let input = String(data: data, encoding: .utf8) else {
        fputs("error: invalid UTF-8 input\n", stderr)
        exit(1)
    }
    let result = try decodeGeneric(input)
    let json = serializeJSON(result)
    print(json)
}

func encodeGraphCommand() throws {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard String(data: data, encoding: .utf8) != nil else {
        fputs("error: invalid UTF-8 input\n", stderr)
        exit(1)
    }
    // Expect JSON with the Payload structure; decode via JSONSerialization
    // and manually construct a Payload.
    guard let obj = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        fputs("error: expected JSON object for graph payload\n", stderr)
        exit(1)
    }
    let payload = try payloadFromJSON(obj)
    let gcf = encode(payload)
    print(gcf, terminator: "")
}

func decodeGraphCommand() throws {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let input = String(data: data, encoding: .utf8) else {
        fputs("error: invalid UTF-8 input\n", stderr)
        exit(1)
    }
    let payload = try decode(input)
    let json = payloadToJSON(payload)
    print(json)
}

func payloadFromJSON(_ obj: [String: Any]) throws -> Payload {
    var p = Payload(tool: obj["tool"] as? String ?? "")
    p.tokenBudget = obj["tokenBudget"] as? Int ?? obj["budget"] as? Int ?? 0
    p.tokensUsed = obj["tokensUsed"] as? Int ?? obj["tokens"] as? Int ?? 0
    p.packRoot = obj["packRoot"] as? String ?? obj["pack_root"] as? String ?? ""

    if let syms = obj["symbols"] as? [[String: Any]] {
        p.symbols = syms.map { s in
            Symbol(
                qualifiedName: s["qualifiedName"] as? String ?? "",
                kind: s["kind"] as? String ?? "",
                score: s["score"] as? Double ?? 0,
                provenance: s["provenance"] as? String ?? "",
                distance: s["distance"] as? Int ?? 0
            )
        }
    }

    if let edges = obj["edges"] as? [[String: Any]] {
        p.edges = edges.map { e in
            Edge(
                source: e["source"] as? String ?? "",
                target: e["target"] as? String ?? "",
                edgeType: e["edgeType"] as? String ?? "",
                status: e["status"] as? String ?? ""
            )
        }
    }

    return p
}

func payloadToJSON(_ p: Payload) -> String {
    var parts: [String] = []
    parts.append("  \"tool\": \(serializeJSONScalar(p.tool))")
    parts.append("  \"tokenBudget\": \(p.tokenBudget)")
    parts.append("  \"tokensUsed\": \(p.tokensUsed)")
    if !p.packRoot.isEmpty {
        parts.append("  \"packRoot\": \(serializeJSONScalar(p.packRoot))")
    }

    // Symbols
    let symStrs = p.symbols.map { s -> String in
        let fields = [
            "\"qualifiedName\": \(serializeJSONScalar(s.qualifiedName))",
            "\"kind\": \(serializeJSONScalar(s.kind))",
            "\"score\": \(s.score)",
            "\"provenance\": \(serializeJSONScalar(s.provenance))",
            "\"distance\": \(s.distance)"
        ]
        return "    {\(fields.joined(separator: ", "))}"
    }
    parts.append("  \"symbols\": [\n\(symStrs.joined(separator: ",\n"))\n  ]")

    // Edges
    let edgeStrs = p.edges.map { e -> String in
        let fields = [
            "\"source\": \(serializeJSONScalar(e.source))",
            "\"target\": \(serializeJSONScalar(e.target))",
            "\"edgeType\": \(serializeJSONScalar(e.edgeType))",
            "\"status\": \(serializeJSONScalar(e.status))"
        ]
        return "    {\(fields.joined(separator: ", "))}"
    }
    parts.append("  \"edges\": [\n\(edgeStrs.joined(separator: ",\n"))\n  ]")

    return "{\n\(parts.joined(separator: ",\n"))\n}"
}

func versionCommand() {
    print("gcf-swift 1.0.0")
}

func printUsage() {
    let usage = """
    Usage: GCFCLI <command>

    Commands:
      encode-generic    Read JSON from stdin, encode to GCF generic profile
      decode-generic    Read GCF generic from stdin, decode to JSON
      encode            Read JSON payload from stdin, encode to GCF graph profile
      decode            Read GCF graph from stdin, decode to JSON payload
      version           Print version
    """
    fputs(usage + "\n", stderr)
}

// MARK: - Main

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else {
    printUsage()
    exit(1)
}

do {
    switch command {
    case "encode-generic":
        try encodeGenericCommand()
    case "decode-generic":
        try decodeGenericCommand()
    case "encode":
        try encodeGraphCommand()
    case "decode":
        try decodeGraphCommand()
    case "version", "--version", "-v":
        versionCommand()
    case "help", "--help", "-h":
        printUsage()
    default:
        fputs("error: unknown command '\(command)'\n", stderr)
        printUsage()
        exit(1)
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
