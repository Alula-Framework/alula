# ALU-DI-1010: @Inject of a protocol several components conform to

**Severity:** warning

## Meaning

An `@Inject` asks for an existential (`any Mailer`), more than one scanned
component conforms, and no included module provides the existential itself,
so no bridge from the protocol to a concrete component was generated.

## Fixes

1. Inject the concrete type you mean.
2. Provide the existential from a module (`let mailer: any Mailer`), which
   makes the choice explicit: when an included module provides it, the build
   uses that value and bridges to no conformer.

## Related

ALU-DI-1002.
