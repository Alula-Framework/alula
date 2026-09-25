# ALU-SCHED-9005: @Scheduler on something that schedules nothing

**Severity:** error

## Meaning

`@Scheduler` is attached to something that is not a class or struct, or to
a type with no `@Scheduled` methods.

## Why Alula rejects it

`@Scheduler` exists to register the type's scheduled jobs. With none, it
registers nothing — usually a sign the jobs were removed or never marked.

## Fixes

1. Add a `@Scheduled` method.
2. If this is an ordinary component, use `@Component` instead.

## Related

ALU-SCHED-9004.
