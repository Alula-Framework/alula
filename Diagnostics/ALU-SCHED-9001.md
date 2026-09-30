# ALU-SCHED-9001: A cron expression or time zone that does not parse

**Severity:** error

## Meaning

A `@Scheduled` cron expression is malformed, or its time zone is not an
IANA identifier.

The build checks the time zone against the build machine's time zone
database. The application checks it again when it starts, against the
database where it runs. If that database lacks the zone, `Alula.run` stops
with this code before serving and names the job.

## Why Alula rejects it

Cron expressions are checked at build time so that a schedule that would
never fire, or would fire at the wrong moment, is caught before deploy. An
unknown time zone would fall back to GMT at runtime without a word.

## Common causes

- A field out of range, such as hour `24` or month `13`.
- A time zone written with spaces: "America/New York" instead of "America/New_York".
- At startup only: a container image without the `tzdata` package, so with
  no time zone database at all.

## Fixes

1. Fix the expression as the message says. Six fields (seconds first) or the classic five.
2. Use an IANA identifier such as "America/New_York", "Europe/London" or "UTC".
3. At startup: install `tzdata` in the image the application runs in.

## Example

```swift
@Scheduled("0 0 3 * * *", timeZone: "America/New_York")
func nightly() async throws { … }
```

## Related

ALU-SCHED-9003.
