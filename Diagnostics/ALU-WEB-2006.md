# ALU-WEB-2006: A route handler declared in a way Alula cannot call

**Severity:** error

## Meaning

A route handler is `static`, `mutating`, or is a WebSocket upgrade that
does not return a `WebSocketUpgradeHandler`.

## Why Alula rejects it

The generated route builds a controller for each request and calls the
handler on that instance. A static method has no instance; a mutating one
would change a controller discarded right after; an upgrade route needs a
handler to hand the connection to.

## Fixes

1. Make the handler an instance method.
2. Drop `mutating`, and keep state in an injected component or on the `RequestContext`.
3. Return a `WebSocketUpgradeHandler` from an upgrade route.

## Example

```swift
@GetRoute("/stats")
func stats(_ context: RequestContext) async throws -> Stats
```

## Related

ALU-WEB-2002.
