# ALU-SCHED-9003: A @Scheduled argument that is not a literal

**Severity:** error

## Meaning

A `@Scheduled` cron expression, time zone or `onEveryNode:` value is a
variable or an expression.

## Why Alula rejects it

Schedules are checked at build time, from the source. A value known only at
runtime cannot be checked.

## Fixes

1. Write the value as a literal.
2. For a schedule only known at runtime, build a `ScheduledJobRegistration` value instead.

## Example

```swift
@Scheduled("0 */15 * * * *", onEveryNode: false)
```

## Related

ALU-SCHED-9001.
