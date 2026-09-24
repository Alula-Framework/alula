import AlulaCore
import Foundation
import Logging
import ServiceLifecycle
import Synchronization
import Testing

@testable import AlulaQueue
import AlulaQueueTesting

struct Greet: QueuedJob {
    let name: String
}

struct Flaky: QueuedJob {
    static let queue = "flaky"
    static let retry = RetryPolicy(maxAttempts: 3, base: .seconds(10), jitter: 0)
    let id: Int
}

struct Boom: Error, CustomStringConvertible {
    var description: String { "boom" }
}

final class Recorder: Sendable {
    private let values = Mutex<[String]>([])
    func append(_ value: String) { values.withLock { $0.append(value) } }
    var all: [String] { values.withLock { $0 } }
}

@Suite("Queue: enqueue, run, retry, discard")
struct QueueBehaviourTests {

    @Test("an enqueued job runs with its payload and completes")
    func runsAndCompletes() async throws {
        let seen = Recorder()
        let harness = QueueTestHarness(handlers: [
            .handle(Greet.self) { job, _ in seen.append(job.name) }
        ])
        try await harness.queue.enqueue(Greet(name: "ada"))
        #expect(await harness.drain() == [.completed])
        #expect(seen.all == ["ada"])
        #expect(await harness.counts() == QueueCounts(completed: 1))
    }

    @Test("a failure retries after its backoff, and is discarded once out of attempts")
    func retriesThenDiscards() async throws {
        let harness = QueueTestHarness(handlers: [.handle(Flaky.self) { _, _ in throw Boom() }])
        let id = try await harness.queue.enqueue(Flaky(id: 1)).id

        let first = await harness.drain()
        guard case .retrying(let at, let error) = first.first else {
            Issue.record("expected a retry, got \(first)")
            return
        }
        #expect(error == "boom")
        #expect(at == harness.now.addingTimeInterval(10))
        // Not due yet: nothing runs.
        #expect(await harness.drain().isEmpty)

        harness.advance(by: .seconds(10))
        guard case .retrying(let second, _) = await harness.drain().first else {
            Issue.record("expected a second retry")
            return
        }
        // Doubling: 10 s, then 20 s.
        #expect(second == harness.now.addingTimeInterval(20))

        harness.advance(by: .seconds(20))
        guard case .discarded(let reason) = await harness.drain().first else {
            Issue.record("expected a discard on the third attempt")
            return
        }
        #expect(reason.contains("out of attempts"))
        #expect(harness.store.lastError(of: id)?.contains("boom") == true)
        #expect(await harness.counts(queue: "flaky") == QueueCounts(discarded: 1))
    }

    @Test("DiscardJob stops retrying at once")
    func discardJobIsFinal() async throws {
        let harness = QueueTestHarness(handlers: [
            .handle(Greet.self) { _, _ in throw DiscardJob("user deleted") }
        ])
        try await harness.queue.enqueue(Greet(name: "gone"))
        #expect(await harness.drain() == [.discarded(reason: "user deleted")])
    }

    @Test("a payload that no longer decodes is discarded, not retried")
    func undecodablePayloadDiscards() async throws {
        struct Renamed: QueuedJob {
            static let kind = "Greet"
            let fullName: String
        }
        let harness = QueueTestHarness(handlers: [.handle(Renamed.self) { _, _ in }])
        try await harness.queue.enqueue(Greet(name: "ada"))
        guard case .discarded(let reason) = await harness.drain().first else {
            Issue.record("expected a discard")
            return
        }
        #expect(reason.contains("does not decode"))
    }

    @Test("an attempt over its timeout counts as a failure")
    func timeoutFails() async throws {
        let harness = QueueTestHarness(handlers: [
            .handle(Flaky.self, timeout: .milliseconds(50)) { _, _ in
                try await Task.sleep(for: .seconds(30))
            }
        ])
        try await harness.queue.enqueue(Flaky(id: 1))
        guard case .retrying(_, let error) = await harness.drain().first else {
            Issue.record("expected a retry")
            return
        }
        #expect(error.contains("timeout"))
    }

