import Foundation

// MARK: - Common Scalar Grammar for GCF v2.0

private let jsonNumberPattern = try! NSRegularExpression(
    pattern: "\\A-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\z"
)
private let numericLikePattern = try! NSRegularExpression(
    pattern: "\\A[+-]?\\.?\\d"
)
private let bareKeyPattern = try! NSRegularExpression(
    pattern: "\\A[a-zA-Z_][a-zA-Z0-9_]*\\z"
)

public func needsQuote(_ s: String) -> Bool {
    if s.isEmpty { return true }
    if s == "-" || s == "~" || s == "^" || s == "true" || s == "false" { return true }
    let range = NSRange(s.startIndex..., in: s)
    if jsonNumberPattern.firstMatch(in: s, range: range) != nil { return true }
    if numericLikePattern.firstMatch(in: s, range: range) != nil { return true }
    if s.first == " " || s.last == " " { return true }
    if s.first == "#" || s.first == "@" { return true }
    for c in s.unicodeScalars {
        if c == "\"" || c == "\\" || c == "|" || c == "," || c.value < 0x20
            || c == "\n" || c == "\r" { return true }
        // Quote any non-ASCII character. Swift's grapheme clustering can merge
        // non-ASCII characters (combining marks, Thai vowels, etc.) with adjacent
        // ASCII delimiters like =, |, and ", breaking parse operations.
        if c.value > 0x7F { return true }
    }
    return false
}

public func quoteString(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if c.value < 0x20 {
                out += String(format: "\\u%04x", c.value)
            } else {
                out += String(c)
            }
        }
    }
    out += "\""
    return out
}

public func formatScalar(_ value: Any?, delimiter: Character = "\0") -> String {
    guard let value = value else { return "-" }
    if value is NSNull { return "-" }
    // NSNumber: must check CFBoolean BEFORE Swift type bridging,
    // because NSNumber(value: 1) bridges to both Bool and Int.
    if let n = value as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() {
            return n.boolValue ? "true" : "false"
        }
        let t = n.objCType.pointee
        if t == 0x64 || t == 0x66 { // 'd' = double, 'f' = float
            return formatNumber(n.doubleValue)
        }
        return n.stringValue
    }
    if let i = value as? Int { return String(i) }
    if let d = value as? Double { return formatNumber(d) }
    let s = "\(value)"
    if needsQuote(s) || (delimiter != "\0" && s.contains(delimiter)) {
        return quoteString(s)
    }
    return s
}

public func formatNumber(_ f: Double) -> String {
    if f.isNaN || f.isInfinite { return "0" }
    if f == 0 {
        return f.sign == .minus ? "-0" : "0"
    }
    let a = abs(f)
    if a >= 1e-6 && a < 1e21 {
        var s = "\(f)"
        // Swift may use scientific notation; convert to plain decimal.
        if s.contains("e") || s.contains("E") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ""
            formatter.maximumFractionDigits = 20
            formatter.minimumFractionDigits = 0
            s = formatter.string(from: NSNumber(value: f)) ?? s
        }
        // Strip trailing .0 for integer-valued floats.
        if s.hasSuffix(".0") && f == f.rounded(.towardZero) {
            s = String(s.dropLast(2))
        }
        return s
    }
    // Exponent notation: use Swift's shortest-exact representation
    // then normalize the exponent format.
    var s = "\(f)"
    // Ensure it has an exponent.
    if !s.contains("e") && !s.contains("E") {
        // Force exponent form.
        s = String(format: "%.17e", f)
    }
    // Normalize: lowercase e, explicit sign, no leading zeros in exponent, strip trailing zeros.
    if let eIdx = s.firstIndex(of: "e") ?? s.firstIndex(of: "E") {
        let mantissa = String(s[s.startIndex..<eIdx])
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        let expPart = String(s[s.index(after: eIdx)...])
        let sign: String
        let digits: String
        if expPart.hasPrefix("-") {
            sign = "-"
            digits = String(expPart.dropFirst()).replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        } else {
            sign = "+"
            let raw = expPart.hasPrefix("+") ? String(expPart.dropFirst()) : expPart
            digits = raw.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        }
        return "\(mantissa)e\(sign)\(digits.isEmpty ? "0" : digits)"
    }
    return s
}

public func isBareKey(_ s: String) -> Bool {
    let range = NSRange(s.startIndex..., in: s)
    return bareKeyPattern.firstMatch(in: s, range: range) != nil
}

