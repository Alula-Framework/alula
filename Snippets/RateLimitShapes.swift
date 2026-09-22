// Every shape Docs/rate-limiting.md claims, compiled.
//
// A doc example that does not compile costs a reader the time to find out.
// This builds as part of `swift build`, so a rename that invalidates the
// prose breaks the build.

import FlightCore
import FlightRateLimit
import FlightRateLimitTesting
import FlightSecurityCore
import FlightWeb

// snippet.hide
enum SignInError: Error { case tooManyAttempts(retryAfter: Duration?) }
struct Credentials: Sendable {
    func verify(_ email: String, _ password: String) async throws -> String { email }
}
// snippet.show

@Service
struct SignIn {
    @Inject var limits: RateLimiter
    let credentials = Credentials()

    func attempt(_ email: String, _ password: String) async throws -> String {
        // Spend the permit before the expensive work: the point of
        // throttling a password check is to avoid performing it.
        let decision = try await limits.consume(
            "login:\(email.lowercased())", quota: .perMinute(5))
        guard decision.isAllowed else {
            throw SignInError.tooManyAttempts(retryAfter: decision.retryAfter)
        }
        return try await credentials.verify(email, password)
    }
}

func rateLimitShapes(configuration: Configuration) throws {
    // The module, built the way the composition root builds it.
    let module = try FlightRateLimitModule(configuration: configuration)
    let limiter = module.limiter

    // The HTTP middleware: a fixed quota, keyed on the caller.
    _ = MiddlewareRegistration.lane(
        .default,
        [
            RateLimiting(store: limiter.store, quota: .perMinute(120)) { context in
                context.principal?.subject ?? "anonymous"
            }
        ])

    // Tiers and per-route cost, both as closures.
    _ = RateLimiting(
        store: limiter.store,
        quota: { $0.principal?.hasRole("pro") == true ? .perMinute(600) : .perMinute(60) },
        cost: { $0.request.path.hasPrefix("/search") ? 10 : 1 },
        onStoreFailure: .deny,
        key: { $0.principal?.subject ?? "anonymous" })

    // Quotas.
    _ = RateLimitQuota.perSecond(10)
    _ = RateLimitQuota.perMinute(100, burst: 10)
    _ = RateLimitQuota.perHour(1_000)
    _ = RateLimitQuota.perDay(10_000)

    // A store of your own is the seam, provided from a module by type.
    struct MyLimitStoreModule: FlightModule {
        let store: any RateLimitStore = InMemoryRateLimitStore()
    }
    _ = MyLimitStoreModule()

    // Tests: the real algorithm, on a clock the test moves.
    let recording = RecordingRateLimitStore()
    recording.advance(by: .seconds(60))
    recording.misbehave()
    recording.recover()
    _ = recording.denied
    _ = recording.callCount(for: "login:ada@example.com")
}
