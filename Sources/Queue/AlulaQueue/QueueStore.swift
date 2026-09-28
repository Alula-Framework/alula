import Foundation

/// Identifies one enqueued job.
public struct QueuedJobID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// A job as it is written: already encoded, already scheduled.
public struct NewQueuedJob: Sendable, Equatable {
    public var id: QueuedJobID
    public var kind: String
    public var queue: String
    /// JSON.
    public var payload: Data
    /// Lower runs first. Default `0`.
    public var priority: Int
    /// Not claimed before this instant.
    public var runAt: Date
    public var maxAttempts: Int
    /// While a job with the same `kind` and `uniqueKey` is waiting or
    /// running, enqueueing another returns the existing one instead.
    public var uniqueKey: String?
    public var enqueuedAt: Date

    public init(
        id: QueuedJobID = QueuedJobID(), kind: String, queue: String, payload: Data,
        priority: Int = 0, runAt: Date, maxAttempts: Int, uniqueKey: String? = nil,
        enqueuedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.queue = queue
        self.payload = payload
        self.priority = priority
        self.runAt = runAt
        self.maxAttempts = maxAttempts
        self.uniqueKey = uniqueKey
        self.enqueuedAt = enqueuedAt
    }
}

/// What enqueueing did.
public enum EnqueueResult: Sendable, Equatable {
    case enqueued(QueuedJobID)
    /// A job with the same kind and unique key was already waiting or
    /// running; this is it, and nothing new was written.
    case duplicate(QueuedJobID)

    public var id: QueuedJobID {
        switch self {
        case .enqueued(let id), .duplicate(let id): id
        }
    }
}

/// A job a worker has claimed and now holds a lease on.
public struct ClaimedJob: Sendable, Equatable {
    public var id: QueuedJobID
    public var kind: String
    public var queue: String
    public var payload: Data
    /// This attempt, 1-based. Also the fencing token: completing, retrying or
    /// discarding names it, so a worker whose lease expired and was taken over
    /// cannot overwrite the new owner's result.
    public var attempt: Int
    public var maxAttempts: Int
    public var enqueuedAt: Date

    public init(
        id: QueuedJobID, kind: String, queue: String, payload: Data, attempt: Int,
        maxAttempts: Int, enqueuedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.queue = queue
        self.payload = payload
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.enqueuedAt = enqueuedAt
    }
}

/// How many jobs are in each state, for one queue.
public struct QueueCounts: Sendable, Equatable {
    /// Waiting, including those scheduled for later and those waiting to retry.
    public var available: Int
    public var running: Int
    public var completed: Int
    /// Out of attempts, or discarded by their handler: the dead letters.
    public var discarded: Int

    public init(available: Int = 0, running: Int = 0, completed: Int = 0, discarded: Int = 0) {
        self.available = available
        self.running = running
        self.completed = completed
        self.discarded = discarded
    }
}

/// Where jobs live between being enqueued and being done.
///
/// A job moves `available → running → completed`, or back to `available`
/// with a later `runAt` when it fails and has attempts left, or to
/// `discarded` when it has none. The contract an implementation must keep:
///
/// - **`claim` is atomic.** Two workers claiming concurrently never both get
///   one job. It takes `available` jobs whose `runAt` has passed *and*
///   `running` jobs whose lease has expired — a worker that died — ordered by
///   priority, then `runAt`. Each claim increments `attempt` and sets the
///   lease. It returns only the kinds asked for, so a worker never claims a
///   job it has no handler for (a rolling deploy adding a new kind).
/// - **Results are fenced by attempt.** `complete`, `retry` and `discard`
///   change the job only if it is still `running` at that attempt, and
///   report whether they did.
/// - **Uniqueness holds across processes** for jobs with a `uniqueKey` while
///   they are `available` or `running`.
///
/// Times are the application's clock, passed in, so a test can move them and
/// every implementation agrees on what "now" meant.
///
/// A method that cannot reach its backing store throws. The worker treats a
/// throw from `complete`, `retry` or `discard` as "not recorded": the job
/// stays `running` until its lease expires, then runs again.
public protocol QueueStore: Sendable {
    /// Writes `job` as `available`, or returns ``EnqueueResult/duplicate(_:)``
    /// with the live job it collides with on `kind` and `uniqueKey`.
    func enqueue(_ job: NewQueuedJob) async throws -> EnqueueResult

    /// Atomically takes up to `limit` due jobs of these `kinds` on `queue`,
    /// marking each `running` until `leaseUntil` at its next attempt.
    func claim(
        queue: String, kinds: Set<String>, limit: Int, now: Date, leaseUntil: Date
    ) async throws -> [ClaimedJob]

    /// Moves the leases of jobs still held at these attempts. Jobs whose
    /// attempt no longer matches are skipped: someone else holds them now.
    func extendLeases(_ jobs: [(id: QueuedJobID, attempt: Int)], until: Date) async throws

    /// To `completed`, if still `running` at `attempt`. Returns whether it was.
    @discardableResult
    func complete(_ id: QueuedJobID, attempt: Int, at: Date) async throws -> Bool

    /// Back to `available`, to be claimed again at `runAt`.
    @discardableResult
    func retry(_ id: QueuedJobID, attempt: Int, runAt: Date, error: String) async throws -> Bool

    /// To `discarded`: no further attempts.
    @discardableResult
    func discard(_ id: QueuedJobID, attempt: Int, at: Date, error: String) async throws -> Bool

    /// Back to `available`, due at `runAt`, *with the attempt given back*:
    /// the job was stopped at shutdown before it finished, which is not a
    /// failure of the job, so it must not use up one of its attempts. The
    /// next claim runs it at the same attempt number, even if that is its
    /// last. Fenced like ``retry(_:attempt:runAt:error:)``: only if still
    /// `running` at `attempt`.
    ///
    /// The default implementation calls ``retry(_:attempt:runAt:error:)``,
    /// which keeps the attempt spent — a job handed back on its final
    /// attempt is then discarded when next claimed. A store should
    /// implement this by decrementing the attempt in the same write.
    @discardableResult
    func handBack(_ id: QueuedJobID, attempt: Int, runAt: Date, error: String) async throws -> Bool

    func counts(queue: String) async throws -> QueueCounts

    /// Deletes completed jobs finished before `completedBefore` and discarded
    /// ones discarded before `discardedBefore`. Returns how many went.
    @discardableResult
    func prune(completedBefore: Date, discardedBefore: Date) async throws -> Int
}

extension QueueStore {
    public func handBack(_ id: QueuedJobID, attempt: Int, runAt: Date, error: String) async throws
        -> Bool
    {
        try await retry(id, attempt: attempt, runAt: runAt, error: error)
    }
}
