# ALU-CONFIG-5013: A module's settings are invalid

**Severity:** error

## Meaning

While the application started, a module checked its settings and refused
them: a TLS certificate with no key, a rate limit of zero, an actuator exposed
without authentication, a webhook secret that is empty. The message after the
code says which setting and why.

## Why Alula rejects it

A module that cannot run as configured stops the start rather than running
some other way — an unprotected actuator, an unlimited rate limit — and
letting that be found in production.

## Fixes

1. Correct the setting the message names, in the configuration file or the environment variable that supplies it.

## Related

ALU-CONFIG-5004, ALU-CONFIG-5008.
