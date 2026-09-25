# ALU-DI-1005: @Inject(from:) names a module that does not provide the type

**Severity:** error

## Meaning

`@Inject(from: SomeModule.self)` asks for a value from a particular module,
and that module holds no stored property of the requested type.

## Why Alula rejects it

`from:` is a promise the build checks rather than trusts. A module
provides a value only by holding it as a stored property with a written
type.

## Common causes

- The wrong module is named.
- The module computes the value instead of storing it, or stores it with no
  written type.

## Fixes

1. Name the module that holds the value.
2. Give the module a stored property of that type.

## Related

ALU-DI-1002, ALU-DI-1006, ALU-DI-1011.
