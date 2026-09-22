# ``FlightRateLimit``

A rate limiter: the GCRA algorithm, a one-method store seam, and a bounded
in-memory default.

## Overview

``RateLimiter`` is what a consumer holds. Say what is being limited, and how
much of it is allowed:

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
        …
    }
}
```

The quota travels with the call rather than living in configuration,
because one application limits logins, uploads and reads at completely
different rates out of one store.

## This is not an HTTP concern

Nothing here imports `FlightWeb`. `RateLimiting` middleware is one consumer
of this seam, a login throttle is another, and a worker draining a queue is
a third. Putting the mechanism below all of them is what lets a headless
service limit something without an HTTP server, the same way `FlightSessions`
sits below both `FlightWeb` and `FlightSecurityCore`.

## One call, not two

``RateLimitStore`` has a single method, and that is the design. Splitting
"may this proceed" from "record that it did" is the race every limiter gets
wrong once: two callers read the same under-quota state before either
writes, and both are admitted. There is no correct concurrent use of a split
API, so the seam does not offer one.

## Topics

### Limiting something

- ``RateLimiter``
- ``RateLimitQuota``
- ``RateLimitDecision``

### The seam

- ``RateLimitStore``
- ``RateLimitStoreError``
- ``InMemoryRateLimitStore``

### Hosting

- ``FlightRateLimitModule``
- ``RateLimitConfigKey``
- ``RateLimitConfigurationError``