public func formatKey(_ s: String) -> String {
    return isBareKey(s) ? s : quoteString(s)
}

// MARK: - Scalar Parsing

public enum ScalarResult {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case missing
    case attachment
}

public func parseScalar(_ s: String, tabularContext: Bool = false) throws -> ScalarResult {
    if s.isEmpty { return .string("") }
    if s.unicodeScalars.first == "\"" { return .string(try parseQuotedString(s)) }
    if s == "-" { return .null }
    if s == "~" {
        if !tabularContext { throw GCFError.invalidMissing }
        return .missing
    }
    if s == "^" {
        if !tabularContext { throw GCFError.invalidAttachment }
        return .attachment
    }
    if s == "true" { return .bool(true) }
    if s == "false" { return .bool(false) }
    let range = NSRange(s.startIndex..., in: s)
    if jsonNumberPattern.firstMatch(in: s, range: range) != nil {
        if let d = Double(s) {
            if !s.contains(".") && !s.contains("e") && !s.contains("E") {
                if abs(d) <= Double(1 << 53) {
                    return .int(Int(d))
                }
            }
            return .double(d)
        }
    }
    return .string(s)
}

public enum GCFError: Error, CustomStringConvertible {
    case missingHeader
    case missingProfile
    case unknownProfile(String)
    case duplicateHeaderField(String)
    case malformedHeaderField(String)
    case invalidMissing
    case invalidAttachment
    case unterminatedQuote
    case trailingCharacters
    case invalidEscape(String)
    case invalidSurrogate(String)
    case invalidIndent
    case tabIndentation
    case duplicateKey(String)
    case duplicateFieldName(String)
    case rowWidthMismatch(Int, Int)
    case countMismatch(Int, Int)
    case invalidCount(String)
    case orphanAttachment(String)
    case missingAttachment(String)
    case duplicateAttachment(String)
    case invalidItemId(Int, String)
    case invalidFieldDeclaration(String)

    public var description: String {
        switch self {
        case .missingHeader: return "missing_header: first line does not begin with GCF"
        case .missingProfile: return "missing_profile: no profile= field"
        case .unknownProfile(let p): return "unknown_profile: \(p)"
        case .duplicateHeaderField(let k): return "duplicate_header_field: \(k)"
        case .malformedHeaderField(let f): return "malformed_header_field: \(f)"
        case .invalidMissing: return "invalid_missing: ~ outside tabular row cell"
        case .invalidAttachment: return "invalid_attachment_marker: ^ outside tabular row cell"
        case .unterminatedQuote: return "unterminated_quote"
        case .trailingCharacters: return "trailing_characters: after closing quote"
        case .invalidEscape(let e): return "invalid_escape: \(e)"
        case .invalidSurrogate(let s): return "invalid_surrogate: \(s)"
        case .invalidIndent: return "invalid_indent: indentation increases by more than one level"
        case .tabIndentation: return "tab_indentation: tabs in leading whitespace"
        case .duplicateKey(let k): return "duplicate_key: \(k)"
        case .duplicateFieldName(let f): return "duplicate_field_name: \(f)"
        case .rowWidthMismatch(let e, let g): return "row_width_mismatch: expected \(e), got \(g)"
        case .countMismatch(let d, let a): return "count_mismatch: declared \(d), got \(a)"
        case .invalidCount(let s): return "invalid_count: \(s)"
        case .orphanAttachment(let s): return "orphan_attachment: \(s)"
        case .missingAttachment(let f): return "missing_attachment: \(f)"
        case .duplicateAttachment(let f): return "duplicate_attachment: \(f)"
        case .invalidItemId(let e, let g): return "invalid_item_id: expected @\(e), got @\(g)"
        case .invalidFieldDeclaration(let s): return "invalid field declaration: \(s)"
        }
    }
}

