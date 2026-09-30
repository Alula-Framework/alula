/// What a module injects to limit something: the store, plus the one call
/// worth making against it.
///
/// Typed distinctly from `any RateLimitStore` on purpose. An adapter module
/// *provides* a store and the base module *takes* one, so if the base module
/// also provided that type the composer would see two providers of one type
/// and stop. `AlulaCacheModule` provides a `CacheRuntime` rather than the
/// `Cache` it wraps for exactly this reason, and `AlulaSessionsModule` a
/// `SessionRuntime`.
///
/// It is also the nicer thing to hold. A consumer wants to say what it is
/// limiting and how much, not reach through to a store:
///
/// ```swift
/// @Service
/// struct SignIn {
///     @Inject var limits: RateLimiter
///
///     func attempt(_ email: String, _ password: String) async throws -> Principal {
///         let decision = try await limits.consume(
///             "login:\(email.lowercased())", quota: .perMinute(5, burst: 5))
///         guard decision.isAllowed else { throw SignInError.tooManyAttempts(decision.retryAfter) }
///         …
///     }
/// }
/// ```
public struct RateLimiter: Sendable {
    /// The store behind it, for a caller that needs the seam directly.
    public let store: any RateLimitStore

    /// A limiter over `store`. ``AlulaRateLimitModule`` builds the
    /// application's.
    public init(store: any RateLimitStore) {
        self.store = store
    }

    /// Spends `cost` permits against `key`. See
    /// ``RateLimitStore/consume(key:cost:quota:)``.
    ///
    /// Throws whatever the store throws — a negative `cost`, or a store
    /// that cannot answer — and applies no fail-open policy of its own:
    /// that is the `RateLimiting` middleware's choice, not this call's. A
    /// caller that lets the error propagate is therefore failing closed; one
    /// that wants to fail open catches it.
    @discardableResult
    public func consume(
        _ key: String, cost: Int = 1, quota: RateLimitQuota
    ) async throws -> RateLimitDecision {
        try await store.consume(key: key, cost: cost, quota: quota)
    }
}
