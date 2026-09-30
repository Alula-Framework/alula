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
2. If absence is meaningful, let the module that knows decide: have it
   provide a non-optional value in every case (a no-op implementation when
   the real one is absent), and inject that.

## Related

ALU-DI-1001.
