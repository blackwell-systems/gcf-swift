import Foundation

/// Dictionary that preserves insertion order of keys.
/// Used for conformance-grade JSON round-tripping where key order matters.
public class OrderedDictionary: NSObject {
    private var keys: [String] = []
    private var values: [String: Any] = [:]

    public override init() {
        super.init()
    }

    public init(_ pairs: [(String, Any)]) {
        super.init()
        for (k, v) in pairs {
            self[k] = v
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public var orderedKeys: [String] { keys }

    public var orderedPairs: [(String, Any)] {
        keys.map { ($0, values[$0]!) }
    }

    public subscript(key: String) -> Any? {
        get { values[key] }
        set {
            if let val = newValue {
                if values[key] == nil {
                    keys.append(key)
                }
                values[key] = val
            } else {
                if values[key] != nil {
                    keys.removeAll { $0 == key }
                    values[key] = nil
                }
            }
        }
    }

    public func contains(_ key: String) -> Bool {
        values[key] != nil
    }
}

/// Parse JSON preserving insertion order using OrderedDictionary.
/// Parse JSON into an OrderedDictionary-based tree, preserving object key
/// insertion order natively (a proper recursive-descent parse; not a byte scan).
/// Numbers become Int when integral and in range, else Double; `-0` is kept as
/// a negative-zero Double so the encoder can emit it faithfully.
public func parseJSONOrdered(_ data: Data) throws -> Any {
    guard let str = String(data: data, encoding: .utf8) else {
        throw GCFError.invalidJSON("input is not valid UTF-8")
    }
    var parser = JSONOrderedParser(Array(str.unicodeScalars))
    let value = try parser.parseValue()
    parser.skipWhitespace()
    guard parser.atEnd else { throw GCFError.invalidJSON("trailing characters") }
    return value
}

private struct JSONOrderedParser {
    private let s: [Unicode.Scalar]
    private var i = 0
    init(_ scalars: [Unicode.Scalar]) { self.s = scalars }

    var atEnd: Bool { i >= s.count }

    mutating func skipWhitespace() {
        while i < s.count {
            let c = s[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1 } else { break }
        }
    }

    mutating func parseValue() throws -> Any {
        skipWhitespace()
        guard i < s.count else { throw GCFError.invalidJSON("unexpected end of input") }
        switch s[i] {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return try parseString()
        case "t", "f": return try parseBool()
        case "n": try expect("null"); return NSNull()
        default: return try parseNumber()
        }
    }

    private mutating func parseObject() throws -> OrderedDictionary {
        i += 1  // consume {
        let od = OrderedDictionary()
        skipWhitespace()
        if i < s.count, s[i] == "}" { i += 1; return od }
        while true {
            skipWhitespace()
            guard i < s.count, s[i] == "\"" else { throw GCFError.invalidJSON("expected object key") }
            let key = try parseString()
            skipWhitespace()
            guard i < s.count, s[i] == ":" else { throw GCFError.invalidJSON("expected ':'") }
            i += 1
            od[key] = try parseValue()
            skipWhitespace()
            guard i < s.count else { throw GCFError.invalidJSON("unterminated object") }
            if s[i] == "," { i += 1; continue }
            if s[i] == "}" { i += 1; return od }
            throw GCFError.invalidJSON("expected ',' or '}'")
        }
    }

    private mutating func parseArray() throws -> [Any] {
        i += 1  // consume [
        var arr: [Any] = []
        skipWhitespace()
        if i < s.count, s[i] == "]" { i += 1; return arr }
        while true {
            arr.append(try parseValue())
            skipWhitespace()
            guard i < s.count else { throw GCFError.invalidJSON("unterminated array") }
            if s[i] == "," { i += 1; continue }
            if s[i] == "]" { i += 1; return arr }
            throw GCFError.invalidJSON("expected ',' or ']'")
        }
    }

    private mutating func parseString() throws -> String {
        i += 1  // consume opening quote
        var out = String.UnicodeScalarView()
        while i < s.count {
            let c = s[i]; i += 1
            if c == "\"" { return String(out) }
            if c != "\\" { out.append(c); continue }
            guard i < s.count else { throw GCFError.invalidJSON("bad escape") }
            let e = s[i]; i += 1
            switch e {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case "b": out.append(Unicode.Scalar(0x08)!)
            case "f": out.append(Unicode.Scalar(0x0C)!)
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "u":
                let cp = try parseHex4()
                if cp >= 0xD800 && cp <= 0xDBFF {
                    guard i + 1 < s.count, s[i] == "\\", s[i + 1] == "u" else {
                        throw GCFError.invalidJSON("expected low surrogate")
                    }
                    i += 2
                    let lo = try parseHex4()
                    guard lo >= 0xDC00 && lo <= 0xDFFF else { throw GCFError.invalidJSON("invalid low surrogate") }
                    let combined = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    guard let sc = Unicode.Scalar(combined) else { throw GCFError.invalidJSON("invalid surrogate pair") }
                    out.append(sc)
                } else if cp >= 0xDC00 && cp <= 0xDFFF {
                    throw GCFError.invalidJSON("isolated low surrogate")
                } else {
                    guard let sc = Unicode.Scalar(cp) else { throw GCFError.invalidJSON("invalid codepoint") }
                    out.append(sc)
                }
            default: throw GCFError.invalidJSON("invalid escape \\\(e)")
            }
        }
        throw GCFError.invalidJSON("unterminated string")
    }

    private mutating func parseHex4() throws -> Int {
        guard i + 4 <= s.count else { throw GCFError.invalidJSON("bad \\u escape") }
        var v = 0
        for _ in 0..<4 {
            let c = s[i]; i += 1
            let d: Int
            switch c {
            case "0"..."9": d = Int(c.value) - 48
            case "a"..."f": d = Int(c.value) - 87
            case "A"..."F": d = Int(c.value) - 55
            default: throw GCFError.invalidJSON("bad hex digit")
            }
            v = v * 16 + d
        }
        return v
    }

    private mutating func parseBool() throws -> Any {
        if matchLiteral("true") { return true }
        if matchLiteral("false") { return false }
        throw GCFError.invalidJSON("invalid literal")
    }

    private mutating func expect(_ lit: String) throws {
        if !matchLiteral(lit) { throw GCFError.invalidJSON("invalid literal") }
    }

    private mutating func matchLiteral(_ lit: String) -> Bool {
        let ls = Array(lit.unicodeScalars)
        guard i + ls.count <= s.count else { return false }
        for k in 0..<ls.count where s[i + k] != ls[k] { return false }
        i += ls.count
        return true
    }

    private mutating func parseNumber() throws -> Any {
        let start = i
        if i < s.count, s[i] == "-" { i += 1 }
        while i < s.count, isDigit(s[i]) { i += 1 }
        var isDouble = false
        if i < s.count, s[i] == "." {
            isDouble = true; i += 1
            while i < s.count, isDigit(s[i]) { i += 1 }
        }
        if i < s.count, s[i] == "e" || s[i] == "E" {
            isDouble = true; i += 1
            if i < s.count, s[i] == "+" || s[i] == "-" { i += 1 }
            while i < s.count, isDigit(s[i]) { i += 1 }
        }
        let str = String(String.UnicodeScalarView(s[start..<i]))
        if str.isEmpty || str == "-" { throw GCFError.invalidJSON("invalid number") }
        if isDouble {
            guard let d = Double(str) else { throw GCFError.invalidJSON("invalid number: \(str)") }
            return d
        }
        // Preserve negative zero (Int cannot represent it).
        if str == "-0" { return -0.0 }
        if let n = Int(str) { return n }
        // Integer literal out of Int range: fall back to Double.
        guard let d = Double(str) else { throw GCFError.invalidJSON("invalid number: \(str)") }
        return d
    }

    private func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
}
