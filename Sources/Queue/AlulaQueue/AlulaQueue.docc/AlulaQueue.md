# ``AlulaQueue``

Background jobs: enqueue from anywhere, run in a worker, retry with backoff,
and keep the ones that never succeed.

## Overview

A job is data, and a handler is the code that runs it:

```swift
struct SendWelcomeEmail: QueuedJob {
    static let queue = "mail"
    let userID: UUID
}

// Wherever the work is handed off:
try await jobs.enqueue(SendWelcomeEmail(userID: user.id))

// In a module, built from the component graph:
let queueHandlers: [QueueHandler] = [
    .handle(SendWelcomeEmail.self) { job, context in
        try await mailer.sendWelcome(to: job.userID)
    },
]
```

``AlulaQueueModule`` provides the ``JobQueue``. ``AlulaQueueWorkerModule``
collects every module's handlers and runs them. The split is structural:
services take the queue, handlers are built from those services, and one
module doing both would be a composition cycle. It also lets a web tier
enqueue while separate processes do the work (`queue.worker.enabled: false`).

## At least once

A job runs **at least once**. A worker holds a lease on each job it runs and
renews it while the job is running. If the worker dies, the lease lapses and
another worker runs the job again. So a handler must be safe to repeat: check
before sending, write with a unique key, and treat "already done" as done.

The alternative, at most once, is what the scheduler's `.once` offers, and it
is the wrong trade for work that must happen: a crash there loses the work
silently.

## What happens when a job fails

A handler that throws is retried under its ``RetryPolicy``, doubling from 15
seconds to at most an hour over 10 attempts by default. After the last
attempt it is **discarded**: kept, with its last error, for
`queue.retain-discarded-days`, so someone can see what never happened.
Throw ``DiscardJob`` to stop at once. A payload that no longer decodes is
discarded rather than retried, because no retry will change it.

## Durability

With no store configured, jobs live in memory. That is fine in development
and tests, and anywhere else ``AlulaQueueModule`` warns at startup that a
restart loses every waiting job. alula-data's `AlulaQueuePostgresModule` keeps
them in Postgres, and can enqueue inside the same transaction as the change
that caused the job.

## Topics

### Defining and enqueueing work

- ``QueuedJob``
- ``JobQueue``
- ``EnqueueOptions``
- ``EnqueueResult``
- ``RetryPolicy``
- ``DiscardJob``

### Running it

- ``QueueHandler``
- ``QueueJobContext``
- ``QueueRunner``
- ``QueueAttemptOutcome``

### Composition and configuration

- ``AlulaQueueModule``
- ``AlulaQueueWorkerModule``
- ``QueueSettings``
- ``QueueConfigurationError``
- ``QueueCompositionError``

### Storage

- ``QueueStore``
- ``InMemoryQueueStore``
- ``NewQueuedJob``
- ``ClaimedJob``
- ``QueuedJobID``
- ``QueueCounts``
