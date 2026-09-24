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
public protocol QueueStore: Sendable {
    func enqueue(_ job: NewQueuedJob) async throws -> EnqueueResult

    func claim(
        queue: String, kinds: Set<String>, limit: Int, now: Date, leaseUntil: Date
    ) async throws -> [ClaimedJob]

    /// Moves the leases of jobs still held at these attempts. Jobs whose
    /// attempt no longer matches are skipped: someone else holds them now.
    func extendLeases(_ jobs: [(id: QueuedJobID, attempt: Int)], until: Date) async throws

    @discardableResult
    func complete(_ id: QueuedJobID, attempt: Int, at: Date) async throws -> Bool

    /// Back to `available`, to be claimed again at `runAt`.
    @discardableResult
    func retry(_ id: QueuedJobID, attempt: Int, runAt: Date, error: String) async throws -> Bool

    /// To `discarded`: no further attempts.
    @discardableResult
    func discard(_ id: QueuedJobID, attempt: Int, at: Date, error: String) async throws -> Bool

    func counts(queue: String) async throws -> QueueCounts

    /// Deletes completed jobs finished before `completedBefore` and discarded
    /// ones discarded before `discardedBefore`. Returns how many went.
    @discardableResult
    func prune(completedBefore: Date, discardedBefore: Date) async throws -> Int
}
