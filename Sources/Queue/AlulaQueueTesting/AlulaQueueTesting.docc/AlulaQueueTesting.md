# ``AlulaQueueTesting``

Run queued jobs on demand, on a clock the test controls.

## Overview

``QueueTestHarness`` gives a test a `JobQueue` to hand to the code under
test, and runs what was enqueued when the test says so:

```swift
let harness = QueueTestHarness(handlers: [
    .handle(SendWelcomeEmail.self) { job, _ in sent.append(job.userID) },
])
try await SignupService(jobs: harness.queue).signUp(form)

#expect(await harness.drain() == [.completed])
```

There is no worker and no sleeping. `drain()` runs due jobs in the order a
worker would, and a failed job waits for its retry until the test calls
`advance(by:)`. So a test can walk a job through every attempt:

```swift
harness.advance(by: .seconds(15))
#expect(await harness.drain() == [...])
```

## Topics

- ``QueueTestHarness``
