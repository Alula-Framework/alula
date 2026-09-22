import Synchronization

/// The default store: one timestamp per key in a bounded dictionary.
///
/// Right for one replica, for development, and for tests, with its limit
/// stated plainly: **this is per-process**. Two replicas behind a load
/// balancer each enforce the quota separately, so a client spreading calls
/// across them gets the quota times the replica count. For anything with
/// more than one instance that is not a rate limiter, and
/// `FlightRateLimitValkey` in flight-data is the store to use instead.
/// Configuring that adapter's URL without listing its module is refused at
/// composition for exactly this reason.
///
/// Bounded, because a key space an attacker chooses is a key space an
/// attacker can grow: limiting by address or by login identifier means the
/// caller decides how many distinct keys exist. Eviction is by closeness to
/// expiry, and an evicted key is a key restored to full allowance, which is
/// the honest failure direction for a bound: dropping state can only ever be
/// too permissive, never wrongly punitive.
public final class InMemoryRateLimitStore: RateLimitStore, Sendable {
    public static let defaultMaxEntries = 100_000

    private struct State {
        /// Theoretical arrival time per key, in seconds on `clock`.
        var arrivals: [String: Double] = [:]
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> Double
    public let maxEntries: Int

    /// - Parameters:
    ///   - maxEntries: The bound. Positive, or a programming error.
    ///   - now: The clock, in seconds, injectable so a test asserts an exact
    ///     sequence of decisions without sleeping. Defaults to a monotonic
    ///     clock rather than a wall clock: a rate limiter that can be
    ///     rewound by an NTP correction is a rate limiter with a bypass.
    public init(
        maxEntries: Int = InMemoryRateLimitStore.defaultMaxEntries,
        now: (@Sendable () -> Double)? = nil
    ) {
        precondition(
            maxEntries > 0,
            "InMemoryRateLimitStore is bounded by design — maxEntries must be positive.")
        self.maxEntries = maxEntries
        self.now = now ?? InMemoryRateLimitStore.monotonicSeconds
    }

    public func consume(key: String, cost: Int, quota: RateLimitQuota) async throws
        -> RateLimitDecision
    {
        let now = now()
        return state.withLock { state in
            let outcome = GCRA.decide(now: now, tat: state.arrivals[key], cost: cost, quota: quota)
            if outcome.isAllowed && cost > 0 {
                state.arrivals[key] = outcome.tat
                enforceBound(&state, now: now)
            }
            return RateLimitDecision(
                isAllowed: outcome.isAllowed,
                remaining: outcome.remaining,
                retryAfter: outcome.retryAfter.map(Duration.rateLimitSeconds),
                resetAfter: .rateLimitSeconds(outcome.resetAfter))
        }
    }

    /// Live keys, expired ones included until swept. Introspection for tests.
    public var count: Int {
        state.withLock { $0.arrivals.count }
    }

    /// Runs under the lock. Keys whose arrival time has passed are back at
    /// full allowance and carry no information, so they go first; if that is
    /// not enough, the keys closest to expiring go in a batch, so the sort is
    /// paid once per batch rather than once per call.
    private func enforceBound(_ state: inout State, now: Double) {
        guard state.arrivals.count > maxEntries else { return }
        state.arrivals = state.arrivals.filter { $0.value > now }
        guard state.arrivals.count > maxEntries else { return }
        let excess = state.arrivals.count - maxEntries + max(1, maxEntries / 16)
        for (key, _) in state.arrivals.sorted(by: { $0.value < $1.value }).prefix(excess) {
            state.arrivals.removeValue(forKey: key)
        }
    }

    private static let started = ContinuousClock.now

    private static let monotonicSeconds: @Sendable () -> Double = {
        started.duration(to: ContinuousClock.now).rateLimitSeconds
    }
}
