# ALU-LIFE-8004: Shutdown did not finish within its timeout

**Severity:** error

## Meaning

The application was asked to stop, and some of its services were still
running when `lifecycle.shutdown-timeout-seconds` ran out. They were
cancelled, and the report names them.

## Why Alula rejects it

A shutdown that runs out of time cancels work in the middle — a job half
done, a request cut off — and that used to be said only at debug level, with
the process exiting 0 as though it had stopped cleanly (Relay #36). It exits
non-zero now, saying which services were cut off.

## Common causes

- A job or request that runs longer than the timeout.
- A service that does not watch for cancellation or graceful shutdown.

## Fixes

1. Raise `lifecycle.shutdown-timeout-seconds` above the longest job or request you expect to finish.
2. Make that work stop sooner: check `Task.isCancelled` or the graceful-shutdown signal, and hand unfinished jobs back.

## Related

ALU-LIFE-8002.
