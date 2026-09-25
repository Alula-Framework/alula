# ALU-SCHED-9002: @Scheduled with no schedule, or with two

**Severity:** error

## Meaning

A `@Scheduled` attribute gives neither a cron expression nor an `every:`
interval, or gives both.

## Why Alula rejects it

A job needs exactly one description of when it runs. With none it would
never run; with two, one would be ignored.

## Fixes

1. Give a cron expression: `@Scheduled("0 0 3 * * *")`.
2. Or an interval: `@Scheduled(every: .minutes(5))`.
3. Not both.

## Example

```swift
@Scheduled(every: .minutes(5))
func sweep() async throws { … }
```

## Related

ALU-SCHED-9001.
