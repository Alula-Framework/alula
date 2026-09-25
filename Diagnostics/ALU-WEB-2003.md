# ALU-WEB-2003: @Controller or @Middleware on something other than a struct or final class

**Severity:** error

## Meaning

`@Controller` or `@Middleware` is attached to a non-final class, an enum,
an actor, a protocol or an extension.

## Why Alula rejects it

The macro generates an initializer and a route (or middleware) factory for
the type. A subclass could override the handlers the route table points at,
and the other declarations have no initializer to generate.

## Common causes

- A class written without `final`.

## Fixes

1. Mark the class `final` (the build offers this as a fix-it).
2. Make it a struct — the usual choice for a controller, which is built per request.

## Example

```swift
@Controller("/users")
struct UsersController { … }
```

## Related

ALU-DI-1018.
