# Flight Rate Limiting

A limiter for anything an application can name: requests per caller, login
attempts per account, pushes per device. One algorithm, one store seam, and
a middleware for the HTTP case.

It is deliberately not only an HTTP feature. `FlightRateLimit` depends on
`FlightCore` and nothing else, the way `FlightSessions` does, so a security
module throttling sign-ins and a worker pacing an outbound API use the same
limiter as the web layer without any of them needing an HTTP server.

## Adding this module

| | |
|---|---|
| **Trait** | none for `FlightRateLimit`; `Web` for the `RateLimiting` middleware |
| **Products** | `FlightRateLimit`; `FlightRateLimitTesting` for tests |
| **Module** | `FlightRateLimitModule.self` |
| **Optional** | `FlightRateLimitValkeyModule.self` from flight-data, for more than one replica |

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/Flight-Framework/flight.git",
        from: "0.35.0", traits: ["Web"]),
],
```

```swift
await Flight.run(
    configuration: try Configuration.load(),
    modules: [
        FlightWebModule<FlightTransport>.self,
        FlightRateLimitModule.self,
        AppModule.self,
    ],
    composedBy: flightComposeModules)
```

The module provides a `RateLimiter`. Inject it anywhere, or hand its `store`
to the middleware.

## Limiting HTTP requests

```swift
let middleware = MiddlewareRegistration.lane(.default, [
    RateLimiting(store: limiter.store, quota: .perMinute(120)) { context in
        context.principal?.subject ?? "anonymous"
    }
])
```

**The key closure is required, and that is the one decision to understand
before using this.** There is no safe universal key. By authenticated
subject is right for an API and useless before sign-in. By address is right
for anonymous traffic and wrong behind a proxy nobody has accounted for. By
path limits every caller together. A limiter that chooses for you is one
whose key you discover during an incident, so this one makes you say it,
the same way `AllowedOrigins.any` with credentials is refused at
construction rather than at three in the morning.

If the key reads identity, list `RateLimiting` **after** `Authentication` in
the lane. Nothing enforces that, because the closure is opaque and the
middleware cannot see which fields it touches.

Responses carry `X-RateLimit-Limit`, `X-RateLimit-Remaining` and
`X-RateLimit-Reset` so a client can pace itself rather than discovering the
limit by hitting it. A refusal is a `429` rendered through the application's
own error format, with `Retry-After` in whole seconds, rounded up.

### Cost and tiers

Both the cost of a request and the quota it is held to are closures, because
both genuinely vary:

```swift
RateLimiting(
    store: limiter.store,
    quota: { $0.principal?.hasRole("pro") == true ? .perMinute(600) : .perMinute(60) },
    cost: { $0.request.path.hasPrefix("/search") ? 10 : 1 },
    key: { $0.principal?.subject ?? "anonymous" })
```

A cost larger than the quota's burst can never be admitted. That is refused
immediately with no `Retry-After`, because no wait would help, and logged as
the configuration error it is. `RateLimitDecision.isUnsatisfiable` is the
programmatic form.

## Limiting anything else

The same store, without HTTP anywhere near it:

```swift
@Service
struct SignIn {
    @Inject var limits: RateLimiter

