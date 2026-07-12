import Foundation

// MARK: - Generic-profile delta session helper (SPEC Section 10a.8)
//
// `GenericDeltaSession` is a producer-side helper that manages the re-anchor
// cadence for a stream of generic-profile updates (SPEC Section 10a.8, which is
// non-normative producer policy). It is thin sugar over the primitives: each
// `next` emits either a compact delta or, on its chosen cadence, a full
// re-anchor (the spec's "full" outcome), updating its held base. It introduces
// NO new wire syntax: every payload it emits is exactly what `encodeGenericFull`
// or `encodeGenericDelta` produce, and the decoder accepts them cadence-
// agnostically. N and the size guard are the helper's knobs; they are never wire
// fields. Byte-for-byte interoperable with gcf-go, gcf-python, gcf-typescript,
// gcf-rust, and gcf-kotlin.

/// The working default cadence for `.fixedN` (SPEC Section 10a.8).
public let DEFAULT_REANCHOR_N = 15

/// Selects when a `GenericDeltaSession` re-anchors.
///   - `.fixedN(n)`: re-anchor every `n` turns.
///   - `.sizeGuard`: re-anchor once the cumulative delta since the last anchor
///     reaches the current full payload's size (size-adaptive).
///
/// Construct `.fixedN` via `ReanchorPolicy.fixed(_:)` so that `n <= 0` clamps to
/// `DEFAULT_REANCHOR_N`.
public enum ReanchorPolicy {
    /// Re-anchor every N turns.
    case fixedN(Int)
    /// Re-anchor once the cumulative delta bytes since the last anchor reach the
    /// current full payload's byte size: it re-anchors more under heavy churn,
    /// rarely under light churn, and bounds the delta spent between anchors to
    /// about one full payload. Production-recommended.
    case sizeGuard

    /// Re-anchor every `n` turns. `n <= 0` falls back to `DEFAULT_REANCHOR_N`.
    public static func fixed(_ n: Int) -> ReanchorPolicy {
        .fixedN(n <= 0 ? DEFAULT_REANCHOR_N : n)
    }
}

/// Holds the current base and re-anchor state for a producer loop. Not safe for
/// concurrent use.
public final class GenericDeltaSession {
    private var base: GenericSet
    private let tool: String
    private let policy: ReanchorPolicy
    private var turn: Int = 0
    private var cum: Int = 0 // cumulative delta bytes since the last anchor

    /// Start a session anchored on `base`. Call `currentFull()` to get the initial
    /// full payload to transmit, then `next(_:)` for each subsequent state.
    public init(base: GenericSet, tool: String, policy: ReanchorPolicy) {
        var p = policy
        if case .fixedN(let n) = p, n <= 0 { p = .fixedN(DEFAULT_REANCHOR_N) }
        self.base = base
        self.tool = tool
        self.policy = p
    }

    /// The number of `next(_:)` calls so far (the initial full is turn 0).
    public var currentTurn: Int { turn }

    /// Returns the full payload for the current base (`encodeGenericFull`). Send
    /// this first to establish the base; it is also a valid manual re-anchor.
    public func currentFull() -> String {
        encodeGenericFull(base, tool: tool)
    }

    /// Advance the session by one turn to `next`, returning the wire to transmit
    /// and whether it is a full re-anchor (`true`) or a delta (`false`). A schema
    /// change forces a full (Section 10a.7). The held base becomes `next` either
    /// way. The wire is byte-identical to calling `encodeGenericFull` /
    /// `encodeGenericDelta` directly.
    public func next(_ next: GenericSet) throws -> (wire: String, isFull: Bool) {
        turn += 1

        // Schema change (or a fresh key) cannot be expressed as a delta -> full.
        if next.key != base.key || base.fields != next.fields {
            return (reanchor(next), true)
        }

        let d = try diffGenericSets(base, next)
        let deltaWire = encodeGenericDelta(d)

        let doReanchor: Bool
        switch policy {
        case .sizeGuard:
            doReanchor = cum + byteLen(deltaWire) >= byteLen(encodeGenericFull(next, tool: tool))
        case .fixedN(let n):
            doReanchor = turn % n == 0
        }

        if doReanchor {
            return (reanchor(next), true)
        }
        base = next
        cum += byteLen(deltaWire)
        return (deltaWire, false)
    }

    /// Emit a full payload for `next`, advance the base, and reset the
    /// cumulative-delta counter.
    private func reanchor(_ next: GenericSet) -> String {
        let wire = encodeGenericFull(next, tool: tool)
        base = next
        cum = 0
        return wire
    }
}

/// UTF-8 byte length, matching Go's `len(string)`. NOT grapheme-cluster count.
private func byteLen(_ s: String) -> Int { s.utf8.count }
