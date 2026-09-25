# ALU-CONFIG-5006: The build could not check configuration keys

**Severity:** warning

## Meaning

The build checks every configuration key without a default against the base
configuration file, and this time it could not:

- the base file (`alula.yaml`, or `<prefix>.yaml`) is not in the package;
- the prefix passed to `Configuration.load` is not a string literal;
- the target loads configuration with more than one prefix.

## Why Alula rejects it

The keys are still checked — at startup, which is later than it needs to be.
The warning exists because a check that silently does not run is worse than
none: it teaches you to trust it.

## Fixes

1. Add the base file at the package root.
2. Pass the prefix as a literal: `Configuration.load(prefix: "relay")`.
3. Load configuration with one prefix.

## Related

ALU-CONFIG-5004, ALU-CONFIG-5005.
