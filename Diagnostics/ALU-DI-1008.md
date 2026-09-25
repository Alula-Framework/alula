# ALU-DI-1008: @Inject of an optional type

**Severity:** error

## Meaning

A component declares `@Inject var x: T?`.

## Why Alula rejects it

Injection resolves a provider for the type written. `T?` is
`Optional<T>`, which nothing provides, so it would always be `nil` — a
dependency that silently never arrives.

## Fixes

1. Drop the `?` if the dependency is required.
2. If absence is meaningful, have a module provide an optional value and
   pass it explicitly, or resolve it by hand.

## Related

ALU-DI-1001.