    func attempt(_ email: String, _ password: String) async throws -> Principal {
        let decision = try await limits.consume(
            "login:\(email.lowercased())", quota: .perMinute(5))
        guard decision.isAllowed else {
            throw SignInError.tooManyAttempts(retryAfter: decision.retryAfter)
        }
        return try await credentials.verify(email, password)
    }
}
```

Spend the permit **before** the expensive work, not after. The point of
throttling a password check is to avoid performing it.

A `cost` of zero asks without spending, which is how a caller checks whether
it is worth starting something it will charge for later.

## Quotas

```swift
.perSecond(10)              // ten a second, all ten may arrive at once
.perMinute(100, burst: 10)  // a hundred a minute, at most ten at once
.perHour(1_000)
.perDay(10_000)
```

Two numbers, because they answer different questions. The rate is what an
operator budgets. The burst is how far ahead of that rate a caller may run,
which decides whether a page issuing twelve requests on load works or fails.
The default burst is the full quota, which is what "a hundred a minute"
usually means to the person saying it.

Quotas are passed per call rather than configured globally, because one
application limits logins, uploads and reads at completely different rates
out of one store. Nothing in `rate-limit.*` sets a quota.

## Why GCRA

A fixed window counts calls per clock interval and resets on the boundary,
which admits **twice the quota** across one: a hundred calls in the last
instant of a minute and a hundred in the first instant of the next is two
hundred inside two seconds, from a limiter configured for a hundred a
minute. A sliding-window log fixes that by keeping a timestamp per call,
which is unbounded memory per key and an O(n) prune on every call.

GCRA gets the smoothness of a sliding window from a single timestamp per
key: the instant at which that key would next be exactly on its budgeted
rate. That is also what makes the distributed store simple. The whole
decision is a read, a comparison and a write of one value, which a Valkey
`EVAL` performs in one round trip with no lock and no read-modify-write
race.

Two consequences worth knowing. Permits refill continuously rather than in
steps, so half a period buys back half the quota. And a refused call spends
nothing, so a client in a retry loop does not push its own recovery further
away.

## Stores

`RateLimitStore` has one method, `consume(key:cost:quota:)`, and the single
method is the design. Splitting "may this proceed" from "record that it did"
is the race every limiter gets wrong once: two callers read the same
under-quota state before either writes, and both are admitted. There is no
correct concurrent use of a split API, so the seam does not offer one.

| Store | Where | For |
|---|---|---|
| `InMemoryRateLimitStore` | `FlightRateLimit`, the default | One replica, development, tests. Bounded |
| `ValkeyRateLimitStore` | `FlightRateLimitValkey` in flight-data | More than one replica |
| `RecordingRateLimitStore` | `FlightRateLimitTesting` | Asserting what was limited |

**The in-memory store is per process.** Two replicas behind a load balancer
each enforce the quota separately, so a client spreading calls across them
gets the quota times the replica count. Configuring `rate-limit.valkey.url`
without listing its module is refused at composition for that reason.

Its bound matters more than the cache's or the session store's, because the
key space is chosen by whoever is being limited: limiting by login
identifier means an attacker decides how many distinct keys exist. Eviction
drops the keys closest to expiry, which restores their allowance. That is
the honest direction for a bound to fail in. Dropping limiter state can only
ever be too permissive, never wrongly punitive.

## When the store is unwell

`RateLimiting` **fails open** by default and logs a warning on every request
while it does.

This is the opposite of what `Sessions` does, and deliberately. A session
store that fails silently signs users out, and there is nothing behind it to
fall back to. A limiter that fails closed takes the whole service down when
it is the limiter that is unwell, which inverts its own job: it exists to
keep the service up. The warning is per request rather than once, because a
limiter that is silently not enforcing is exactly the failure nobody notices,
and one line at startup would not say it is still happening an hour later.

Where being unlimited is worse than being down, say so per lane:

```swift
RateLimiting(store: store, quota: .perMinute(5), onStoreFailure: .deny) { … }
```

## Configuration reference

| key | default | meaning |
|---|---|---|
| `rate-limit.memory.max-entries` | `100000` | The in-memory store's bound |

Quotas are not here; see *Quotas* above. The Valkey adapter's own keys are
in flight-data's guide.

## Testing

`RecordingRateLimitStore` runs the real algorithm over a clock the test
moves, so replenishment is tested without sleeping:

```swift
let limits = RecordingRateLimitStore()
_ = await client.get("/search")
_ = await client.get("/search")
#expect(await client.get("/search").status == .tooManyRequests)

limits.advance(by: .seconds(60))
#expect(await client.get("/search").status == .ok)
#expect(limits.denied.count == 1)
```

A real store with only time faked, rather than a stub that agrees with the
production limiter until the day it does not. `misbehave()` throws on every
call, which is the outage the fail-open policy exists for.

## Limiting by client address

`RequestContext.clientAddress` is the real client's address, accounting for
a reverse proxy when one is configured — see
[client-address.md](client-address.md) for the whole story, including why
trusting it needs a policy at all:

```swift
RateLimiting(store: limiter.store, quota: .perMinute(60)) { context in
    context.clientAddress?.host ?? "unknown"
}
```

`clientAddress` is `nil` when it cannot be determined — no real socket
behind the request, or a forwarded chain that never resolves to a confident
answer — so a key closure keying on it needs a fallback, the same way one
keying on `context.principal` needs one for anonymous traffic.

## Deliberately not here

- **Distributed coordination beyond one key.** Each key is independent. A
  global "requests per second across the whole service" budget is a
  different problem.
- **Queueing or delaying.** A refused call is refused. Nothing here holds a
  request until a permit frees up, which would turn a limiter into a source
  of latency and a place to exhaust memory.
