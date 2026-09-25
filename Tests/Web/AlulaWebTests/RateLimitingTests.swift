import AlulaCore
import AlulaRateLimit
import AlulaRateLimitTesting
import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Testing

@Controller("/")
private struct RateLimitedController {
    @GetRoute("/search")
    func search(_ context: RequestContext) -> String { "results" }

    @GetRoute("/health")
    func health(_ context: RequestContext) -> String { "ok" }
}

@Suite("RateLimiting middleware")
struct RateLimitingTests {
    private let store = RecordingRateLimitStore()

    private func client(
        quota: RateLimitQuota = .perMinute(2),
        cost: @escaping @Sendable (RequestContext) -> Int = { _ in 1 },
        onStoreFailure: RateLimitFailurePolicy = .allow,
        advertisesLimit: Bool = true,
        key: @escaping @Sendable (RequestContext) -> String = { _ in "everyone" }
    ) throws -> TestClient {
        let limiting = RateLimiting(
            store: store, quota: quota, cost: cost, onStoreFailure: onStoreFailure,
            advertisesLimit: advertisesLimit, key: key)
        return try TestClient(
            routes: RateLimitedController.alulaRoutes { _ in RateLimitedController() },
            middleware: MiddlewareRegistration.lane(.default, [limiting]))
    }

    // MARK: Allowing and refusing

    @Test("under the quota the request is served and told what is left")
    func allowsAndAdvertises() async throws {
        let response = await (try client()).get("/search")
        #expect(response.status == .ok)
        #expect(response.bodyText == "results")
        #expect(response.header("x-ratelimit-limit") == "2")
        #expect(response.header("x-ratelimit-remaining") == "1")
        #expect(response.header("x-ratelimit-reset") != nil)
        #expect(response.header("retry-after") == nil, "nothing to retry")
    }

    @Test("over the quota the request is refused with 429 and a Retry-After")
    func refuses() async throws {
        let client = try client()
        _ = await client.get("/search")
        _ = await client.get("/search")
        let denied = await client.get("/search")
        #expect(denied.status == .tooManyRequests)
        #expect(denied.header("x-ratelimit-remaining") == "0")
        let retryAfter = try #require(denied.header("retry-after"))
        #expect(Int(retryAfter) != nil, "whole seconds, as the header requires")
        #expect(Int(retryAfter)! >= 1, "rounded up: zero would invite an immediate second refusal")
    }

    @Test("the refusal body is the application's error shape, not a bespoke one")
    func refusalUsesTheAppsErrorRendering() async throws {
        let client = try client()
        _ = await client.get("/search")
        _ = await client.get("/search")
        let denied = await client.get("/search")
        // The default renderer is problem+json, the same one a 404 or a 500
        // from this application produces.
        #expect(denied.headers[.contentType]?.contains("problem+json") == true)
        #expect(denied.bodyText.contains("Too Many Requests"))
    }

    @Test("the quota replenishes on the clock")
    func replenishes() async throws {
        let client = try client()
        _ = await client.get("/search")
        _ = await client.get("/search")
        #expect(await client.get("/search").status == .tooManyRequests)

        store.advance(by: .seconds(30))
        #expect(await client.get("/search").status == .ok, "half a minute, half the quota back")
    }

    @Test("a refused request spends nothing, so retrying does not extend the wait")
    func denialDoesNotConsume() async throws {
        let client = try client()
        _ = await client.get("/search")
        _ = await client.get("/search")
        for _ in 0..<20 {
            #expect(await client.get("/search").status == .tooManyRequests)
        }
        // Thirty seconds buys exactly one permit back whether the client
        // waited quietly or hammered the door twenty times.
        store.advance(by: .seconds(30))
        #expect(await client.get("/search").status == .ok)
        #expect(await client.get("/search").status == .tooManyRequests)
    }

    // MARK: The key

    @Test("callers with different keys have separate budgets")
    func keysSeparateCallers() async throws {
        let client = try client(key: { $0.request.queryParam("who") ?? "anonymous" })
        for _ in 0..<2 { _ = await client.get("/search?who=ada") }
        #expect(await client.get("/search?who=ada").status == .tooManyRequests)
        #expect(await client.get("/search?who=grace").status == .ok, "grace has her own budget")
        #expect(store.callCount(for: "ada") == 3)
        #expect(store.callCount(for: "grace") == 1)
    }

    @Test("the key can be the route, limiting an endpoint rather than a caller")
    func keyByRoute() async throws {
        let client = try client(key: { $0.request.path })
        for _ in 0..<2 { _ = await client.get("/search") }
        #expect(await client.get("/search").status == .tooManyRequests)
        #expect(await client.get("/health").status == .ok, "a different endpoint, a different key")
    }

    // MARK: Cost and quota as closures

