import AlulaRateLimit
import HTTPTypes

/// What to do when the rate limit store cannot answer.
public enum RateLimitFailurePolicy: Sendable, Equatable {
    /// Serve the request, and say loudly that the limiter is not enforcing.
    ///
    /// The default, because the alternative turns a limiter outage into a
    /// service outage. A limiter exists to keep a service up under abuse;
    /// one that takes the service down when *it* is unwell has inverted its
    /// own job. The window is bounded by whatever the store does about its
    /// own health — the Valkey store trips a breaker and fails in
    /// microseconds rather than hanging on every request.
    case allow

    /// Refuse the request with a 503.
    ///
    /// For the endpoint where being unlimited is worse than being down: a
    /// signup that costs money per call, a password check an attacker would
    /// happily grind. Deliberate, per lane, never the default.
    case deny
}

/// Limits requests, keyed by whatever the application says identifies a
/// caller.
///
/// ```swift
/// MiddlewareRegistration.lane(.default, [
///     RateLimiting(store: limiter.store, quota: .perMinute(120)) { context in
///         context.principal?.subject ?? "anonymous"
///     }
/// ])
/// ```
///
/// **The key closure is required and has no default**, which is the whole
/// design decision worth knowing about. There is no safe universal key. By
/// authenticated subject is right for an API and useless before sign-in; by
/// address is right for anonymous traffic and wrong behind a proxy that has
/// not been accounted for; by path limits everyone together. A limiter that
/// picks for you is one whose key you discover in an incident, so this one
/// makes you say it. The same reasoning refuses `AllowedOrigins.any` with
/// credentials at construction rather than at three in the morning.
///
/// **Order matters if the key reads identity.** A key closure using
/// `context.principal` must sit after `Authentication` in the lane, or it
/// will see `nil` on every request and limit every caller as one. Nothing
/// enforces that, because the closure is opaque: the middleware cannot tell
/// which context fields it touches.
///
/// **A denial costs nothing.** A refused request does not spend a permit, so
/// a client in a retry loop does not push its own recovery further away.
public struct RateLimiting: Middleware {
    private let store: any RateLimitStore
    private let quota: @Sendable (RequestContext) -> RateLimitQuota
    private let key: @Sendable (RequestContext) -> String
    private let cost: @Sendable (RequestContext) -> Int
    private let onStoreFailure: RateLimitFailurePolicy
    private let advertisesLimit: Bool

    /// - Parameters:
    ///   - store: Where the state lives. `AlulaRateLimitModule` provides a
    ///     `RateLimiter` whose `store` is this.
    ///   - quota: The allowance, computed per request, so a paid tier and a
    ///     free one can share a lane. See the non-closure overload for a
    ///     fixed quota.
    ///   - cost: What this request spends. Defaults to one. A search that
    ///     costs ten and a health check that costs one out of the same
    ///     budget is the reason this is a closure.
    ///   - onStoreFailure: What an unreachable store means.
    ///     ``RateLimitFailurePolicy/allow`` by default.
    ///   - advertisesLimit: Whether successful responses carry
    ///     `X-RateLimit-*`, so a client can pace itself rather than
    ///     discovering the limit by hitting it. Refusals always carry them.
    ///   - key: What identifies the caller. Required; see the type's note.
    public init(
        store: any RateLimitStore,
        quota: @escaping @Sendable (RequestContext) -> RateLimitQuota,
        cost: @escaping @Sendable (RequestContext) -> Int = { _ in 1 },
        onStoreFailure: RateLimitFailurePolicy = .allow,
        advertisesLimit: Bool = true,
        key: @escaping @Sendable (RequestContext) -> String
    ) {
        self.store = store
        self.quota = quota
        self.key = key
        self.cost = cost
        self.onStoreFailure = onStoreFailure
        self.advertisesLimit = advertisesLimit
    }

    /// The common case: one quota for everything in the lane.
    public init(
        store: any RateLimitStore,
        quota: RateLimitQuota,
        cost: @escaping @Sendable (RequestContext) -> Int = { _ in 1 },
        onStoreFailure: RateLimitFailurePolicy = .allow,
        advertisesLimit: Bool = true,
        key: @escaping @Sendable (RequestContext) -> String
    ) {
        self.init(
            store: store, quota: { _ in quota }, cost: cost, onStoreFailure: onStoreFailure,
            advertisesLimit: advertisesLimit, key: key)
    }

    public func handle(_ context: RequestContext, next: Next) async throws -> Response {
        let quota = quota(context)
        let decision: RateLimitDecision
        do {
            decision = try await store.consume(
                key: key(context), cost: cost(context), quota: quota)
        } catch {
            // Per request, at warning level, on purpose. A limiter that is
            // silently not enforcing is the failure nobody notices until the
            // bill arrives, and one line at startup would not say that it is
            // *still* happening an hour later.
            context.logger.warning(
                "rate limit store unavailable",
                metadata: [
                    "policy": "\(onStoreFailure == .allow ? "allowing" : "refusing")",
                    "reason": "\(error)",
                ])
            switch onStoreFailure {
            case .allow:
                return try await next(context)
            case .deny:
                return context.coders.renderError(.serviceUnavailable, "Service Unavailable")
            }
        }

        guard decision.isAllowed else {
            if decision.isUnsatisfiable {
                // No wait helps: the request costs more than the quota's
                // burst. That is the application's bug, not the client's, so
                // it is worth a line — and the answer carries no Retry-After,
                // because there is no time at which retrying would work.
                context.logger.error(
                    "rate limit cost exceeds the quota's burst; this request can never be admitted",
                    metadata: ["quota": "\(quota)"])
            }
            var response = context.coders.renderError(.tooManyRequests, "Too Many Requests")
            response = limitHeaders(on: response, decision: decision, quota: quota)
            if let retryAfter = decision.retryAfter {
                response = response.settingHeader(
                    .retryAfter, String(retryAfterSeconds(retryAfter)))
            }
            return response
        }

        let response = try await next(context)
        guard advertisesLimit else { return response }
        return limitHeaders(on: response, decision: decision, quota: quota)
    }

    private func limitHeaders(
        on response: Response, decision: RateLimitDecision, quota: RateLimitQuota
    ) -> Response {
        response
            .settingHeader(RateLimitHeader.limit, String(quota.permits))
            .settingHeader(RateLimitHeader.remaining, String(decision.remaining))
            .settingHeader(RateLimitHeader.reset, String(retryAfterSeconds(decision.resetAfter)))
    }

    /// `Retry-After` is whole seconds, and it rounds **up**: telling a client
    /// to come back in zero seconds when it has 400ms to wait produces a
    /// second refusal and a client that believes the header is lying.
    private func retryAfterSeconds(_ duration: Duration) -> Int {
        let components = duration.components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        return Int(components.seconds) + (components.attoseconds > 0 ? 1 : 0)
    }
}

/// The response headers a limiter sets. Names are the de-facto ones every
/// major API uses; the IETF draft's `RateLimit-*` spelling is not settled,
/// and shipping the unprefixed names before it is would be guessing.
enum RateLimitHeader {
    // Literals, checked by `RateLimitHeaderTests` so the force-unwraps
    // cannot become a crash on a typo nobody ran.
    static let limit = HTTPField.Name("x-ratelimit-limit")!
    static let remaining = HTTPField.Name("x-ratelimit-remaining")!
    static let reset = HTTPField.Name("x-ratelimit-reset")!
}
