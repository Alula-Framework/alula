# ALU-DI-1009: @Inject of a type nothing in the scan provides

**Severity:** warning

## Meaning

An `@Inject` names a type that is neither a scanned `@Component` nor a value
any included module provides.

## Why Alula warns

It may be provided some other way the build cannot see — a value supplied
by hand at composition. If it is not, the application fails at startup
instead of at build time.

## Fixes

1. Make the type a `@Component`, or have a module hold it.
2. If it is supplied by hand on purpose, acknowledge it with a
   `// alula:hand-registered` comment on the property.

## Related

ALU-DI-1001.