    @Test("cost is charged per request, so an expensive route drains faster")
    func costCharged() async throws {
        let client = try client(
            quota: .perMinute(10),
            cost: { $0.request.path == "/search" ? 5 : 1 })
        let first = await client.get("/search")
        #expect(first.status == .ok)
        #expect(first.header("x-ratelimit-remaining") == "5", "one search spent five of ten")

        #expect(await client.get("/search").status == .ok)
        #expect(await client.get("/search").status == .tooManyRequests, "ten spent")
        // They share a key here, so the cheap route is refused too: the
        // budget belongs to the key, not the route.
        #expect(await client.get("/health").status == .tooManyRequests)
    }

    @Test("a cheap route survives what an expensive one drains, given its own key")
    func costWithPerRouteKeys() async throws {
        let client = try client(
            quota: .perMinute(10),
            cost: { $0.request.path == "/search" ? 5 : 1 },
            key: { $0.request.path })
        for _ in 0..<2 { #expect(await client.get("/search").status == .ok) }
        #expect(await client.get("/search").status == .tooManyRequests)
        #expect(await client.get("/health").status == .ok, "its own key, its own budget")
    }

    @Test("the quota can vary per request, so tiers share a lane")
    func tieredQuota() async throws {
        let limiting = RateLimiting(
            store: store,
            quota: { $0.request.queryParam("tier") == "paid" ? .perMinute(50) : .perMinute(1) },
            key: { $0.request.queryParam("tier") ?? "free" })
        let client = try TestClient(
            routes: RateLimitedController.alulaRoutes { _ in RateLimitedController() },
            middleware: MiddlewareRegistration.lane(.default, [limiting]))

        #expect(await client.get("/search").status == .ok)
        #expect(await client.get("/search").status == .tooManyRequests, "free tier: one a minute")
        for _ in 0..<10 {
            #expect(await client.get("/search?tier=paid").status == .ok)
        }
    }

    /// A negative cost used to trap in the store and stop the server. Sent
    /// through as a store failure instead, it would have met the default
    /// `.allow` policy — a client able to make the cost negative would not
    /// be limited at all. It is charged as one permit.
    @Test("a negative cost is charged as one permit: no crash, and no way around the limit")
    func negativeCostIsChargedOne() async throws {
        let client = try client(cost: { _ in -5 })
        #expect(await client.get("/search").status == .ok)
        #expect(await client.get("/search").status == .ok)
        #expect(await client.get("/search").status == .tooManyRequests)
    }

    @Test("a cost over the burst is refused with no Retry-After, because none would help")
    func unsatisfiableCost() async throws {
        let client = try client(quota: .perMinute(5), cost: { _ in 99 })
        let denied = await client.get("/search")
        #expect(denied.status == .tooManyRequests)
        #expect(denied.header("retry-after") == nil)
    }

    // MARK: When the store is unwell

    @Test("an unreachable store serves the request by default")
    func failsOpen() async throws {
        let client = try client()
        store.misbehave()
        let response = await client.get("/search")
        #expect(response.status == .ok, "a limiter outage is not a service outage")
        #expect(
            response.header("x-ratelimit-limit") == nil,
            "nothing was measured, so nothing is claimed")
    }

    @Test("an unreachable store refuses when the lane asked it to")
    func failsClosedWhenAsked() async throws {
        let client = try client(onStoreFailure: .deny)
        store.misbehave()
        #expect(await client.get("/search").status == .serviceUnavailable)
    }

    @Test("enforcement resumes when the store recovers")
    func recovers() async throws {
        let client = try client()
        store.misbehave()
        _ = await client.get("/search")
        store.recover()
        _ = await client.get("/search")
        _ = await client.get("/search")
        #expect(await client.get("/search").status == .tooManyRequests)
    }

    // MARK: Advertising

    @Test("advertising can be turned off for success, never for a refusal")
    func advertisingOff() async throws {
        let client = try client(advertisesLimit: false)
        let allowed = await client.get("/search")
        #expect(allowed.status == .ok)
        #expect(allowed.header("x-ratelimit-limit") == nil)

        _ = await client.get("/search")
        let denied = await client.get("/search")
        #expect(denied.status == .tooManyRequests)
        #expect(
            denied.header("x-ratelimit-limit") == "2", "a refusal always says what the limit was")
    }

    @Test("the header names parse; the middleware force-unwraps them")
    func headerNamesAreValid() {
        // `HTTPField.Name` is failable and these are literals, so the
        // force-unwraps in `RateLimitHeader` are safe exactly as long as
        // this passes.
        #expect(HTTPField.Name("x-ratelimit-limit") != nil)
        #expect(HTTPField.Name("x-ratelimit-remaining") != nil)
        #expect(HTTPField.Name("x-ratelimit-reset") != nil)
    }
}
