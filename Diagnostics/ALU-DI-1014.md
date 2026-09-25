# ALU-DI-1014: The removed type-level `qualifier:` argument

**Severity:** error

## Meaning

A component declares a type-level `qualifier:`, removed in 0.20.0.

## Why Alula rejects it

It expanded to nothing: composition wires by type, not by name. The
property-level `@Inject("name")` went in the same release, and two `@Inject`
properties of one type are a build error, because nothing distinguishes them.

## Fixes

Delete the argument. To choose between providers of one type, use
`defaultProviders` and `@Inject(from:)` (ALU-DI-1002).
