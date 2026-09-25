# ALU-CONFIG-5007: The base configuration file does not parse

**Severity:** error

## Meaning

The base configuration file is not valid YAML, or could not be read. The
diagnostic points at the line and column the parser stopped at.

The same code is printed at startup when a configuration file cannot be read or parsed.

## Why Alula rejects it

The build reads the file to check keys, with the same parser the
application uses at startup — so a file the build cannot read is one the
application cannot either.

## Common causes

- Inconsistent indentation.
- A tab used for indentation.

## Fixes

1. Fix the YAML at the reported position.

## Related

ALU-CONFIG-5004.
