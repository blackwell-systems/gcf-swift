import Foundation

// Keyed-tabular map encoding (SPEC 7.2a, v3.5), canonical / default-on.
//
// A JSON object whose values are all objects forming a losslessly-tabular set is
// encoded as a keyed table `## [N:]{key,field1,...}`: the shared value fields are
// declared once in a header, and each member is one positional row prefixed by its
// key. This is the object-valued analogue of Section 7.4 tabular array encoding.

/// The result of testing an object for keyed-map eligibility (SPEC 7.2a.1).
struct KeyedMapPlan {
    let keys: [String]         // ordered member keys
    let values: [Any]          // corresponding value objects
    let valueFields: [String]  // ordered value-field union (Section 7.4.3)
    let keyLabel: String       // key-column label ("key", "_key" on collision)
}

/// Reports whether `value` is a keyed map of objects that should render as a keyed
/// table. Returns a plan (member keys, value objects, value-field union, key label)
/// or nil when the object uses Section 7.2 section encoding instead.
func keyedMapEligible(_ value: Any) -> KeyedMapPlan? {
    guard let pairs = asOrderedDict(value) else { return nil }
    if pairs.isEmpty { return nil }

    let keys = pairs.map { $0.0 }
    let values = pairs.map { $0.1 }

    // A keyed map requires at least two members: the form factors the shared value
    // fields into one header, which only pays off across multiple members. A
    // single-member map yields a one-row table the same size as a section, so keying
    // it would change canonical output for every nested single-member object (e.g. a
    // {"data":{...}} wrapper) with no benefit (SPEC 7.2a.1). Single-member objects
    // use ordinary encoding; a single-key wrapper of a multi-member map therefore
    // defers, and the inner map is keyed at its own level.
    if keys.count < 2 { return nil }

    // Every value must be a non-empty object; build the ordered field union.
    var valueFields: [String] = []
    var seen = Set<String>()
    for v in values {
        // A null or non-object value disqualifies the keyed form (SPEC 7.2a.1).
        if v is NSNull { return nil }
        guard let vo = asOrderedDict(v) else { return nil }
        for (f, _) in vo {
            if !seen.contains(f) {
                seen.insert(f)
                valueFields.append(f)
            }
        }
    }
    // All-empty value objects have an empty field union and are not eligible.
    if valueFields.isEmpty { return nil }

    // A keyed header needs at least one value field that can be a tabular column. A
    // field name containing ">" cannot be a column (SPEC 7.4.6.1.4); if every value
    // field contains ">", the keyed form would have only the key column, which is
    // invalid. Such a map uses Section 7.2 section encoding instead, the object
    // analogue of an array falling back to expanded form.
    if !valueFields.contains(where: { !$0.contains(">") }) { return nil }

    // Key-column label: "key", made unique by prepending "_" on collision.
    var keyLabel = "key"
    while valueFields.contains(keyLabel) {
        keyLabel = "_" + keyLabel
    }

    return KeyedMapPlan(keys: keys, values: values, valueFields: valueFields, keyLabel: keyLabel)
}

/// Builds the header prefix up to the count bracket. `named` distinguishes an
/// anonymous root keyed map (`## `) from a named member whose name may itself be
/// the empty string (`## ""`), which formatKey quotes so it round-trips as a
/// distinct level rather than collapsing into the anonymous root form.
func keyedHeaderPrefix(name: String, named: Bool, depth: Int) -> String {
    let prefix = String(repeating: "  ", count: depth)
    if !named { return prefix + "## " }
    return prefix + "## " + formatKey(name) + " "
}

/// Augments each value object with the key column and routes through the tabular
/// encoder with the keyed bracket, so nested-value handling (flatten/inline/
/// attachment/null/absent) is inherited unchanged. `name` is empty for a root or
/// anonymous keyed map.
func encodeKeyedMap(_ plan: KeyedMapPlan, name: String, named: Bool, out: inout String, depth: Int, opts: GenericOptions) {
    encodeKeyedMapWithPrefix(plan, headerPrefix: keyedHeaderPrefix(name: name, named: named, depth: depth),
                             out: &out, depth: depth, opts: opts)
}

/// Emits `<headerPrefix>[N:]{...}` and the keyed rows, reusing the tabular encoder.
/// `headerPrefix` is the full prefix up to the count bracket.
func encodeKeyedMapWithPrefix(_ plan: KeyedMapPlan, headerPrefix: String, out: inout String, depth: Int, opts: GenericOptions) {
    let fields = [plan.keyLabel] + plan.valueFields

    // Build the augmented row array: each value object plus the key column.
    var arr: [Any] = []
    arr.reserveCapacity(plan.keys.count)
    for (i, k) in plan.keys.enumerated() {
        let aug = OrderedDictionary()
        if let vo = asOrderedDict(plan.values[i]) {
            for (kk, vv) in vo { aug[kk] = vv }
        }
        aug[plan.keyLabel] = k
        arr.append(aug)
    }

    encodeTabular(headerPrefix, arr: arr, fields: fields, out: &out, depth: depth, opts: opts, keyed: true)
}

/// Reconstructs the map from decoded keyed-table rows: the first declared field is
/// the member key; the remaining fields form the value object. The key-column label
/// is discarded and MUST NOT appear as a member of any value object (SPEC 7.2a.4).
func keyedRowsToMap(_ rows: [Any], fields: [String]) throws -> OrderedDictionary {
    if fields.count < 2 {
        throw GCFError.invalidFieldDeclaration("keyed_map: header must declare at least two fields")
    }
    let keyLabel = fields[0]
    let out = OrderedDictionary()
    for r in rows {
        guard let row = r as? OrderedDictionary else {
            throw GCFError.invalidFieldDeclaration("keyed_map: row is not an object")
        }
        guard let kv = row[keyLabel] else {
            throw GCFError.invalidFieldDeclaration("keyed_map: row missing key column \(keyLabel)")
        }
        let ks: String
        if let s = kv as? String { ks = s } else { ks = "\(kv)" }
        if out[ks] != nil {
            throw GCFError.duplicateKey(ks)
        }
        row[keyLabel] = nil
        out[ks] = row
    }
    return out
}
