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
    public var concurrency: Int
    public var perQueueConcurrency: [String: Int]
    public var pollInterval: Duration
    /// Renewed every third of itself while a job runs, so it bounds how long
    /// a crashed worker's jobs wait, not how long a job may take.
    public var lease: Duration
    public var retainCompleted: Duration
    public var retainDiscarded: Duration
    public var workerEnabled: Bool
    /// Nil: every queue some handler names.
    public var onlyQueues: Set<String>?

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
            let value = try configuration.getIfPresent(key, as: Int.self) ?? fallback
            guard value > 0 else { throw QueueConfigurationError(key: key, value: "\(value)") }
            return value
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

    public func concurrency(of queue: String) -> Int {
        perQueueConcurrency[queue] ?? concurrency
    }
}

public struct QueueConfigurationError: Error, Sendable, CustomStringConvertible {
    public let key: String
    public let value: String
    public var description: String { "\(key) must be a positive whole number; it is \(value)" }
}
