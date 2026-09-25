# ALU-WEB-2002: A route handler parameter Alula cannot bind

**Severity:** error

## Meaning

A route handler has a parameter Alula has no way to fill. Alula binds:

- `_ context: RequestContext`, always the first parameter;
- a path parameter, labelled after its `:segment`;
- `body:`, decoded from the request body (once);
- `query:`, decoded from the query string (once).

## Why Alula rejects it

The generated route calls your handler with values it read from the
request. A parameter matching none of those sources would have nothing to
be called with.

## Common causes

- An unlabelled parameter meant as the body.
- A path parameter label that does not match its segment (`id:` for `:userID`).
- A `body:` on a WebSocket upgrade — an upgrade request has no body.
- A path segment named `:body` or `:query`, which collides with those labels.

## Fixes

1. Label the body `body:`.
2. Name the parameter after its segment, or rename the segment.
3. Load domain objects from the id yourself: take `id: UUID`, not `user: User`.
4. Read a colliding segment explicitly: `context.pathParam("body", as: String.self)`.

## Example

```swift
@GetRoute("/users/:id")
func show(_ context: RequestContext, id: UUID) async throws -> User
```

## Related

ALU-WEB-2006.
