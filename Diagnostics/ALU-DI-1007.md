# ALU-DI-1007: @Inject(from:) names a module that provides the type more than once

**Severity:** error

## Meaning

The module named by `@Inject(from:)` holds two or more stored properties of
the requested type, so naming the module does not pick one.

## Fixes

1. Give each value its own type (a small wrapper struct is enough).
2. Keep one of the properties and compute the other where it is used.

## Related

ALU-DI-1002.
