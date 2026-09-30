# ALU-WEB-2002: A route handler parameter Alula cannot bind

**Severity:** error

## Meaning

A route handler has a parameter Alula has no way to fill. Alula binds:

- `_ context: RequestContext`, first when the handler declares it (optional,
  except on a `@WebSocketRoute`);
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
- The context declared somewhere other than first, or with a label.
- A `@WebSocketRoute` handler without the context.
- A path segment named `:body` or `:query`, which collides with those labels.

## Fixes

1. Label the body `body:`.
2. Name the parameter after its segment, or rename the segment.
3. Load domain objects from the id yourself: take `id: UUID`, not `user: User`.
4. Read a colliding segment explicitly: `context.pathParam("body", as: String.self)`.

## Example

```swift
@GetRoute("/users/:id")
func show(id: UUID) async throws -> User

@GetRoute("/users/:id/avatar")
func avatar(_ context: RequestContext, id: UUID) async throws -> Response
```

## Related

ALU-WEB-2006.
