import Foundation
import Logging

/// What a handler is told about the attempt it is running.
public struct QueueJobContext: Sendable {
    public let id: QueuedJobID
    /// 1-based.
    public let attempt: Int
    public let maxAttempts: Int
    public let enqueuedAt: Date
    /// Carries `job-id`, `job-kind` and `attempt` metadata.
    public let logger: Logger

    public init(id: QueuedJobID, attempt: Int, maxAttempts: Int, enqueuedAt: Date, logger: Logger) {
        self.id = id
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.enqueuedAt = enqueuedAt
        self.logger = logger
    }

    /// Whether a failure now is final.
    public var isFinalAttempt: Bool { attempt >= maxAttempts }
}

/// How one kind of job is run: the code, with whatever it closes over.
///
/// Handlers are contributions. Any module holding `queueHandlers:
/// [QueueHandler]` adds to the worker, built from the component graph so a
/// handler can use the application's services:
///
/// ```swift
/// struct AppModule: AlulaModule {
///     let queueHandlers: [QueueHandler]
///
///     init(graph: AlulaGraph) {
///         queueHandlers = [
///             .handle(SendWelcomeEmail.self) { job, context in
///                 try await graph.mailer.sendWelcome(to: job.userID)
///             },
///         ]
///     }
/// }
/// ```
///
/// A handler that throws is retried under its job's ``RetryPolicy``; one that
/// throws ``DiscardJob`` is not. A payload that no longer decodes — a field
/// renamed with jobs in flight — is discarded rather than retried, since no
/// number of attempts will change it.
public struct QueueHandler: Sendable {
    public let kind: String
    public let queue: String
    public let retry: RetryPolicy
    /// How long one attempt may run before it counts as a failure. Nil is no
    /// limit — but a hung attempt then holds a worker slot, and its lease is
    /// renewed, for as long as it hangs.
    public let timeout: Duration?
    let perform: @Sendable (Data, QueueJobContext) async throws -> Void

    /// A handler for `Job`.
    public static func handle<Job: QueuedJob>(
        _ job: Job.Type, timeout: Duration? = .seconds(300),
        _ body: @escaping @Sendable (Job, QueueJobContext) async throws -> Void
    ) -> QueueHandler {
        QueueHandler(
            kind: Job.kind, queue: Job.queue, retry: Job.retry, timeout: timeout
        ) { payload, context in
            let decoded: Job
            do {
                decoded = try QueueCoding.decoder.decode(Job.self, from: payload)
            } catch {
                throw DiscardJob("payload does not decode as \(Job.self): \(error)")
            }
            try await body(decoded, context)
        }
    }

    init(
        kind: String, queue: String, retry: RetryPolicy, timeout: Duration?,
        perform: @escaping @Sendable (Data, QueueJobContext) async throws -> Void
    ) {
        self.kind = kind
        self.queue = queue
        self.retry = retry
        self.timeout = timeout
        self.perform = perform
    }
}

struct QueueJobTimedOut: Error, CustomStringConvertible {
    let timeout: Duration
    var description: String { "attempt exceeded its timeout of \(timeout)" }
}
