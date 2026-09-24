import AlulaQueue
import Foundation
import Synchronization

/// Runs queued jobs on demand, on a clock the test moves.
///
/// ```swift
/// let harness = QueueTestHarness(handlers: [
///     .handle(SendWelcomeEmail.self) { job, _ in mailer.sent.append(job.userID) },
/// ])
/// let service = SignupService(jobs: harness.queue)
/// try await service.signUp(form)
///
/// let outcomes = await harness.drain()
/// #expect(outcomes == [.completed])
/// ```
///
/// No worker, no polling, no sleeping: `drain()` runs every job that is due,
/// in the order a worker would, until none is. A retry is due only once the
/// test has advanced the clock past it.
public final class QueueTestHarness: Sendable {
    public let store: InMemoryQueueStore
    public let queue: JobQueue
    private let handlers: [String: QueueHandler]
    private let clock: TestClock

    private final class TestClock: Sendable {
        let value: Mutex<Date>
        init(_ start: Date) { value = Mutex(start) }
        var now: Date { value.withLock { $0 } }
    }

    public init(
        handlers: [QueueHandler] = [], start: Date = Date(timeIntervalSince1970: 1_000_000_000)
    ) {
        let clock = TestClock(start)
        let store = InMemoryQueueStore()
        self.clock = clock
        self.store = store
        self.handlers = Dictionary(
            handlers.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        self.queue = JobQueue(store: store, now: { clock.now })
    }

    public var now: Date { clock.now }

    public func advance(by duration: Duration) {
        let (seconds, attoseconds) = duration.components
        clock.value.withLock {
            $0 = $0.addingTimeInterval(Double(seconds) + Double(attoseconds) / 1e18)
        }
    }

    /// Runs every due job, one at a time, until none is due. Returns each
    /// attempt's outcome in order.
    @discardableResult
    public func drain(limit: Int = 1000) async -> [QueueAttemptOutcome] {
        let runner = QueueRunner(store: store, now: { [clock] in clock.now })
        let queues = Set(handlers.values.map(\.queue))
        let kinds = Set(handlers.keys)
        var outcomes: [QueueAttemptOutcome] = []
        while outcomes.count < limit {
            var ranOne = false
            for name in queues.sorted() {
                let at = now
                guard
                    let job = try? await store.claim(
                        queue: name, kinds: kinds, limit: 1, now: at,
                        leaseUntil: at.addingTimeInterval(60)
                    ).first
                else { continue }
                outcomes.append(await runner.run(job, handler: handlers[job.kind]))
                ranOne = true
            }
            if !ranOne { break }
        }
        return outcomes
    }

    /// How many jobs are in each state on `queue`.
    public func counts(queue name: String = "default") async -> QueueCounts {
        (try? await store.counts(queue: name)) ?? QueueCounts()
    }
}