    @Test("a unique key collapses enqueues while the first is waiting, and only then")
    func uniqueness() async throws {
        let harness = QueueTestHarness(handlers: [.handle(Greet.self) { _, _ in }])
        let options = EnqueueOptions(uniqueKey: "room-7")
        let first = try await harness.queue.enqueue(Greet(name: "a"), options: options)
        let second = try await harness.queue.enqueue(Greet(name: "b"), options: options)
        #expect(second == .duplicate(first.id))

        await harness.drain()
        let third = try await harness.queue.enqueue(Greet(name: "c"), options: options)
        guard case .enqueued = third else {
            Issue.record("a finished job must not block a new one")
            return
        }
    }

    @Test("priority first, then due time; a delayed job waits")
    func ordering() async throws {
        let seen = Recorder()
        let harness = QueueTestHarness(handlers: [
            .handle(Greet.self) { job, _ in seen.append(job.name) }
        ])
        try await harness.queue.enqueue(Greet(name: "later"), options: .init(delay: .seconds(60)))
        try await harness.queue.enqueue(Greet(name: "low"), options: .init(priority: 5))
        try await harness.queue.enqueue(Greet(name: "high"), options: .init(priority: -5))
        await harness.drain()
        #expect(seen.all == ["high", "low"])

        harness.advance(by: .seconds(60))
        await harness.drain()
        #expect(seen.all == ["high", "low", "later"])
    }
}

@Suite("Queue store contract")
struct QueueStoreContractTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func job(_ kind: String = "Greet", queue: String = "default") -> NewQueuedJob {
        NewQueuedJob(
            kind: kind, queue: queue, payload: Data("{}".utf8), runAt: t0, maxAttempts: 3,
            enqueuedAt: t0)
    }

    @Test("a dead worker's job is claimed again after its lease, and the old attempt is fenced off")
    func leaseExpiryAndFencing() async throws {
        let store = InMemoryQueueStore()
        let id = try await store.enqueue(job()).id
        let first = try await store.claim(
            queue: "default", kinds: ["Greet"], limit: 1, now: t0, leaseUntil: t0 + 30)
        #expect(first.map(\.attempt) == [1])

        // Lease still held: nobody else gets it.
        #expect(
            try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 1, now: t0 + 10, leaseUntil: t0 + 40
            ).isEmpty)

        let second = try await store.claim(
            queue: "default", kinds: ["Greet"], limit: 1, now: t0 + 31, leaseUntil: t0 + 61)
        #expect(second.map(\.attempt) == [2])

        // The first worker comes back and tries to finish: refused.
        #expect(try await store.complete(id, attempt: 1, at: t0 + 32) == false)
        #expect(try await store.complete(id, attempt: 2, at: t0 + 33))
    }

    @Test("a renewed lease keeps the job")
    func renewal() async throws {
        let store = InMemoryQueueStore()
        let id = try await store.enqueue(job()).id
        _ = try await store.claim(
            queue: "default", kinds: ["Greet"], limit: 1, now: t0, leaseUntil: t0 + 30)
        try await store.extendLeases([(id, 1)], until: t0 + 90)
        #expect(
            try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 1, now: t0 + 60, leaseUntil: t0 + 120
            ).isEmpty)
    }

    @Test("a worker claims only kinds it can run, and only its queue")
    func claimFilters() async throws {
        let store = InMemoryQueueStore()
        _ = try await store.enqueue(job("NewKind"))
        _ = try await store.enqueue(job("Greet", queue: "mail"))
        #expect(
            try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 10, now: t0, leaseUntil: t0 + 30
            ).isEmpty)
    }

    @Test("the final attempt lost to a dead worker is discarded, not run again")
    func lostFinalAttempt() async throws {
        let store = InMemoryQueueStore()
        var single = job()
        single.maxAttempts = 1
        let id = try await store.enqueue(single).id
        _ = try await store.claim(
            queue: "default", kinds: ["Greet"], limit: 1, now: t0, leaseUntil: t0 + 30)
        let reclaimed = try await store.claim(
            queue: "default", kinds: ["Greet"], limit: 1, now: t0 + 31, leaseUntil: t0 + 61)
        let ran = Recorder()
        let outcome = await QueueRunner(store: store, now: { self.t0 + 31 }).run(
            try #require(reclaimed.first),
            handler: .handle(Greet.self) { _, _ in ran.append("ran") })
        guard case .discarded = outcome else {
            Issue.record("expected discard, got \(outcome)")
            return
        }
        #expect(ran.all.isEmpty)
        #expect(store.lastError(of: id)?.contains("final attempt") == true)
    }

    @Test("prune removes finished jobs past retention and nothing live")
    func prune() async throws {
        let store = InMemoryQueueStore()
        let done = try await store.enqueue(job()).id
        _ = try await store.enqueue(job())
        let claimed = try await store.claim(
            queue: "default", kinds: ["Greet"], limit: 1, now: t0, leaseUntil: t0 + 30)
        #expect(claimed.first?.id == done || claimed.count == 1)
        try await store.complete(try #require(claimed.first).id, attempt: 1, at: t0 + 1)
        #expect(try await store.prune(completedBefore: t0 + 2, discardedBefore: t0 + 2) == 1)
        #expect(try await store.counts(queue: "default") == QueueCounts(available: 1))
    }
}

