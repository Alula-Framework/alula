# ALU-LIFE-8005: A module failed after the application started

**Severity:** error

## Meaning

Every service had started and the application had been running for a while
when one module's service threw. Services in an Alula application stop
together, so the whole application stopped. The report names the module,
how long the application had been running, and the error it threw.

## Why Alula rejects it

This is not a failed start, and reporting it as "could not start" sent
readers to check configuration that had worked for hours. The error says
what actually happened: the application served, then this module failed.

## Common causes

- A connection the module depends on closed or refused, such as a database, a
  broker, or an upstream feed, and the module's service let the error escape.
- A bug in the module's service loop, reached only by live traffic.

## Fixes

1. Read the error under the diagnostic: it is the module's own error, unchanged.
2. If the failure is one the service should survive, such as a dropped connection,
   catch it inside the service's loop and retry, instead of letting it end the application.

## Related

ALU-LIFE-8006, ALU-LIFE-8004.
