# ALU-WEB-2009: A route runs through a lane nothing declares

**Severity:** warning

## Meaning

A route's (or its controller's) `pipelines:` names a lane — `"audit"` — that
no module declares with `MiddlewareRegistration.lane(_:_:)`.

## Why Alula rejects it

Dispatch is built from the declared lanes, and building it fails on a route
that names one it cannot find — at startup. It is a warning rather than an
error because a lane can be declared by a module the build tool cannot see,
such as one registered from a computed value.

## Common causes

- A typo in the lane name.
- The module that declares the lane is not in `modules:`.

## Fixes

1. Declare the lane in a module: `MiddlewareRegistration.lane("audit", [AuditMiddleware.self])`. An empty list is legal.
2. Correct the name, or remove the lane from the route's pipelines.

## Example

```swift
@Controller("/admin", pipelines: [.authenticated, "audit"])
```

## Related

ALU-WEB-2008.
