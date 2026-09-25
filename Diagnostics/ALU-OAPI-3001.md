# ALU-OAPI-3001: A type the API uses has no schema

**Severity:** warning

## Meaning

The application serves an OpenAPI document (it includes `AlulaOpenAPIModule`),
and a route takes or returns a type — directly or through a property — that the
build cannot derive a schema for: one declared outside the targets it scans,
typically in another package, or one whose shape Alula does not describe, such
as an enum with associated values or a generic type.

## Why Alula rejects it

The document's schemas are derived from source the build reads. For a type
it cannot read, the document names it and describes nothing, so a client
generated from it gets an empty type. It is a warning because the application
works; the document is what is incomplete.

## Common causes

- A property whose type comes from another package: `let total: Money`.
- An enum with associated values, or a generic wrapper such as `Page<Order>`.

## Fixes

1. Declare a wire type in the application that mirrors what is sent, and use it in the route's types.
2. If the type is yours, move it into a target in this package.

## Example

```swift
struct MoneyDTO: Codable { let amount: Decimal; let currency: String }
struct Order: Codable { let id: UUID; let total: MoneyDTO }
```

## Related

ALU-OAPI-3002.
