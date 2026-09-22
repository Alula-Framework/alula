/// The Generic Cell Rate Algorithm, as a rate limiter.
///
/// One number of state per key: the theoretical arrival time, the instant at
/// which the key would next be exactly on its budgeted rate. A call is
/// admitted when that instant is no further ahead of now than the burst
/// allows, and admitting it pushes the instant forward by the call's cost.
///
/// ## Why not a fixed window
///
/// A fixed window counts calls per clock interval and resets on the
/// boundary, which admits **twice the quota** across one: a hundred calls in
/// the last instant of one minute and a hundred in the first instant of the
/// next is two hundred inside two seconds, from a limiter configured for a
/// hundred a minute. Sliding-window logs fix that by keeping a timestamp per
/// call, which is unbounded memory per key and an O(n) prune on every call.
///
/// GCRA gets the smoothness of a sliding window from a single timestamp. It
/// never admits more than `burst` at once and never more than the sustained
/// rate over any interval, and its state is one number, which is also why it
/// ports to a distributed store unchanged: the whole decision is a read, a
/// comparison and a write of one value, which a Valkey `EVAL` does in one
/// round trip with no lock and no read-modify-write race.
///
/// ## Why the math is integer microseconds
///
/// Because it has to be exact, and because the Valkey store does the same
/// arithmetic in Lua, where numbers are doubles.
///
/// In fractional seconds this is subtly wrong for any store keyed on wall
/// time. Subtracting two timestamps near 1.8e15 leaves about half a
/// microsecond of floating-point error, which is enough to report one permit
/// fewer than are actually free — caught by the differential test that runs
/// these scenarios against both stores, and not by anything else. In whole
/// microseconds every value here is an exact integer: exact in an `Int64`,
/// and exact in a `Double` too, since microseconds since the epoch stay
/// inside the 53-bit integer range until the year 2255. Two implementations
/// of one algorithm can then be compared line by line, and neither needs an
/// epsilon.
enum GCRA {
    struct Outcome: Equatable {
        /// Whether the call is admitted.
        var isAllowed: Bool
        /// The theoretical arrival time to store, in microseconds. On a
        /// denial this is the value that was already there: a refused call
        /// consumes nothing, which is what keeps a client hammering a closed
        /// door from pushing its own recovery further away.
        var tat: Int64
        var remaining: Int
        /// Microseconds until this call would be admitted; `nil` when it is,
        /// and `nil` when no wait would help.
        var retryAfter: Int64?
        /// Microseconds until the key is back to a full burst.
        var resetAfter: Int64
    }

    /// - Parameters:
    ///   - now: The current time in microseconds, on whatever clock the
    ///     store keeps its stored values on.
    ///   - tat: The stored theoretical arrival time, or `nil` for a key this
    ///     store has not seen.
    ///   - cost: Permits this call spends. Zero reports the current state
    ///     and changes nothing.
    static func decide(now: Int64, tat storedTAT: Int64?, cost: Int, quota: RateLimitQuota)
        -> Outcome
    {
        precondition(cost >= 0, "A rate limit cost cannot be negative; got \(cost).")
        let emission = quota.emissionIntervalMicroseconds
        let burstOffset = quota.burstOffsetMicroseconds

        // A key whose theoretical arrival time is in the past is a key that
        // has been idle long enough to be back at full: start from now, not
        // from the stale value, or an idle key would bank credit forever.
        let tat = max(storedTAT ?? now, now)

        // A free probe: what is the state, without spending anything.
        if cost == 0 {
            return Outcome(
                isAllowed: true, tat: tat,
                remaining: permits(level: tat - now, burstOffset: burstOffset, emission: emission),
                retryAfter: nil, resetAfter: tat - now)
        }

        // Costing more than the burst is refused outright rather than
        // deferred. No wait makes it admissible, because each wait advances
        // `now` and the stored value together.
        guard cost <= quota.burst else {
            return Outcome(
                isAllowed: false, tat: tat,
                remaining: permits(level: tat - now, burstOffset: burstOffset, emission: emission),
                retryAfter: nil, resetAfter: tat - now)
        }

        let newTAT = tat + Int64(cost) * emission
        let admitAt = newTAT - burstOffset
        guard admitAt <= now else {
            return Outcome(
                isAllowed: false, tat: tat,
                remaining: permits(level: tat - now, burstOffset: burstOffset, emission: emission),
                retryAfter: admitAt - now, resetAfter: tat - now)
        }
        return Outcome(
            isAllowed: true, tat: newTAT,
            remaining: permits(level: newTAT - now, burstOffset: burstOffset, emission: emission),
            retryAfter: nil, resetAfter: newTAT - now)
    }

    /// How many whole permits are still free, given how far ahead of now the
    /// theoretical arrival time sits. Exact integer division; no epsilon,
    /// because there is no rounding error left to absorb.
    private static func permits(level: Int64, burstOffset: Int64, emission: Int64) -> Int {
        guard emission > 0 else { return 0 }
        let free = burstOffset - level
        guard free > 0 else { return 0 }
        return Int(free / emission)
    }
}
