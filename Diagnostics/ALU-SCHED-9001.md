# ALU-SCHED-9001: A cron expression or time zone that does not parse

**Severity:** error

## Meaning

A `@Scheduled` cron expression is malformed, or its time zone is not an
IANA identifier.

## Why Alula rejects it

Cron expressions are checked at build time so that a schedule that would
never fire, or would fire at the wrong moment, is caught before deploy. An
unknown time zone would fall back to GMT at runtime without a word.

## Common causes

- A field out of range, such as hour `24` or month `13`.
- A time zone written with spaces: "America/New York" instead of "America/New_York".

## Fixes

1. Fix the expression as the message says. Six fields (seconds first) or the classic five.
2. Use an IANA identifier such as "America/New_York", "Europe/London" or "UTC".

## Example

```swift
@Scheduled("0 0 3 * * *", timeZone: "America/New_York")
func nightly() async throws { … }
```

## Related

ALU-SCHED-9003.
