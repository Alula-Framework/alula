# ALU-SEC-6001: A route requires roles but authenticates no one

**Severity:** error

## Meaning

A route requires roles but runs on the `.public` lane, which establishes no
principal.

## Why Alula rejects it

A role check needs someone to check. On a public lane every request is
anonymous, so every request would be rejected — the route could never
succeed.

## Common causes

- A route marked `pipelines: [.public]` that kept its `roles:`.

## Fixes

1. Put the route on a lane that authenticates.
2. Drop the roles if the route is meant to be public.

## Example

```swift
@GetRoute("/invoices", pipelines: [.authenticated], roles: [AppRole.billing])
```

## Related

ALU-WEB-2008.
