# ``FlightTelemetryTesting``

Captures the events a piece of code emits, and only that code's, even with
every other test in the process emitting the same events at once.

## Overview

```swift
@Test func signInCountsFailures() async throws {
    let attempts = await TelemetryTest.capture(SignInEvents.Attempt.self) {
        _ = try? await authenticator.authenticate(identifier: "ada", password: "wrong", clientAddress: nil)
    }
    #expect(attempts.map(\.metadata.outcome) == ["invalid_credentials"])
}
```

A capture binds a scope in a task-local for the length of its body. One
shared handler per event type records an emit only for the scopes current
where it happens. Child tasks inherit the scope, so their events are
captured, and parallel tests have different scopes, so theirs aren't.
Production code pays nothing for any of this: the task-local is read only
by handlers that exist only during a capture.

Not captured: work that leaves structured concurrency, such as
`Task.detached` or a thread Swift concurrency doesn't manage.

## Topics

- ``TelemetryTest``
- ``CapturedEvent``
- ``CapturedAnyEvent``
- ``CapturedSpans``
- ``UnexpectedEmission``
