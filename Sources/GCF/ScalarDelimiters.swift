import Foundation

// MARK: - Scalar-based delimiter helpers
//
// GCF structural delimiters are code points (SPEC 2.4). Swift's String iterates
// by grapheme cluster (Character), so a delimiter byte adjacent to a
// grapheme-extending scalar in the data (for example U+0619, U+102D, U+0ECB)
// merges with it into one Character. Character-based detection (hasPrefix,
// firstIndex(of:), dropFirst, index(after:), split(separator:)) then misreads
// structure. All structural detection in the decoders operates on unicode
// scalars instead. These helpers are shared by the generic, graph, and delta
// decoders.

/// Returns true if the scalar view of `s` begins with the scalars of `prefix`.
func scalarHasPrefix(_ s: String, _ prefix: String) -> Bool {
    var si = s.unicodeScalars.startIndex
    let se = s.unicodeScalars.endIndex
    for p in prefix.unicodeScalars {
        if si == se || s.unicodeScalars[si] != p { return false }
        si = s.unicodeScalars.index(after: si)
    }
    return true
}

/// Returns true if the scalar view of `s` ends with the scalars of `suffix`.
func scalarHasSuffix(_ s: String, _ suffix: String) -> Bool {
    let sv = s.unicodeScalars
    let fv = suffix.unicodeScalars
    var si = sv.endIndex
    var fi = fv.endIndex
    while fi != fv.startIndex {
        if si == sv.startIndex { return false }
        si = sv.index(before: si)
        fi = fv.index(before: fi)
        if sv[si] != fv[fi] { return false }
    }
    return true
}

/// Drops the first `n` scalars from `s` and returns the remainder as a String.
func scalarDropFirst(_ s: String, _ n: Int) -> String {
    let sv = s.unicodeScalars
    let idx = sv.index(sv.startIndex, offsetBy: n, limitedBy: sv.endIndex) ?? sv.endIndex
    return String(sv[idx...])
}

/// Returns the scalar-view index of the first occurrence of `scalar`, or nil.
func scalarFirstIndex(_ s: String, _ scalar: Unicode.Scalar) -> String.UnicodeScalarView.Index? {
    var i = s.unicodeScalars.startIndex
    let e = s.unicodeScalars.endIndex
    while i < e {
        if s.unicodeScalars[i] == scalar { return i }
        i = s.unicodeScalars.index(after: i)
    }
    return nil
}

/// The first unicode scalar of `s`, or nil when empty.
func firstScalar(_ s: String) -> Unicode.Scalar? {
    return s.unicodeScalars.first
}

/// Splits `s` on every occurrence of a single scalar, keeping empty segments
/// (equivalent to split with omittingEmptySubsequences: false).
func scalarSplit(_ s: String, _ sep: Unicode.Scalar) -> [String] {
    var parts: [String] = []
    var current: [Unicode.Scalar] = []
    for c in s.unicodeScalars {
        if c == sep {
            parts.append(String(String.UnicodeScalarView(current)))
            current = []
        } else {
            current.append(c)
        }
    }
    parts.append(String(String.UnicodeScalarView(current)))
    return parts
}

/// Splits `s` on runs of a single scalar, dropping empty segments (equivalent
/// to split with omittingEmptySubsequences: true). Used for whitespace-delimited
/// graph node and edge lines where consecutive delimiters must not yield empty
/// fields.
func scalarSplitNonEmpty(_ s: String, _ sep: Unicode.Scalar) -> [String] {
    var parts: [String] = []
    var current: [Unicode.Scalar] = []
    for c in s.unicodeScalars {
        if c == sep {
            if !current.isEmpty { parts.append(String(String.UnicodeScalarView(current))); current = [] }
        } else {
            current.append(c)
        }
    }
    if !current.isEmpty { parts.append(String(String.UnicodeScalarView(current))) }
    return parts
}

/// Returns true if the scalar view of `s` contains the scalars of `needle`.
func scalarContains(_ s: String, _ needle: String) -> Bool {
    let sv = Array(s.unicodeScalars)
    let nv = Array(needle.unicodeScalars)
    if nv.isEmpty { return true }
    if sv.count < nv.count { return false }
    for start in 0...(sv.count - nv.count) {
        var match = true
        for k in 0..<nv.count {
            if sv[start + k] != nv[k] { match = false; break }
        }
        if match { return true }
    }
    return false
}