@Suite("Queue worker", .serialized)
struct QueueWorkerTests {

    private func worker(
        _ queue: JobQueue, handlers: [QueueHandler], configuration: [String: String] = [:]
    ) throws -> any Service {
        try #require(
            try AlulaQueueWorkerModule(
                configuration: Configuration(values: configuration), queue: queue,
                handlers: handlers
            ).service)
    }

    @Test("a job enqueued in this process runs without waiting for the poll")
    func wakesOnEnqueue() async throws {
        let queue = JobQueue(store: InMemoryQueueStore())
        let done = AsyncStream<Void>.makeStream()
        let service = try worker(
            queue,
            handlers: [.handle(Greet.self) { _, _ in done.continuation.yield() }],
            configuration: ["queue.poll-interval-ms": "60000"])
        let group = ServiceGroup(
            configuration: .init(services: [service], logger: Logger(label: "test")))
        let running = Task { try await group.run() }
        try await Task.sleep(for: .milliseconds(50))

        let started = ContinuousClock.now
        try await queue.enqueue(Greet(name: "now"))
        var iterator = done.stream.makeAsyncIterator()
        _ = await iterator.next()
        // A one-minute poll, answered in well under a second.
        #expect(ContinuousClock.now - started < .seconds(5))

        await group.triggerGracefulShutdown()
        try await running.value
    }

    @Test("concurrency bounds how many run at once")
    func concurrencyBound() async throws {
        let queue = JobQueue(store: InMemoryQueueStore())
        let current = Atomic(0)
        let peak = Atomic(0)
        let finished = Atomic(0)
        let service = try worker(
            queue,
            handlers: [
                .handle(Greet.self) { _, _ in
                    let now = current.add(1, ordering: .relaxed).newValue
                    _ = peak.max(now, ordering: .relaxed)
                    try await Task.sleep(for: .milliseconds(30))
                    current.subtract(1, ordering: .relaxed)
                    finished.add(1, ordering: .relaxed)
                }
            ],
            configuration: ["queue.concurrency": "3", "queue.poll-interval-ms": "20"])
        for index in 0..<12 { try await queue.enqueue(Greet(name: "\(index)")) }

        let group = ServiceGroup(
            configuration: .init(services: [service], logger: Logger(label: "test")))
        let running = Task { try await group.run() }
        let deadline = ContinuousClock.now + .seconds(10)
        while finished.load(ordering: .relaxed) < 12, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await group.triggerGracefulShutdown()
        try await running.value

        #expect(finished.load(ordering: .relaxed) == 12)
        #expect(peak.load(ordering: .relaxed) <= 3)
        #expect(peak.load(ordering: .relaxed) > 1)
    }

    @Test("graceful shutdown lets a running job finish and records it")
    func shutdownDrains() async throws {
        let store = InMemoryQueueStore()
        let queue = JobQueue(store: store)
        let started = AsyncStream<Void>.makeStream()
        let service = try worker(
            queue,
            handlers: [
                .handle(Greet.self) { _, _ in
                    started.continuation.yield()
                    try await Task.sleep(for: .milliseconds(300))
                }
            ])
        let group = ServiceGroup(
            configuration: .init(services: [service], logger: Logger(label: "test")))
        let running = Task { try await group.run() }
        try await queue.enqueue(Greet(name: "slow"))
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()

        await group.triggerGracefulShutdown()
        try await running.value
        #expect(try await store.counts(queue: "default") == QueueCounts(completed: 1))
    }

    @Test("a job running past its lease keeps it: a second worker never runs it too")
    func renewalPreventsDoubleRun() async throws {
        let store = InMemoryQueueStore()
        let runs = Atomic(0)
        let finished = Atomic(0)
        let handlers: [QueueHandler] = [
            .handle(Greet.self, timeout: nil) { _, _ in
                runs.add(1, ordering: .relaxed)
                try await Task.sleep(for: .milliseconds(2500))
                finished.add(1, ordering: .relaxed)
            }
        ]
        let settings = ["queue.lease-seconds": "1", "queue.poll-interval-ms": "50"]
        let first = try worker(JobQueue(store: store), handlers: handlers, configuration: settings)
        let second = try worker(JobQueue(store: store), handlers: handlers, configuration: settings)
        let group = ServiceGroup(
            configuration: .init(services: [first, second], logger: Logger(label: "test")))
        try await JobQueue(store: store).enqueue(Greet(name: "long"))
        let running = Task { try await group.run() }

        let deadline = ContinuousClock.now + .seconds(10)
        while finished.load(ordering: .relaxed) < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        await group.triggerGracefulShutdown()
        try await running.value
        #expect(runs.load(ordering: .relaxed) == 1)
        #expect(try await store.counts(queue: "default") == QueueCounts(completed: 1))
    }

    @Test("two handlers for one kind fail composition")
    func duplicateHandler() {
        #expect(throws: QueueCompositionError.duplicateHandler(kind: "Greet")) {
            try AlulaQueueWorkerModule(
                configuration: Configuration(), queue: JobQueue(store: InMemoryQueueStore()),
                handlers: [.handle(Greet.self) { _, _ in }, .handle(Greet.self) { _, _ in }])
        }
    }

    @Test("a disabled worker, or one limited to other queues, runs nothing")
    func disabledOrFiltered() throws {
        let queue = JobQueue(store: InMemoryQueueStore())
        let handlers: [QueueHandler] = [.handle(Greet.self) { _, _ in }]
        #expect(
            try AlulaQueueWorkerModule(
                configuration: Configuration(values: ["queue.worker.enabled": "false"]),
                queue: queue, handlers: handlers
            ).service == nil)
        #expect(
            try AlulaQueueWorkerModule(
                configuration: Configuration(values: ["queue.worker.only": "mail"]),
                queue: queue, handlers: handlers
            ).service == nil)
    }

    @Test("a non-positive setting is refused")
    func badSettings() {
        #expect(throws: QueueConfigurationError.self) {
            try QueueSettings(configuration: Configuration(values: ["queue.concurrency": "0"]))
        }
    }
}

@Suite("Retry policy")
struct RetryPolicyTests {
    @Test("doubles from the base and stops at the cap")
    func backoff() {
        let policy = RetryPolicy(base: .seconds(15), cap: .seconds(100), jitter: 0)
        #expect(policy.baseDelay(after: 1) == .seconds(15))
        #expect(policy.baseDelay(after: 2) == .seconds(30))
        #expect(policy.baseDelay(after: 3) == .seconds(60))
        #expect(policy.baseDelay(after: 4) == .seconds(100))
        #expect(policy.baseDelay(after: 60) == .seconds(100))
    }
}
