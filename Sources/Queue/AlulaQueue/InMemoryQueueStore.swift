import Foundation
import Synchronization

/// A ``QueueStore`` in this process's memory.
///
/// **Not durable.** Jobs are gone when the process exits, and a second
/// process has its own. That is right for development and tests and wrong
/// for anything whose work must survive a deploy — which is why
/// ``AlulaQueueModule`` warns when it falls back to this outside development.
/// alula-data's `PostgresQueueStore` is the durable one.
///
/// It keeps the full ``QueueStore`` contract (atomic claim, lease expiry,
/// attempt fencing, uniqueness), so behaviour tested against it holds against
/// a durable store.
public final class InMemoryQueueStore: QueueStore {
    enum State: Sendable, Equatable {
        case available
        case running(leaseUntil: Date)
        case completed(at: Date)
        case discarded(at: Date)
    }

    struct Entry: Sendable {
        var job: NewQueuedJob
        var state: State
        var attempt: Int = 0
        var lastError: String?
    }

    private let entries = Mutex<[QueuedJobID: Entry]>([:])

    public init() {}

    public func enqueue(_ job: NewQueuedJob) async throws -> EnqueueResult {
        entries.withLock { entries in
            if let key = job.uniqueKey,
                let existing = entries.values.first(where: {
                    $0.job.kind == job.kind && $0.job.uniqueKey == key && $0.isLive
                })
            {
                return .duplicate(existing.job.id)
            }
            entries[job.id] = Entry(job: job, state: .available)
            return .enqueued(job.id)
        }
    }

    public func claim(
        queue: String, kinds: Set<String>, limit: Int, now: Date, leaseUntil: Date
    ) async throws -> [ClaimedJob] {
        guard limit > 0 else { return [] }
        return entries.withLock { entries in
            let due = entries.values
                .filter { entry in
                    guard entry.job.queue == queue, kinds.contains(entry.job.kind) else {
                        return false
                    }
                    switch entry.state {
                    case .available: return entry.job.runAt <= now
                    case .running(let lease): return lease < now
                    case .completed, .discarded: return false
                    }
                }
                .sorted {
                    ($0.job.priority, $0.job.runAt, $0.job.id.rawValue.uuidString)
                        < ($1.job.priority, $1.job.runAt, $1.job.id.rawValue.uuidString)
                }
                .prefix(limit)
            return due.map { entry in
                var claimed = entry
                claimed.attempt += 1
                claimed.state = .running(leaseUntil: leaseUntil)
                entries[entry.job.id] = claimed
                return ClaimedJob(
                    id: claimed.job.id, kind: claimed.job.kind, queue: claimed.job.queue,
                    payload: claimed.job.payload, attempt: claimed.attempt,
                    maxAttempts: claimed.job.maxAttempts, enqueuedAt: claimed.job.enqueuedAt)
            }
        }
    }

    public func extendLeases(_ jobs: [(id: QueuedJobID, attempt: Int)], until: Date) async throws {
        entries.withLock { entries in
            for (id, attempt) in jobs {
                guard var entry = entries[id], entry.attempt == attempt,
                    case .running = entry.state
                else { continue }
                entry.state = .running(leaseUntil: until)
                entries[id] = entry
            }
        }
    }

    public func complete(_ id: QueuedJobID, attempt: Int, at: Date) async throws -> Bool {
        transition(id, attempt: attempt) { $0.state = .completed(at: at) }
    }

    public func retry(_ id: QueuedJobID, attempt: Int, runAt: Date, error: String) async throws
        -> Bool
    {
        transition(id, attempt: attempt) {
            $0.state = .available
            $0.job.runAt = runAt
            $0.lastError = error
        }
    }

    public func discard(_ id: QueuedJobID, attempt: Int, at: Date, error: String) async throws
        -> Bool
    {
        transition(id, attempt: attempt) {
            $0.state = .discarded(at: at)
            $0.lastError = error
        }
    }

    public func counts(queue: String) async throws -> QueueCounts {
        entries.withLock { entries in
            var counts = QueueCounts()
            for entry in entries.values where entry.job.queue == queue {
                switch entry.state {
                case .available: counts.available += 1
                case .running: counts.running += 1
                case .completed: counts.completed += 1
                case .discarded: counts.discarded += 1
                }
            }
            return counts
        }
    }

    public func prune(completedBefore: Date, discardedBefore: Date) async throws -> Int {
        entries.withLock { entries in
            let doomed = entries.values.filter {
                switch $0.state {
                case .completed(let at): at < completedBefore
                case .discarded(let at): at < discardedBefore
                case .available, .running: false
                }
            }
            for entry in doomed { entries[entry.job.id] = nil }
            return doomed.count
        }
    }

    /// The last error recorded for a job, for tests and inspection.
    public func lastError(of id: QueuedJobID) -> String? {
        entries.withLock { $0[id]?.lastError }
    }

    /// When a job is next due, while it is waiting.
    public func runAt(of id: QueuedJobID) -> Date? {
        entries.withLock { entries in
            guard let entry = entries[id], case .available = entry.state else { return nil }
            return entry.job.runAt
        }
    }

    private func transition(_ id: QueuedJobID, attempt: Int, _ change: (inout Entry) -> Void)
        -> Bool
    {
        entries.withLock { entries in
            guard var entry = entries[id], entry.attempt == attempt, case .running = entry.state
            else { return false }
            change(&entry)
            entries[id] = entry
            return true
        }
    }
}

extension InMemoryQueueStore.Entry {
    var isLive: Bool {
        switch state {
        case .available, .running: true
        case .completed, .discarded: false
        }
    }
}
