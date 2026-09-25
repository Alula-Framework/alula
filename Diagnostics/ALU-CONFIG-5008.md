# ALU-CONFIG-5008: A configuration value of the wrong type

**Severity:** error

## Meaning

At startup, a configuration key has a value that does not decode as the type
the application reads it as — `server.port: eighty` read as an `Int`.

## Why Alula rejects it

A value that cannot be what the code expects would fail later, somewhere
less obvious. Configuration is resolved while the application starts so that
it fails there, naming the key.

## Common causes

- A typo in the value.
- An environment variable overriding the key with the wrong kind of value.

## Fixes

1. Correct the value in the file or variable that supplies it — the message names the key and the value it found.

## Related

ALU-CONFIG-5004.
