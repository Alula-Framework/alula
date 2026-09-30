import AlulaCore
import Foundation

/// `queue.*`, read once at composition.
///
/// ```yaml
/// queue:
///   concurrency: 10              # per queue, per process
///   poll-interval-ms: 1000       # how soon another process's enqueue is noticed
///   lease-seconds: 60            # how soon a dead worker's jobs are retried
///   retain-completed-hours: 24
///   retain-discarded-days: 14
///   queues:
///     reports:
///       concurrency: 2
///   worker:
///     enabled: true              # false on processes that only enqueue
///     only: mail, reports        # run just these queues here
/// ```
public struct QueueSettings: Sendable, Equatable {
    /// Jobs one process runs at once on each queue, unless the queue has its
    /// own in `perQueueConcurrency`.
    public var concurrency: Int
    /// Overrides of `concurrency` by queue name, from
    /// `queue.queues.<name>.concurrency`.
    public var perQueueConcurrency: [String: Int]
    /// How often an idle worker looks for due jobs. An enqueue in this
    /// process wakes the worker at once; this bounds how long a job enqueued
    /// by another process, or scheduled for later, waits to be noticed.
    public var pollInterval: Duration
    /// Renewed every third of itself while a job runs, so it bounds how long
    /// a crashed worker's jobs wait, not how long a job may take. A worker that
    /// cannot renew — its store unreachable for longer than this — keeps
    /// running the job, and another worker may claim and run it too; only the
    /// newer attempt's result is recorded.
    public var lease: Duration
    /// How long a completed job stays in the store before pruning deletes it.
    public var retainCompleted: Duration
    /// How long a discarded job (a dead letter) stays, with its error, before
    /// pruning deletes it.
    public var retainDiscarded: Duration
    /// False: this process enqueues but runs no jobs (`queue.worker.enabled`).
    public var workerEnabled: Bool
    /// Nil: every queue some handler names.
    public var onlyQueues: Set<String>?

    /// Settings built in code. Each default is the one
    /// ``init(configuration:queues:)`` uses for an absent key.
    public init(
        concurrency: Int = 10, perQueueConcurrency: [String: Int] = [:],
        pollInterval: Duration = .seconds(1), lease: Duration = .seconds(60),
        retainCompleted: Duration = .seconds(24 * 3600),
        retainDiscarded: Duration = .seconds(14 * 24 * 3600), workerEnabled: Bool = true,
        onlyQueues: Set<String>? = nil
    ) {
        self.concurrency = concurrency
        self.perQueueConcurrency = perQueueConcurrency
        self.pollInterval = pollInterval
        self.lease = lease
        self.retainCompleted = retainCompleted
        self.retainDiscarded = retainDiscarded
        self.workerEnabled = workerEnabled
        self.onlyQueues = onlyQueues
    }

    /// Reads `queue.*`. Per-queue concurrency is read for `queues`, the ones
    /// handlers name, since configuration cannot be enumerated.
    public init(configuration: Configuration, queues: Set<String> = []) throws {
        func positive(_ key: String, _ fallback: Int) throws -> Int {
            try configuration.positive(
                key, orThrow: { QueueConfigurationError(key: $0.key, value: $0.value) })
                ?? fallback
        }
        let concurrency = try positive("queue.concurrency", 10)
        var perQueue: [String: Int] = [:]
        for queue in queues {
            let key = "queue.queues.\(queue).concurrency"
            if try configuration.getIfPresent(key, as: Int.self) != nil {
                perQueue[queue] = try positive(key, concurrency)
            }
        }
        let only = try configuration.getIfPresent("queue.worker.only", as: String.self)
            .map { raw in
                Set(
                    raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty })
            }
        self.init(
            concurrency: concurrency, perQueueConcurrency: perQueue,
            pollInterval: .milliseconds(try positive("queue.poll-interval-ms", 1000)),
            lease: .seconds(try positive("queue.lease-seconds", 60)),
            retainCompleted: .seconds(try positive("queue.retain-completed-hours", 24) * 3600),
            retainDiscarded: .seconds(try positive("queue.retain-discarded-days", 14) * 86400),
            workerEnabled: try configuration.getIfPresent("queue.worker.enabled", as: Bool.self)
                ?? true,
            onlyQueues: only)
    }

    /// Jobs one process runs at once on `queue`: its own override, or
    /// `concurrency`.
    public func concurrency(of queue: String) -> Int {
        perQueueConcurrency[queue] ?? concurrency
    }
}

/// A `queue.*` value that is not a positive whole number. Thrown at
/// composition, so the application does not start.
public struct QueueConfigurationError: Error, Sendable, CustomStringConvertible {
    /// The offending key, such as `queue.concurrency`.
    public let key: String
    /// The value as configured.
    public let value: String
    /// Names the key, the rule and the value.
    public var description: String { "\(key) must be a positive whole number; it is \(value)" }
}

extension QueueConfigurationError: ModuleConfigurationError {}
