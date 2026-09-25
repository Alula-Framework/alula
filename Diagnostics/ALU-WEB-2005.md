# ALU-WEB-2005: A route path that is not a string literal

**Severity:** error

## Meaning

A `@Controller` or route attribute's path is a variable, an expression, or
an interpolated string.

## Why Alula rejects it

The route table is built at compile time, from the source. A path known
only at runtime cannot be checked for conflicts, cannot appear in
`alula routes` or the OpenAPI document, and cannot be validated.

## Fixes

1. Write the path as a plain string literal.
2. For a route that really is only known at runtime, declare a `RouteRegistration` value from a module.

## Example

```swift
@GetRoute("/health")           // not @GetRoute(healthPath)
```

## Related

ALU-WEB-2004.
