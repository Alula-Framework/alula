import Testing

@testable import AlulaRateLimit

/// The algorithm, driven directly. The store tests exercise the same math
/// through the seam; these pin the arithmetic so a failure says which of the
/// two is wrong.
@Suite("GCRA")
struct GCRATests {
    private let tenPerSecond = RateLimitQuota.perSecond(10)

    /// Runs `count` calls at `now` from `tat`, returning the final outcome.
    private func spend(
        _ count: Int, at now: Int64, from tat: Int64?, quota: RateLimitQuota
    ) -> GCRA.Outcome {
        var outcome = GCRA.decide(now: now, tat: tat, cost: 0, quota: quota)
        for _ in 0..<count {
            outcome = GCRA.decide(now: now, tat: outcome.tat, cost: 1, quota: quota)
        }
        return outcome
    }

    @Test("a fresh key may spend its whole burst at once, and no more")
    func burstThenRefuse() {
        let tenth = spend(10, at: 0, from: nil, quota: tenPerSecond)
        #expect(tenth.isAllowed)
        #expect(tenth.remaining == 0)
        #expect(tenth.resetAfter == 1_000_000, "the whole period, having spent the whole quota")

        let eleventh = GCRA.decide(now: 0, tat: tenth.tat, cost: 1, quota: tenPerSecond)
        #expect(!eleventh.isAllowed)
        #expect(eleventh.retryAfter == 100_000, "one emission interval, not the whole period")
        #expect(!eleventh.isUnsatisfiableOutcome)
    }

    @Test("remaining counts down one per permit")
    func remainingCountsDown() {
        var tat: Int64? = nil
        for expected in stride(from: 9, through: 0, by: -1) {
            let outcome = GCRA.decide(now: 0, tat: tat, cost: 1, quota: tenPerSecond)
            #expect(outcome.isAllowed)
            #expect(outcome.remaining == expected, "after spending \(10 - expected)")
            tat = outcome.tat
        }
    }

    @Test("a refused call spends nothing")
    func denialDoesNotConsume() {
        // The property that matters under a retry loop: a client hammering a
        // closed door must not push its own recovery further away.
        var tat = spend(10, at: 0, from: nil, quota: tenPerSecond).tat
        for _ in 0..<50 {
            let denied = GCRA.decide(now: 0, tat: tat, cost: 1, quota: tenPerSecond)
            #expect(!denied.isAllowed)
            tat = denied.tat
        }
        // One emission interval later exactly one permit is back, as though
        // the fifty refusals had never happened.
        let recovered = GCRA.decide(now: 100_000, tat: tat, cost: 1, quota: tenPerSecond)
        #expect(recovered.isAllowed)
        let next = GCRA.decide(now: 100_000, tat: recovered.tat, cost: 1, quota: tenPerSecond)
        #expect(!next.isAllowed, "exactly one, not two")
    }

    @Test("permits refill continuously rather than on a boundary")
    func continuousRefill() {
        // The fixed-window failure this algorithm exists to avoid: a window
        // would admit the full quota again the instant the boundary passed.
        let spent = spend(10, at: 0, from: nil, quota: tenPerSecond)
        let halfway = GCRA.decide(now: 500_000, tat: spent.tat, cost: 0, quota: tenPerSecond)
        #expect(halfway.remaining == 5, "half a period back means half the quota back")

        let full = GCRA.decide(now: 1_000_000, tat: spent.tat, cost: 0, quota: tenPerSecond)
        #expect(full.remaining == 10)
    }

