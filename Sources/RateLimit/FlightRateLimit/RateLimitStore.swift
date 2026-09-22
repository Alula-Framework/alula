/// Where rate limit state is kept. One method, and it is one method on
/// purpose.
///
/// **Deciding and recording are the same call.** Splitting them into "may
/// this proceed" and "record that it did" is the race every rate limiter
/// gets wrong once: two calls read the same under-quota state before either
/// writes, and both are admitted. There is no correct way to use a split
/// API concurrently, so this seam does not offer one. It costs a store
/// nothing, because the atomic form is also the cheaper one: a Valkey store
/// does it in a single `EVAL` rather than a `WATCH`/`MULTI` retry loop.
///
/// **Every method throws.** A store that cannot answer says so, and the
/// caller decides what that means: the `RateLimiting` middleware fails open
/// by default and says loudly that it did, because a limiter outage should
/// not become a service outage, while a caller guarding something expensive
/// may choose to refuse instead. That policy does not belong here — a store
/// reports facts.
///
/// ``InMemoryRateLimitStore`` ships here and is the default.
/// `FlightRateLimitValkey` in flight-data implements this across replicas,
/// and `FlightRateLimitTesting`'s `RecordingRateLimitStore` is the one for
/// tests.
public protocol RateLimitStore: Sendable {
    /// Spends `cost` permits against `key`, and says whether they were
    /// available.
    ///
    /// A denial spends nothing: the key is left exactly as it was, so a
    /// client retrying in a loop does not push its own recovery further
    /// away.
    ///
    /// - Parameters:
    ///   - key: What is being limited. The caller's vocabulary entirely:
    ///     a user id, an API key, a login identifier, an address. A store
    ///     treats it as opaque.
    ///   - cost: Permits to spend. `0` reports the current state without
    ///     spending, which is how a caller checks before doing expensive
    ///     work it is about to charge for.
    ///   - quota: The allowance this key is held to. Passed per call rather
    ///     than configured into the store, because one store serves every
    ///     limit in an application: logins, uploads and reads do not share a
    ///     budget.
    func consume(key: String, cost: Int, quota: RateLimitQuota) async throws -> RateLimitDecision
}

extension RateLimitStore {
    /// The common case: one permit.
    public func consume(key: String, quota: RateLimitQuota) async throws -> RateLimitDecision {
        try await consume(key: key, cost: 1, quota: quota)
    }
}

/// A store's own failure, with detail for the internal log. The wire never
/// sees it.
public struct RateLimitStoreError: Error, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { "rate limit store failed: \(reason)" }
}
