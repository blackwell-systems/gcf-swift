# Changelog

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
