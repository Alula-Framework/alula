/// How much traffic a key is allowed: a rate, and how much of it may arrive
/// at once.
///
/// ```swift
/// .perMinute(100)              // 100 a minute, and all 100 may arrive together
/// .perMinute(100, burst: 10)   // 100 a minute, at most 10 at once
/// .perSecond(5, burst: 1)      // strictly one every 200ms, no clumping
/// ```
///
/// Two numbers rather than one because they answer different questions.
/// ``permits`` over ``period`` is the sustained rate, which is the number an
/// operator budgets for. ``burst`` is how far ahead of that rate a caller may
/// run, which is what decides whether a page issuing twelve requests on load
/// works or fails. A limiter with only the first number has to pick a burst
/// silently, and every choice is wrong for somebody.
///
/// The default burst is the full ``permits``, which is the behaviour people
/// expect from "100 a minute": spend all hundred at once, then they refill
/// smoothly at one per 600ms rather than all at once on a clock boundary.
public struct RateLimitQuota: Sendable, Equatable {
    /// The sustained allowance over ``period``.
    public let permits: Int

    /// The window ``permits`` is expressed over. Not a window the limiter
    /// actually tracks: GCRA holds one timestamp and refills continuously,
    /// so there is no boundary for traffic to bunch up against.
    public let period: Duration

    /// The largest number of permits that may be spent at once, and
    /// therefore **the largest `cost` that can ever be admitted**. A call
    /// costing more than this is refused permanently rather than deferred,
    /// and ``RateLimitDecision/isUnsatisfiable`` says so.
    public let burst: Int

    /// - Parameters:
    ///   - permits: The sustained allowance. Must be positive.
    ///   - period: What the allowance is measured over. Must be positive.
    ///   - burst: How many permits may be spent at once. Defaults to
    ///     `permits`. Must be positive.
    public init(permits: Int, per period: Duration, burst: Int? = nil) {
        // Preconditions rather than throws: a quota is written as a literal
        // at the call site, the way a `Cookie` name is, so a bad one is a
        // programming error worth finding rather than a runtime condition to
        // handle. A quota read from configuration is validated where it is
        // read, before it reaches here.
        precondition(permits > 0, "A rate limit quota needs at least one permit; got \(permits).")
        precondition(period > .zero, "A rate limit quota needs a positive period; got \(period).")
        let burst = burst ?? permits
        precondition(burst > 0, "A rate limit quota needs a positive burst; got \(burst).")
        self.permits = permits
        self.period = period
        self.burst = burst
    }

    public static func perSecond(_ permits: Int, burst: Int? = nil) -> RateLimitQuota {
        RateLimitQuota(permits: permits, per: .seconds(1), burst: burst)
    }

    public static func perMinute(_ permits: Int, burst: Int? = nil) -> RateLimitQuota {
        RateLimitQuota(permits: permits, per: .seconds(60), burst: burst)
    }

    public static func perHour(_ permits: Int, burst: Int? = nil) -> RateLimitQuota {
        RateLimitQuota(permits: permits, per: .seconds(60 * 60), burst: burst)
    }

    public static func perDay(_ permits: Int, burst: Int? = nil) -> RateLimitQuota {
        RateLimitQuota(permits: permits, per: .seconds(24 * 60 * 60), burst: burst)
    }

    /// The gap between permits, in **whole microseconds**: GCRA's emission
    /// interval.
    ///
    /// Public because implementing ``RateLimitStore`` requires it. A store
    /// keeping its state somewhere this package cannot reach — a Lua script
    /// on a Valkey server, a row in Postgres — needs the algorithm's two
    /// parameters to run the same arithmetic the in-memory store does.
    ///
    /// Integer microseconds rather than fractional seconds, and that is not
    /// a detail. The algorithm subtracts two timestamps and divides the
    /// result by this, and a store keyed on Unix time is subtracting numbers
    /// near 1.8e15: in a `Double` those carry about half a microsecond of
    /// error, which is enough to report one permit fewer than are actually
    /// free. Microseconds since the epoch fit exactly in a `Double`'s 53-bit
    /// integer range until the year 2255, and exactly in an `Int64` for far
    /// longer, so every implementation can do this arithmetic exactly and
    /// none of them needs a fudge factor.
    ///
    /// At least 1: a rate finer than one permit per microsecond is beyond
    /// anything this is for, and a zero interval would divide by zero.
    public var emissionIntervalMicroseconds: Int64 {
        max(1, (period.rateLimitMicroseconds + Int64(permits) / 2) / Int64(permits))
    }

    /// How far ahead of the sustained rate a key may run, in microseconds.
    /// GCRA's delay variation tolerance, and the other half of what a store
    /// needs.
    public var burstOffsetMicroseconds: Int64 {
        emissionIntervalMicroseconds * Int64(burst)
    }
}

extension RateLimitQuota: CustomStringConvertible {
    public var description: String {
        "\(permits) per \(period)\(burst == permits ? "" : ", burst \(burst)")"
    }
}

extension Duration {
    /// Whole microseconds, the unit the algorithm works in.
    var rateLimitMicroseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000_000 + Int64(parts.attoseconds / 1_000_000_000_000)
    }

    /// The inverse, for building a `Duration` back out of the math.
    static func rateLimitMicroseconds(_ value: Int64) -> Duration {
        .microseconds(value)
    }
}
