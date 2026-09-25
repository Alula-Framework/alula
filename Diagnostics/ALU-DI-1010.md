# ALU-DI-1010: @Inject of a protocol several components conform to

**Severity:** warning

## Meaning

An `@Inject` asks for an existential (`any Mailer`), and more than one
scanned component conforms, so no bridge from the protocol to a concrete
component was generated.

## Fixes

1. Inject the concrete type you mean.
2. Provide the existential from a module (`let mailer: any Mailer`), which
   makes the choice explicit.
3. If you supply it by hand, acknowledge it with `// alula:hand-registered`.

## Related

ALU-DI-1002.
