import FlightCore

/// The `rate-limit.*` configuration vocabulary (env-var form
/// `FLIGHT_RATE_LIMIT_*`).
///
/// Deliberately short: quotas are **not** here. One application limits
/// logins, uploads and reads at wildly different rates, so a quota belongs
/// at the call site that knows what it is protecting, the way
/// `@Cacheable(ttl:)` carries its own TTL. What is global is which store
/// holds the state.
public enum RateLimitConfigKey {
    public static let root = "rate-limit"
    /// `rate-limit.memory.max-entries` — the in-memory store's bound.
    public static let memoryMaxEntries = "rate-limit.memory.max-entries"
}

/// Rate limit wiring, composed by argument:
///
/// ```swift
/// await Flight.run(configuration: try .load(), modules: [
///     FlightWebModule<FlightTransport>.self,
///     FlightRateLimitModule.self,
///     FlightRateLimitValkeyModule.self,   // flight-data; omit for one replica
///     AppModule.self,
/// ], composedBy: flightComposeModules)
/// ```
///
/// Provides a ``RateLimiter`` over the store an adapter module supplied,
/// or over a bounded in-memory one when none was. Absent adapter means one
/// replica; configuring an adapter's URL without listing its module is
/// refused at composition, because a per-replica limiter behind a load
/// balancer enforces the quota once per replica and nothing says so.
///
/// No `service`: the in-memory store has no long-running work, and an
/// adapter with a connection exposes its own.
///
/// **Not gated on `Web`.** A limiter is not an HTTP concern. The
/// `RateLimiting` middleware in `FlightWeb` is one consumer; a login
/// throttle in a security module and a send throttle in a worker are
/// others, and none of them should need an HTTP server to exist.
public struct FlightRateLimitModule: FlightModule {
    /// The one value this module provides.
    public let limiter: RateLimiter

    /// - Parameters:
    ///   - configuration: `rate-limit.*` is read from here.
    ///   - store: A shared store from an adapter module. Nil means the
    ///     in-memory store — one replica, and the default.
    public init(configuration: Configuration, store: (any RateLimitStore)? = nil) throws {
        if store == nil {
            try configuration.requireNoUnloadedAdapter(
                feature: "rate limiting",
                candidates: [
                    AdapterCandidate(
                        configurationKey: ValkeyRateLimitConfigKeyProbe.url,
                        module: "FlightRateLimitValkeyModule")
                ])
        }
        let maxEntries =
            try configuration.getIfPresent(RateLimitConfigKey.memoryMaxEntries, as: Int.self)
            ?? InMemoryRateLimitStore.defaultMaxEntries
        guard maxEntries > 0 else {
            throw RateLimitConfigurationError.invalidMaxEntries(maxEntries)
        }
        self.limiter = RateLimiter(store: store ?? InMemoryRateLimitStore(maxEntries: maxEntries))
    }

    public init() {
        preconditionFailure(
            "FlightRateLimitModule takes its configuration in init(configuration:store:), so it "
                + "cannot be instantiated from its type. Pass `composedBy: flightComposeModules` "
                + "to Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }
}

/// A `rate-limit.*` value that cannot be used. Thrown at composition.
public enum RateLimitConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidMaxEntries(Int)

    public var description: String {
        switch self {
        case .invalidMaxEntries(let value):
            return """
                \(RateLimitConfigKey.memoryMaxEntries) must be positive; it is \(value). The \
                in-memory store is bounded by design.
                """
        }
    }
}

/// The adapter's required key, spelled here so this module can notice a
/// configuration block its own build may not contain code for.
///
/// FlightRateLimit cannot import FlightRateLimitValkey — it lives in
/// flight-data, and the dependency runs the other way. A string constant is
/// the whole coupling, and the adapter's own suite pins its key equal to
/// this one so the two cannot drift.
enum ValkeyRateLimitConfigKeyProbe {
    static let url = "rate-limit.valkey.url"
}
