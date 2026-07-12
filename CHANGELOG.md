# Changelog

## v2.3.0 (2026-07-12)

### Generic-profile delta encoding (SPEC §10a)

- Full producer + consumer implementation of generic-profile delta, byte-for-byte interoperable with `gcf-go`, `gcf-python`, `gcf-typescript`, and `gcf-rust`:
  - `GenericSet` (keyed record set), `GenericDeltaPayload`
  - `genericPackRoot` (`gcf-pack-root-v1`, generic profile) with a purpose-built cell canonicalization (`canonicalCell`) decoupled from the wire cell encoder: collision-free (null/bool/number bare, strings always quoted) and record-safe. Fields and records sort by UTF-8 byte order (`utf8.lexicographicallyPrecedes`) because Swift's default `String` ordering is Unicode-normalized, not byte-wise; this keeps pack roots identical across SDKs.
  - `diffGenericSets` (the blessed producer path; centralizes the keyed-diff invariants), `encodeGenericFull`, `encodeGenericDelta`
  - `decodeGenericFull`, `decodeGenericDelta` (consumer wire parsing)
  - `verifyGenericDelta` (atomic apply + `new_root` verification)
- Delta is opt-in and bilateral; the existing `encodeGeneric` path is unchanged (backward compatible). SHA-256 uses the platform `CryptoKit` framework (no package dependency added).

### Generic-profile delta session helper (SPEC §10a.8)