public func parseQuotedString(_ s: String) throws -> String {
    let chars = Array(s.unicodeScalars)
    guard chars.count >= 2, chars[0] == "\"" else { throw GCFError.unterminatedQuote }
    var out = ""
    var i = 1
    while i < chars.count {
        if chars[i] == "\"" {
            if i + 1 != chars.count { throw GCFError.trailingCharacters }
            return out
        }
        if chars[i] == "\\" {
            guard i + 1 < chars.count else { throw GCFError.unterminatedQuote }
            i += 1
            switch chars[i] {
            case "\"": out += "\""
            case "\\": out += "\\"
            case "/": out += "/"
            case "b": out += "\u{08}"
            case "f": out += "\u{0C}"
            case "n": out += "\n"
            case "r": out += "\r"
            case "t": out += "\t"
            case "u":
                guard i + 4 < chars.count else { throw GCFError.invalidEscape("incomplete unicode") }
                let hex = String(chars[i+1...i+4].map { Character($0) })
                guard let code = UInt16(hex, radix: 16) else {
                    throw GCFError.invalidEscape("invalid unicode \\u\(hex)")
                }
                if (0xD800...0xDBFF).contains(code) {
                    guard i + 10 < chars.count, chars[i+5] == "\\", chars[i+6] == "u" else {
                        throw GCFError.invalidSurrogate("isolated high surrogate")
                    }
                    let hex2 = String(chars[i+7...i+10].map { Character($0) })
                    guard let low = UInt16(hex2, radix: 16), (0xDC00...0xDFFF).contains(low) else {
                        throw GCFError.invalidSurrogate("invalid low surrogate")
                    }
                    let combined = 0x10000 + UInt32(code - 0xD800) * 0x400 + UInt32(low - 0xDC00)
                    out += String(Unicode.Scalar(combined)!)
                    i += 11
                    continue
                }
                if (0xDC00...0xDFFF).contains(code) {
                    throw GCFError.invalidSurrogate("isolated low surrogate")
                }
                out += String(Unicode.Scalar(UInt32(code))!)
                i += 5
                continue
            default:
                throw GCFError.invalidEscape("unknown \\\(chars[i])")
            }
            i += 1
            continue
        }
        if chars[i].value < 0x20 {
            throw GCFError.invalidEscape("unescaped control U+\(String(format: "%04x", chars[i].value))")
        }
        out += String(chars[i])
        i += 1
    }
    throw GCFError.unterminatedQuote
}

public func splitRespectingQuotes(_ s: String, delimiter: Character) -> [String] {
    let delimScalar = delimiter.unicodeScalars.first!
    var parts: [String] = []
    var current: [Unicode.Scalar] = []
    var inQuote = false
    var escaped = false
    for c in s.unicodeScalars {
        if escaped { current.append(c); escaped = false; continue }
        if c == "\\" && inQuote { current.append(c); escaped = true; continue }
        if c == "\"" { inQuote = !inQuote; current.append(c); continue }
        if c == delimScalar && !inQuote {
            parts.append(String(String.UnicodeScalarView(current)))
            current = []
            continue
        }
        current.append(c)
    }
    parts.append(String(String.UnicodeScalarView(current)))
    return parts
}

public func splitFieldDecl(_ s: String) throws -> [String] {
    guard s.unicodeScalars.count >= 2, s.unicodeScalars.first == "{" else {
        throw GCFError.invalidFieldDeclaration(s)
    }
    guard let closeIdx = findClosingBrace(s) else {
        throw GCFError.invalidFieldDeclaration(s)
    }
    let startIdx = s.unicodeScalars.index(after: s.unicodeScalars.startIndex)
    let endIdx = s.unicodeScalars.index(s.unicodeScalars.startIndex, offsetBy: closeIdx)
    let inner = String(s[startIdx..<endIdx])
    if inner.isEmpty { return [] }
    let raw = splitRespectingQuotes(inner, delimiter: ",")
    var fields: [String] = []
    var seen = Set<String>()
    for f in raw {
        let trimmed = f.trimmingCharacters(in: .whitespaces)
        let name: String
        if trimmed.count >= 2 && trimmed.unicodeScalars.first == "\"" && trimmed.unicodeScalars.last == "\"" {
            name = try parseQuotedString(trimmed)
        } else {
            guard isBareKey(trimmed) else {
                throw GCFError.invalidFieldDeclaration("invalid field name: \(trimmed)")
            }
            name = trimmed
        }
        if seen.contains(name) { throw GCFError.duplicateFieldName(name) }
        seen.insert(name)
        fields.append(name)
    }
    return fields
}

/// Returns the unicode scalar offset of the closing `}`.
public func findClosingBrace(_ s: String) -> Int? {
    var inQuote = false
    var escaped = false
    var offset = 0
    for c in s.unicodeScalars {
        if escaped { escaped = false; offset += 1; continue }
        if c == "\\" && inQuote { escaped = true; offset += 1; continue }
        if c == "\"" { inQuote = !inQuote; offset += 1; continue }
        if c == "}" && !inQuote { return offset }
        offset += 1
    }
    return nil
}
