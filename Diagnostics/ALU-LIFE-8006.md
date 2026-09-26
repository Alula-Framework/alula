# ALU-LIFE-8006: A module's service returned while the application ran

**Severity:** error

## Meaning

A module's service returned without throwing. A module's service is meant
to run until the application shuts down, so returning early stops the
application. The report names the module, and says whether the application
had started or not.

## Why Alula rejects it

A service that returns has not failed, so there is no error to show, and
the application stopped with nothing saying why. A service ending on its
own is almost always a mistake, so Alula names the module.

## Common causes

- A `for await` loop over a stream that finished, for example because its
  producer ended or its connection closed cleanly.
- A `run()` that starts work in the background and returns, instead of
  waiting for it or for graceful shutdown.
- A service that really is a bounded job, such as a one-off import, that
  was not declared as one.

## Fixes

1. Keep `run()` running until shutdown: await the work, or end with `try await gracefulShutdown()`.
2. For a bounded job whose completion should end the application, declare
   `serviceCompletion: .endsApp` on the module.

## Related

ALU-LIFE-8005.