- `GenericDeltaSession`: producer-side helper that manages the re-anchor cadence for a stream of generic-profile updates. Each `next(_:)` emits either a compact delta or, on its chosen cadence, a full re-anchor, updating its held base; a schema change forces a full (§10a.7). It introduces no new wire syntax: every payload is byte-identical to `encodeGenericFull` / `encodeGenericDelta`, and the decoder accepts them cadence-agnostically. `ReanchorPolicy` is `.fixedN(n)` (re-anchor every n turns; construct via `ReanchorPolicy.fixed(_:)` so n <= 0 clamps to `DEFAULT_REANCHOR_N` = 15) or `.sizeGuard` (re-anchor once cumulative delta bytes reach the current full payload's byte size). Byte-for-byte interoperable with `gcf-go`, `gcf-python`, `gcf-typescript`, `gcf-rust`, and `gcf-kotlin`; cadence byte accounting uses UTF-8 length (`utf8.count`) to match the reference implementations.
- Conformance runner support for `generic-delta-session` (3 shared fixtures: fixed-N cadence, size-guard, schema-change forced full); unit suite mirrors the Go tests (fixed-N pattern, size-guard trigger, 30-turn cadence count, and the load-bearing consumer-stays-in-sync invariant under both policies).

### Tests

- Unit suite mirroring the other SDKs: self-proving round-trip (diff -> encode -> apply -> recomputed root), determinism / row-order invariance, no-type-collision canonicalization, every invariant/error path, full-payload wire round-trip, the complete server -> wire -> consumer end-to-end loop, and malformed-wire-fails-closed.
- Conformance runner support for `generic-pack-root`, `generic-delta`, `generic-delta-verify`, `generic-delta-decode` (12 shared fixtures); produces identical pack roots and delta wire to the Go, Python, TypeScript, and Rust SDKs.
- Generic-delta fuzz (`GenericDeltaFuzzTests`), mirroring `gcf-go`: the decoder never crashes on arbitrary/mutated input, and arbitrary UTF-8 string cells (including multi-byte and control characters) survive the full-wire round-trip with the pack root preserved.

## v2.2.3 (2026-07-10)

### Fixes

- **Graph encode parity:** the graph encoder now sorts symbols by distance ascending then score descending (assigning `@N` ids in output order) and omits zero-valued header fields (`budget`, `tokens`, `edges`), matching the reference SDKs byte-for-byte. Previously Swift emitted symbols in input order with `budget=0 tokens=0 edges=0` always present, diverging from the other implementations.
- **Ordered JSON parse:** `parseJSONOrdered` is now a proper recursive-descent parser. The prior implementation scanned the whole document for each key's first `"key":` occurrence, which mis-ordered nested-object keys (a nested `{id,name}` could pick up an earlier top-level `name`), and routed through `JSONSerialization`, which dropped negative-zero. Nested key order and `-0` now round-trip faithfully.

### Tests

- Added `ConformanceV2Test`, running the shared cross-SDK conformance fixtures (`gcf/tests/conformance`) against the Swift implementation, mirroring the TypeScript/Go/Rust/Python/Kotlin runners. Skips only session/delta/pack-root/delta-verify and binary inputs. One deliberate Swift-only byte divergence is round-trip-checked but not byte-matched: the encoder quotes any non-ASCII scalar (grapheme-cluster safety), so an emoji string is quoted where other SDKs leave it bare.

## v2.2.2 (2026-07-10)

### Fixes

- **Losslessness (nested null):** a nested object that is null at an intermediate level (e.g. `{"meta":{"owner":null}}`) is no longer flattened. Previously its leaves encoded as absent (`~`) and unflattened to a missing key, silently dropping the null. Such fields now fall back to the attachment mechanism; a top-level null still flattens losslessly (emits `-`, reconstructs via the all-null rule). Prototype pollution does not affect Swift (dictionary-based).

### Tests

- `testPropertyRoundTripFlatten`: aligned arrays whose shared fields are fixed-shape nested objects, with a field or an intermediate nested level sometimes null/absent — the shape the prior scalar-only generator never produced, leaving the flatten/unflatten path unexercised. Verified to fail on the pre-fix encoder and pass on the fix.

## v2.2.1 (2026-06-23)

### Flatten Opt-Out

- Added `GenericOptions` struct with `noFlatten` parameter to disable nested object flattening
- `encodeGeneric(data, opts: GenericOptions(noFlatten: true))` produces attachment syntax instead of path columns
- Backward compatible: `encodeGeneric(data)` behavior unchanged (flatten on by default)
- Fixed: field names containing `>` no longer appear as tabular columns (spec rule 7.4.6.1.4)
- Fixed: field names containing `>` no longer eligible for flattening analysis
- Fixed: decoder no longer treats literal `>` in key names as a path separator
- Fixed: decoder accepts orphan attachments (fields excluded from column list)
- 10 targeted edge case tests for `>` in field names (both flatten modes)

## v2.2.0 (2026-06-22)

### Spec v3.2: Nested Object Flattening

- Encoder automatically flattens fixed-shape nested objects into `>` path column names
- Decoder reconstructs nested objects from `>` path columns
- 20-48% fewer tokens on deeply nested API data
- Zero regression on lossless round-trips (200K random + adversarial)
- Falls back to attachment mechanism for non-flattenable cases

## v2.1.0 (2026-06-14)

### Spec v3.1

- `tool` field in graph profile header is now optional (SHOULD be present for MCP, not required)
- Removed `missingTool` case from `DecodeError` enum

### Bug Fixes

- Quote strings containing commas (conformance: `inline-schema/006_inline_with_quoted_values`)
- Decode v2-format indented attachments in tabular rows (conformance: `decode/002_attachment`)
- Reject duplicate attachments on the same row (conformance: `errors-v2/027_duplicate_attachment`)
- Reject orphan attachments on rows without `^` cells (conformance: `errors-v2/016_orphan_attachment`)

## v2.0.0 (2026-06-12)

### Breaking Changes

- `encodeGeneric` now produces inline schema format (not backwards compatible with v1.x decoders)
- Attachment lines no longer indented (same depth as parent row)
- Inline object fields use positional encoding without field-name prefix

### New Features

- Inline object schema: objects with 3+ scalar fields encoded positionally with `^{fields}` header
- Shared array schemas: identical nested arrays omit `{fields}` after first row
- 472M+ fuzz iterations across all 6 implementations, zero failures

### Bug Fixes

- Quote strings starting with `.` (dot prefix)
- Quote C1 control characters (U+0080-U+009F)
- Quote Unicode whitespace (NBSP, hair space, etc.)
- Fix grapheme clustering in attachment name parsing (U+08E2 combining with delimiters)

## v1.0.1 (2026-06-10)

- CLI: `GCFCLI` executable with `encode`, `decode`, `encode-generic`, `decode-generic` subcommands
- `OrderedDictionary`: insertion-order-preserving dictionary for conformance-grade round-trips
- `decodeGeneric` now returns `OrderedDictionary` instead of `NSMutableDictionary`
- `encodeGeneric` accepts `OrderedDictionary` input (preserves key order)
- Property-based round-trip tests: 50M values (25M random zero failures, 25M adversarial 2 edge cases at 99.999992%)
- Fix: number precision loss in exponent notation (`%e` replaced with shortest-exact representation)
- Fix: Unicode combining marks (Mn/Mc/Me) merging with delimiters in grapheme clustering
- Fix: `splitRespectingQuotes` rewritten to operate on unicode scalars, not grapheme clusters
- Fix: `findKVSplit`, `findClosingBrace`, `splitFieldDecl` rewritten for scalar-safe parsing
- Fix: NSRegularExpression `$` anchor matching before `\n` (replaced with `\z`)
- Fix: `dropFirst()` consuming combining marks after `=` delimiter
- Fix: Thai Sara Am (U+0E33) and similar characters clustering with ASCII delimiters
- All non-ASCII characters now quoted to prevent grapheme clustering edge cases

## v1.0.0 (2026-06-07)

- SPEC v2.0 implementation: `GCF profile=generic` header, common scalar grammar, `^` attachments, `~` missing, expanded form, root scalars/arrays
- Full JSON string escaping (`\b`, `\f`, `\n`, `\r`, `\t`, `\uXXXX`, surrogate pairs)
- Encoder quoting obligation (strings colliding with typed literals must be quoted)
- 30 strict-mode decoder error conditions
- NSNumber bool/int disambiguation via `CFBooleanGetTypeID()`

## v0.5.0 (2026-06-05)

- `GenericStreamEncoder`: zero-buffering tabular streaming encode (beginArray/writeRow/endArray/writeKV/writeSection/writeInlineArray)
- `decodeGeneric`: parse GCF tabular text into `Any` (tabular arrays, key-value, nested sections, inline arrays, nested row fields, empty arrays, graph fallback)

## v0.3.0 (2026-06-05)

- `encodeGeneric`: primitive arrays inlined as `name[N]: val1,val2,val3`

## v0.2.0 (2026-06-05)

- **Breaking**: `encode()` now emits `edges=N` in header line
- **Breaking**: `encode()` now emits `## edges [N]` section header (was `## edges`)
- `decode()` updated to parse `## edges [N]` format (strips bracket suffix)
- Session encoder updated to emit new edge count format

## v0.1.0 (2026-06-04)

- Initial release
- `encode` / `decode`: full GCF round-trip
- `encodeWithSession`: session deduplication
- `encodeDelta`: delta encoding
- `encodeGeneric`: tabular profile encoding
- Thread-safe `Session` class (NSLock)
- 16 kind abbreviations
- Swift Package Manager distribution, zero dependencies
