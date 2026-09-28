# ALU-DI-1009: @Inject of a type nothing in the scan provides

**Severity:** warning

## Meaning

An `@Inject` in a library target names a type that is neither a scanned
`@Service` nor a value any scanned module provides — in the library itself or
in a package it links.

## Why Alula warns

A library composes nothing, so the build cannot check its wiring the way it
checks an application's. It can still see every module in the scan; a type
none of them provides has no known source, and an application that uses the
component fails to build (ALU-DI-1001) unless it supplies one itself.

In an application target this warning never appears: the composer checks
every dependency against the modules the application includes, and reports a
missing one as ALU-DI-1001.

## Fixes

1. Make the type a `@Service`.
2. Have a module provide it (`public let pool: DataSource`) — one the library
   declares, or one in a package it links.

## Related

ALU-DI-1001.
