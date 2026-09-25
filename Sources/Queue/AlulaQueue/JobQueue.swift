import Foundation
import Synchronization

/// How one job is enqueued, beyond what its type says.
public struct EnqueueOptions: Sendable, Equatable {
    /// Not before this long from now. Ignored when `runAt` is set.
    public var delay: Duration?
    /// Not before this instant.
    public var runAt: Date?
    /// Lower runs first. Default `0`.
    public var priority: Int
    /// While a job of this kind with this key is waiting or running, another
    /// enqueue returns it instead of adding one: "send the digest for room 7"
    /// enqueued by three events becomes one job.
    public var uniqueKey: String?
    /// Overrides the type's queue.
    public var queue: String?
    /// Overrides the type's `RetryPolicy.maxAttempts`.
    public var maxAttempts: Int?

    public init(
        delay: Duration? = nil, runAt: Date? = nil, priority: Int = 0, uniqueKey: String? = nil,
        queue: String? = nil, maxAttempts: Int? = nil
    ) {
        self.delay = delay
        self.runAt = runAt
        self.priority = priority
        self.uniqueKey = uniqueKey
        self.queue = queue
        self.maxAttempts = maxAttempts
    }
}

/// Enqueues background work. Inject it wherever work is handed off:
///
/// ```swift
/// @Component struct SignupService {
///     @Inject var jobs: JobQueue
///
///     func signUp(_ form: SignupForm) async throws {
///         let user = try await users.create(form)
///         try await jobs.enqueue(SendWelcomeEmail(userID: user.id))
///     }
/// }
/// ```
///
/// ``AlulaQueueModule`` provides it. Enqueueing writes to the store and
/// returns; a worker — in this process or another — runs the job.
public struct JobQueue: Sendable {
    public let store: any QueueStore
    let now: @Sendable () -> Date
    let wake: QueueWakeup

    public init(store: any QueueStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(store: store, now: now, wake: QueueWakeup())
    }

    init(store: any QueueStore, now: @escaping @Sendable () -> Date, wake: QueueWakeup) {
        self.store = store
        self.now = now
        self.wake = wake
    }

    /// Adds `job` to its queue.
    @discardableResult
    public func enqueue<Job: QueuedJob>(_ job: Job, options: EnqueueOptions = EnqueueOptions())
        async throws -> EnqueueResult
    {
        let prepared = try prepare(job, options: options)
        let result = try await store.enqueue(prepared)
        QueueTelemetry.enqueued(kind: prepared.kind, queue: prepared.queue)
        wake.signal(Job.self)
        return result
    }

    /// `job` encoded and scheduled, ready for a store — for a store that can
    /// write it inside the caller's own database transaction, so the job
    /// exists exactly when the change that caused it does.
    public func prepare<Job: QueuedJob>(_ job: Job, options: EnqueueOptions = EnqueueOptions())
        throws -> NewQueuedJob
    {
        try Self.prepare(job, options: options, now: now())
    }

    /// `prepare` without a queue: for code that writes jobs with no
    /// ``JobQueue`` at hand.
    public static func prepare<Job: QueuedJob>(
        _ job: Job, options: EnqueueOptions = EnqueueOptions(), now: Date = Date()
    ) throws -> NewQueuedJob {
        let runAt = options.runAt ?? now.addingTimeInterval(options.delay?.queueSeconds ?? 0)
        return NewQueuedJob(
            kind: Job.kind, queue: options.queue ?? Job.queue,
            payload: try QueueCoding.encoder.encode(job), priority: options.priority,
            runAt: runAt, maxAttempts: options.maxAttempts ?? Job.retry.maxAttempts,
            uniqueKey: options.uniqueKey, enqueuedAt: now)
    }
}

enum QueueCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Lets an enqueue in this process wake this process's idle worker at once,
/// instead of after its next poll. Another process's enqueue still waits for
/// the poll; that is what the poll is for.
///
/// One waiter per queue — the worker loop for it. A signal with nobody
/// waiting is remembered, so an enqueue that lands between a claim finding
/// nothing and the loop starting to wait is not lost.
final class QueueWakeup: Sendable {
    private struct Slot {
        var pending = false
        var waiter: (id: UInt64, continuation: CheckedContinuation<Void, Never>)?
    }
    private struct State {
        var slots: [String: Slot] = [:]
        var nextID: UInt64 = 0
    }
    private let state = Mutex(State())

    func signal(_ job: (some QueuedJob).Type) {
        signal(queue: job.queue)
    }

    func signal(queue: String) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if let waiter = state.slots[queue]?.waiter {
                state.slots[queue]?.waiter = nil
                return waiter.continuation
            }
            state.slots[queue, default: Slot()].pending = true
            return nil
        }
        waiter?.resume()
    }

    /// Returns after `timeout`, when `queue` is signalled, or when the caller
    /// is cancelled — whichever is first.
    func wait(queue: String, timeout: Duration) async {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediately = state.withLock { state -> Bool in
                    if state.slots[queue]?.pending == true {
                        state.slots[queue]?.pending = false
                        return true
                    }
                    if Task.isCancelled { return true }
                    state.slots[queue, default: Slot()].waiter = (id, continuation)
                    return false
                }
                if immediately {
                    continuation.resume()
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.release(queue: queue, id: id)
                }
            }
        } onCancel: {
            release(queue: queue, id: id)
        }
    }

    private func release(queue: String, id: UInt64) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.slots[queue]?.waiter, waiter.id == id else { return nil }
            state.slots[queue]?.waiter = nil
            return waiter.continuation
        }
        waiter?.resume()
    }
}
