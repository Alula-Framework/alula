import Foundation
import Logging

/// What one attempt came to.
public enum QueueAttemptOutcome: Sendable, Equatable {
    case completed
    /// Failed with attempts left; runs again at this instant.
    case retrying(at: Date, error: String)
    /// Failed for good — out of attempts, a ``DiscardJob``, an undecodable
    /// payload, or no handler at all.
    case discarded(reason: String)
    /// The store no longer had this attempt running — its lease expired and
    /// another worker took it — so this result was not recorded.
    case superseded
}

/// Runs one claimed job and records the result. The worker uses it for every
/// attempt; tests use it to run jobs deterministically.
public struct QueueRunner: Sendable {
    let store: any QueueStore
    let now: @Sendable () -> Date
    let logger: Logger

    public init(
        store: any QueueStore, now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(label: "alula.queue")
    ) {
        self.store = store
        self.now = now
        self.logger = logger
    }

    /// Runs `job` with `handler` (nil when this process has none for it) and
    /// records what happened.
    public func run(_ job: ClaimedJob, handler: QueueHandler?) async -> QueueAttemptOutcome {
        var logger = logger
        logger[metadataKey: "job-id"] = "\(job.id)"
        logger[metadataKey: "job-kind"] = "\(job.kind)"
        logger[metadataKey: "attempt"] = "\(job.attempt)"

        // Claimed back from a worker that died holding its last attempt: the
        // attempt was spent, so there is nothing left to try.
        guard job.attempt <= job.maxAttempts else {
            return await record(
                .discarded(
                    reason: "its final attempt was lost when the worker running it stopped"),
                job, logger)
        }
        guard let handler else {
            return await record(
                .discarded(reason: "no handler for kind \(job.kind)"), job, logger)
        }

        let context = QueueJobContext(
            id: job.id, attempt: job.attempt, maxAttempts: job.maxAttempts,
            enqueuedAt: job.enqueuedAt, logger: logger)
        do {
            try await Self.perform(handler, payload: job.payload, context: context)
            return await record(.completed, job, logger)
        } catch let discard as DiscardJob {
            return await record(.discarded(reason: discard.reason), job, logger)
        } catch {
            let message = String(describing: error)
            if job.attempt >= job.maxAttempts {
                return await record(
                    .discarded(reason: "out of attempts; last error: \(message)"), job, logger)
            }
            var random = SystemRandomNumberGenerator()
            let delay = handler.retry.delay(after: job.attempt, using: &random)
            return await record(
                .retrying(at: now().addingTimeInterval(delay.queueSeconds), error: message),
                job, logger)
        }
    }

    private static func perform(
        _ handler: QueueHandler, payload: Data, context: QueueJobContext
    ) async throws {
        guard let timeout = handler.timeout else {
            try await handler.perform(payload, context)
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await handler.perform(payload, context) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw QueueJobTimedOut(timeout: timeout)
            }
            // The first to finish decides; a handler that ignores cancellation
            // still has to return before this does.
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func record(_ outcome: QueueAttemptOutcome, _ job: ClaimedJob, _ logger: Logger) async
        -> QueueAttemptOutcome
    {
        do {
            let recorded: Bool
            switch outcome {
            case .completed:
                recorded = try await store.complete(job.id, attempt: job.attempt, at: now())
                logger.debug("job completed")
            case .retrying(let at, let error):
                recorded = try await store.retry(
                    job.id, attempt: job.attempt, runAt: at, error: error)
                logger.warning(
                    "job failed; will retry",
                    metadata: ["error": "\(error)", "retry-at": "\(at)"])
            case .discarded(let reason):
                recorded = try await store.discard(
                    job.id, attempt: job.attempt, at: now(), error: reason)
                logger.error("job discarded", metadata: ["reason": "\(reason)"])
            case .superseded:
                return .superseded
            }
            if !recorded {
                logger.warning(
                    "job result not recorded: its lease expired and another worker holds it")
                return .superseded
            }
        } catch {
            // The lease will expire and the job will be claimed again, so a
            // store failure here costs a repeat, never the job.
            logger.error(
                "could not record job result; it will run again when its lease expires",
                metadata: ["error": "\(error)"])
        }
        return outcome
    }
}
