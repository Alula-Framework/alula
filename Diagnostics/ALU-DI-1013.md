# ALU-DI-1013: The removed `scope:` argument

**Severity:** error

## Meaning

A component declares `scope:` — `@Component(scope: .transient)` or similar.
The argument was removed in 0.20.0.

## Why Alula rejects it

Singleton is the only lifetime. Nothing needed the others, and removing them
removed the captive-dependency class of bug with them — an application-lived
component can no longer hold a request-lived value. Per-request state
travels on `RequestContext` (the authenticated principal is the worked
example), and a pooled connection is leased per operation by the repository
that holds the pool.

## Fixes

Delete the argument: `@Component`.
