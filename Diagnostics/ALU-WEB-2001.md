# ALU-WEB-2001: Two handlers for one method and path

**Severity:** error

## Meaning

Two route handlers answer the same HTTP method and path.

## Why Alula rejects it

A router can dispatch a request to only one handler. Keeping whichever was
registered last would make routing depend on declaration order, and the
other handler would be dead code no one is told about.

## Common causes

- A handler copied to start a new one, with the path left unchanged.

## Fixes

1. Change one handler's method or path.
2. Delete the handler you no longer need.

## Example

```swift
@GetRoute("/users/:id") func show(_ context: RequestContext, id: UUID) …
@GetRoute("/users/:id") func detail(_ context: RequestContext, id: UUID) … // ALU-WEB-2001
```

## Related

ALU-WEB-2004.
