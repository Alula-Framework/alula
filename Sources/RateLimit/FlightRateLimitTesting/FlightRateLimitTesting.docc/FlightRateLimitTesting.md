# ``FlightRateLimitTesting``

A rate limit store that remembers what it was asked, on a clock the test
moves.

## Overview

``RecordingRateLimitStore`` runs the real GCRA math over a fake clock, so a
suite asserts both what was limited and what the limiter concluded, without
sleeping:

```swift
let limits = RecordingRateLimitStore()
let client = try TestClient(
    routes: SearchController.flightRoutes { _ in SearchController() },
    middleware: MiddlewareRegistration.lane(.default, [
        RateLimiting(store: limits, quota: .perMinute(2)) { $0.request.path }
    ]))

_ = await client.get("/search")
_ = await client.get("/search")
#expect(await client.get("/search").status == .tooManyRequests)

limits.advance(by: .seconds(60))
#expect(await client.get("/search").status == .ok)
```

A real store with only time faked, rather than a stub: a stub agrees with
the production limiter until the day it does not. `misbehave()` makes every
call throw, which is the outage the middleware's fail-open policy exists
for, and `recover()` puts it back.

## Topics

- ``RecordingRateLimitStore``
