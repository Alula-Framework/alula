# ALU-DI-1006: @Inject(from:) names a module the application does not include

**Severity:** error

## Meaning

`@Inject(from: SomeModule.self)` names a module that is not part of this
application.

## Why Alula rejects it

A module takes part only when it is in `modules:`, or in the `dependencies`
of a module that is. A value cannot come from a module that is never built.

## Fixes

1. Add the module to `modules:`, or to the `dependencies` of a module that
   is already there.
2. Name a module the application does include.

## Related

ALU-DI-1005.