    @Test("an idle key banks nothing beyond its burst")
    func idleDoesNotBank() {
        let spent = spend(10, at: 0, from: nil, quota: tenPerSecond)
        // An hour later the key is at full, not at an hour's worth.
        let after = spend(10, at: 3_600_000_000, from: spent.tat, quota: tenPerSecond)
        #expect(after.isAllowed)
        #expect(after.remaining == 0)
        #expect(
            !GCRA.decide(now: 3_600_000_000, tat: after.tat, cost: 1, quota: tenPerSecond).isAllowed
        )
    }

    @Test("burst is separable from rate")
    func burstSeparateFromRate() {
        // Sixty a minute with a burst of one is one per second, strictly.
        let quota = RateLimitQuota.perMinute(60, burst: 1)
        let first = GCRA.decide(now: 0, tat: nil, cost: 1, quota: quota)
        #expect(first.isAllowed)
        let second = GCRA.decide(now: 0, tat: first.tat, cost: 1, quota: quota)
        #expect(!second.isAllowed)
        #expect(second.retryAfter == 1_000_000)
        #expect(GCRA.decide(now: 1_000_000, tat: first.tat, cost: 1, quota: quota).isAllowed)
    }

    @Test("cost is charged in whole permits")
    func costCharged() {
        let outcome = GCRA.decide(now: 0, tat: nil, cost: 4, quota: tenPerSecond)
        #expect(outcome.isAllowed)
        #expect(outcome.remaining == 6)
        let rest = GCRA.decide(now: 0, tat: outcome.tat, cost: 7, quota: tenPerSecond)
        #expect(!rest.isAllowed, "seven does not fit in the six that are left")
        #expect(GCRA.decide(now: 0, tat: outcome.tat, cost: 6, quota: tenPerSecond).isAllowed)
    }

    @Test("a cost larger than the burst is refused permanently, not deferred")
    func costExceedingBurst() {
        let outcome = GCRA.decide(now: 0, tat: nil, cost: 11, quota: tenPerSecond)
        #expect(!outcome.isAllowed)
        #expect(outcome.retryAfter == nil, "no wait makes it admissible")
        #expect(outcome.isUnsatisfiableOutcome)
        // And waiting really does not help, which is why saying "retry in
        // 100ms" would have been a lie.
        #expect(
            !GCRA.decide(now: 60_000_000, tat: outcome.tat, cost: 11, quota: tenPerSecond).isAllowed
        )
    }

    @Test("the arithmetic is exact at wall-clock magnitudes")
    func exactAtWallClockMagnitudes() {
        // The bug the differential test against the Valkey store caught. In
        // fractional seconds, subtracting timestamps near 1.8e15 leaves
        // enough error to report nine permits free where ten are. In whole
        // microseconds it is exact, at any magnitude a clock will produce.
        let now: Int64 = 1_790_000_000_123_456
        let first = GCRA.decide(now: now, tat: nil, cost: 1, quota: tenPerSecond)
        #expect(first.isAllowed)
        #expect(first.remaining == 9, "nine free, not eight")

        let tenth = spend(9, at: now, from: first.tat, quota: tenPerSecond)
        #expect(tenth.remaining == 0)
        #expect(!GCRA.decide(now: now, tat: tenth.tat, cost: 1, quota: tenPerSecond).isAllowed)
    }

    @Test("a zero cost reports the state and changes nothing")
    func zeroCostProbes() {
        let spent = spend(3, at: 0, from: nil, quota: tenPerSecond)
        let probe = GCRA.decide(now: 0, tat: spent.tat, cost: 0, quota: tenPerSecond)
        #expect(probe.isAllowed)
        #expect(probe.remaining == 7)
        #expect(probe.tat == spent.tat, "probing spends nothing")
    }

    @Test("a quota built from data is nil when the numbers cannot make one, rather than a trap")
    func validatingQuota() {
        #expect(RateLimitQuota(validating: 0, per: .seconds(60)) == nil)
        #expect(RateLimitQuota(validating: 10, per: .zero) == nil)
        #expect(RateLimitQuota(validating: 10, per: .seconds(60), burst: -1) == nil)
        #expect(RateLimitQuota(validating: 10, per: .seconds(60))?.burst == 10)
    }

    @Test("the in-memory store refuses a negative cost with an error, not a trap")
    func negativeCostThrows() async {
        let store = InMemoryRateLimitStore()
        await #expect(throws: RateLimitStoreError.self) {
            _ = try await store.consume(key: "k", cost: -1, quota: .perMinute(5))
        }
    }
}

extension GCRA.Outcome {
    /// The store maps this onto `RateLimitDecision.isUnsatisfiable`; the
    /// algorithm's own spelling of it, for these tests.
    fileprivate var isUnsatisfiableOutcome: Bool { !isAllowed && retryAfter == nil }
}
