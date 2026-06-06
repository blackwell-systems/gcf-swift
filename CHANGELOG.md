# Changelog

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
