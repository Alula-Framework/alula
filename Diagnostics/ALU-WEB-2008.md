# ALU-WEB-2008: A route's pipelines drop its controller's authentication

**Severity:** warning

## Meaning

A route's `pipelines:` argument leaves out a lane its controller uses to
authenticate, so the route runs without authentication.

## Why Alula rejects it

A route's `pipelines:` replaces the controller's rather than adding to it —
so a route that meant to add a lane can quietly lose authentication. It is
a warning because a public route inside an authenticated controller is
legitimate; the build asks you to say so.

## Common causes

- Adding a lane to one route, expecting the controller's lanes to remain.

## Fixes

1. List the controller's authenticating lane too.
2. If the route is meant to be public, write `pipelines: [.public]` — that records the decision and silences the warning.

## Example

```swift
@Controller("/account", pipelines: [.authenticated])
struct AccountController {
    @GetRoute("/export", pipelines: [.authenticated, "audited"]) …
    @GetRoute("/terms", pipelines: [.public]) …
}
```

## Related

ALU-SEC-6001.
