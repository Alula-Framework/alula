# Alula Queue

Background jobs. Hand work off from a request, a channel or a scheduled job,
and a worker runs it: retried with backoff when it fails, and kept as a dead
letter when it never succeeds.

This is not the scheduler. The scheduler runs code *at times*. Its `.once`
promises at most once, and a missed firing is gone. A queue runs work that
*must happen*, as soon as possible or after a delay, at least once, and
survives a restart when its store does.

## Adding this module

| | |
|---|---|
| **Trait** | none |
| **Products** | `AlulaQueue`; `AlulaQueueTesting` for tests |
| **Modules** | `AlulaQueueWorkerModule.self`, which brings `AlulaQueueModule` |
| **For durability** | `AlulaQueuePostgresModule.self` from alula-data (`AlulaQueuePostgres`, trait `Postgres`) |

```swift
await Alula.run(
    configuration: try Configuration.load(),
    modules: [
        PostgresDataModule<PrimaryDataSource>.self,
        AlulaQueuePostgresModule.self,
        AlulaQueueWorkerModule.self,
        AppModule.self,
    ],
    composedBy: alulaComposeModules)
```

## Jobs, enqueueing and handlers

A job is the data the work needs, as a `Codable` value:

```swift
struct SendWelcomeEmail: QueuedJob {
    static let queue = "mail"                                  // default "default"
    static let retry = RetryPolicy(maxAttempts: 5)             // default 10
    let userID: UUID
}
```

Enqueue it through the `JobQueue`, which any component can inject:

```swift
@Service
struct UserService {
    @Inject var jobs: JobQueue

    func signup(...) async throws -> User {
        let user = try await repository.create(...)
        try await jobs.enqueue(SendWelcomeEmail(userID: user.id))
        return user
    }
}
```

`EnqueueOptions` adds a `delay` or `runAt`, a `priority` (lower first), a
`uniqueKey`, or a different queue. While a job with a given kind and unique
key is waiting or running, enqueueing another returns the first, so "rebuild
the digest for room 7", enqueued by ten messages, runs once.

A handler is the code, contributed by any module holding `[QueueHandler]`.
The application module is the usual place, since it has the component graph:

```swift
struct AppModule: AlulaModule {
    let queueHandlers: [QueueHandler]

    init(graph: AlulaGraph) {
        queueHandlers = [
            .handle(SendWelcomeEmail.self) { job, context in
                try await graph.mailer.sendWelcome(to: job.userID)
            },
        ]
    }
}
```

Enqueueing and running are two modules, and that is not ceremony. Services
take the `JobQueue`, and handlers are built from those services. If one module
provided the queue and took the handlers, it would sit on both sides of the
component graph, a composition cycle the build refuses.

## Delivery: at least once

Each running job holds a lease, renewed every third of `queue.lease-seconds`.
A worker that dies stops renewing. Once the lease lapses, the next claim takes
the job and runs it again. Results are fenced by attempt number, so a worker
that was only slow cannot overwrite the new owner's result when it wakes up.

The consequence is the one every durable queue has: **a handler can run
twice**. Make it safe to repeat. Check whether the email went out before
sending it, and write with a key that makes the second write a no-op.

## Failure

| What happened | What the queue does |
|---|---|
| The handler threw | Retries after `base × 2^(attempt−1)` (±10% jitter), up to `cap` |
| It threw on its last attempt | Discards it: kept, with the error, for `retain-discarded-days` |
| It threw `DiscardJob("reason")` | Discards it now |
| The payload no longer decodes | Discards it now, since no retry changes it |
| It ran past its `timeout` (default 300 s) | Counts as a thrown error |
| No handler in this process | Never claimed here, so a rolling deploy adding a kind is safe |
| Its worker died on the last attempt | Discards it: the attempt was spent |

A handler's `timeout:` cancels the attempt. Code that ignores cancellation
still has to return before the worker moves on.

## Configuration

```yaml
queue:
  concurrency: 10              # per queue, per process
  poll-interval-ms: 1000       # how soon another process's enqueue is seen
  lease-seconds: 60            # how soon a dead worker's job is retried
  retain-completed-hours: 24
  retain-discarded-days: 14
  queues:
    reports:
      concurrency: 2           # slow work cannot take every slot
  worker:
    enabled: true              # false where a process only enqueues
    only: mail, reports        # run just these queues here
  postgres:
    table: alula_jobs          # AlulaQueuePostgresModule
```

An enqueue in the same process wakes its worker at once. One from another
process is picked up on the next poll.

## Durability

With no store module, jobs are kept in memory: right for development and
tests, and outside them `AlulaQueueModule` logs a warning at startup, because
a restart loses every waiting job.

`AlulaQueuePostgresModule` keeps them in a table. It claims with
`FOR UPDATE SKIP LOCKED`, so workers on every replica share the queue without
contending. The table is not created at boot. Put the statements from
`PostgresQueueStore.schema()` in a migration.

It can also enqueue **inside your transaction**, so the job commits exactly
when the change that caused it does:

```swift
try await pool.withRepo { repo in
    try await repo.transaction { tx in
        let order = try await tx.insert(order)
        _ = try await queueStore.enqueue(jobs.prepare(ShipOrder(id: order.id)), in: tx)
    }
}
```

Enqueueing after the commit risks losing the job if the process dies between
the two. Enqueueing before it risks running a job for a change that then
rolls back.

## Shutdown

On `SIGTERM` the worker stops claiming and waits for the jobs it holds.
Bound that wait with `lifecycle.shutdown-timeout-seconds`. Past the bound,
handlers are cancelled, and their jobs run again elsewhere once their leases
lapse.

## Testing

`QueueTestHarness` runs jobs on demand, on a clock the test moves:

```swift
let harness = QueueTestHarness(handlers: [.handle(SendWelcomeEmail.self) { job, _ in … }])
try await UserService(repository: fake, jobs: harness.queue).signup(...)
#expect(await harness.drain() == [.completed])

// A failing job waits for its retry until the clock says so:
harness.advance(by: .seconds(15))
await harness.drain()
```

## Telemetry

With the `Telemetry` trait (on with `Web`), the queue reports through
`AlulaTelemetryModule`, tagged by queue and job kind, never by job id:

| Metric | What |
|---|---|
| `alula.queue.enqueued` | jobs enqueued |
| `alula.queue.attempts` | attempts finished, by `outcome`: `completed`, `retrying`, `discarded`, `superseded` |
| `alula.queue.duration` | how long handlers ran |
| `alula.queue.wait` | from enqueue to an attempt's start, delays and backoff included |
| `alula.queue.available`, `.running`, `.discarded` | each queue's depth, sampled by workers at the poll interval (at least every 5 s) |
| `alula.queue.lease_renewal_failures`, `.claim_failures` | the store refusing a worker |

Alert on `available` growing and on `discarded`: a queue that is correct but
backing up is invisible without them. The events themselves are
`QueueEvents`, for anything else (a log line, a test). Without the trait the
queue reports nothing and depends on nothing extra.

## Not here yet

- **An Actuator view of queue depth.** The depth metrics above carry it;
  the dashboard does not show it yet.
- **LISTEN/NOTIFY wakeups**, so another process's enqueue is seen at once
  rather than on the next poll.
- **A Valkey store.**
