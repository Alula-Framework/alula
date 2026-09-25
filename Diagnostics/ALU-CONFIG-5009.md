# ALU-CONFIG-5009: A configuration source could not answer

**Severity:** error

## Meaning

At startup, a configuration source failed while reading a key — a secrets
store that is down or refused permission — or holds a value with no single
string form, such as an array read as a scalar.

## Why Alula rejects it

Resolution stops at the failing source rather than falling through to a
lower-precedence layer. Falling through would answer a production key from
the development YAML underneath, silently and with the right-looking value.

## Fixes

1. Restore access to the source the message names.
2. For an array, read it through `Configuration.reader` and ask for the array type.

## Related

ALU-CONFIG-5004.
