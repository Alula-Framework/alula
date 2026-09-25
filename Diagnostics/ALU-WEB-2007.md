# ALU-WEB-2007: A route attribute outside a @Controller

**Severity:** error

## Meaning

A route attribute such as `@GetRoute` is on something that is not a
method, or on a method whose type is not a `@Controller`.

## Why Alula rejects it

`@Controller` reads the route attributes of its methods; nothing else
does. A route anywhere else would silently never exist.

## Common causes

- `@Controller` forgotten on the type.
- The handler moved into an extension, which the controller does not scan.

## Fixes

1. Add `@Controller` to the type that declares the method.
2. Move the handler into the controller's main declaration.
3. Declare the route as a `RouteRegistration` value from a module.

## Example

```swift
@Controller("/users")
struct UsersController {
    @GetRoute("/") func list(_ context: RequestContext) async throws -> [User] { … }
}
```

## Related

ALU-WEB-2003.
