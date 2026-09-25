# ALU-SCHED-9004: @Scheduled on a method Alula cannot run as a job

**Severity:** error

## Meaning

`@Scheduled` is on something that is not a method, on a method that takes
parameters or returns a value, or appears twice on one method.

## Why Alula rejects it

The scheduler calls the job with nothing and reads nothing back: there is
no caller to supply arguments or to use a result. A job is named after its
method, so two schedules on one method would collide rather than both run.

## Fixes

1. Take no parameters; inject what the job needs into the enclosing type.
2. Return `Void`, and record results where they are needed.
3. Split two schedules across two methods, or declare the extra one as a `ScheduledJobRegistration` value.

## Example

```swift
@Scheduler
struct Maintenance {
    @Inject var store: SessionStore
    @Scheduled(every: .hours(1)) func purge() async throws { try await store.purgeExpired() }
}
```

## Related

ALU-SCHED-9005.
