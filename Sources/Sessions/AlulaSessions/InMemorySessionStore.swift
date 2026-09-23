import Foundation
import Synchronization

/// The default store: a bounded dictionary with TTL expiry.
///
/// Right for one replica, for development, and for tests, with its limits
/// stated plainly: not shared across instances, and lost on restart. A
/// deployment with two replicas behind a load balancer needs the Valkey
/// store from alula-data, and configuring that store's URL without listing
/// its module is refused at startup for exactly that reason.
///
/// Bounded by default — an unbounded session store is a memory leak that
/// every anonymous visitor who logs in adds to. Expiry is lazy: an expired
/// entry is dropped when loaded, and swept when the bound is reached. Past
/// the bound the least recently loaded entries go, in batches, so the cost
/// of bounding is paid once per batch rather than once per save.
public final class InMemorySessionStore: OwnerIndexedSessionStore, Sendable {
    public static let defaultMaxEntries = 100_000

    private struct Entry {
        var data: Data
        var expiresAt: Date
        var lastAccess: Date
        var owner: String?
    }

    private let entries = Mutex<[SessionID: Entry]>([:])
    private let now: @Sendable () -> Date
    public let maxEntries: Int

    /// - Parameters:
    ///   - maxEntries: The bound. Positive, or a programming error.
    ///   - now: The clock, injectable so expiry is testable without sleeping.
    public init(
        maxEntries: Int = InMemorySessionStore.defaultMaxEntries,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(
            maxEntries > 0,
            "InMemorySessionStore is bounded by design — maxEntries must be positive.")
        self.maxEntries = maxEntries
        self.now = now
    }

    public func load(_ id: SessionID) async throws -> Data? {
        let now = now()
        return entries.withLock { entries in
            guard let entry = entries[id] else { return nil }
            guard entry.expiresAt > now else {
                entries.removeValue(forKey: id)
                return nil
            }
            entries[id]!.lastAccess = now
            return entry.data
        }
    }

    public func save(_ id: SessionID, _ record: Data, ttl: Duration) async throws {
        try await save(id, record, ttl: ttl, owner: nil)
    }

    public func save(_ id: SessionID, _ record: Data, ttl: Duration, owner: String?) async throws {
        let now = now()
        entries.withLock { entries in
            entries[id] = Entry(
                data: record, expiresAt: now.addingTimeInterval(ttl.timeInterval), lastAccess: now,
                owner: owner)
            enforceBound(&entries, now: now)
        }
    }

    /// A scan, not an index: in one process, bounded, and run rarely — at a
    /// password change or an account being disabled — it is cheaper than
    /// keeping a second map consistent on every save.
    @discardableResult
    public func deleteSessions(ownedBy owner: String, keeping: SessionID?) async throws -> Int {
        entries.withLock { entries in
            let doomed = entries.filter { $0.value.owner == owner && $0.key != keeping }.map(\.key)
            for id in doomed { entries.removeValue(forKey: id) }
            return doomed.count
        }
    }

    public func delete(_ id: SessionID) async throws {
        entries.withLock { _ = $0.removeValue(forKey: id) }
    }

    /// Live entries, expired ones included until loaded or swept —
    /// introspection for tests.
    public var count: Int {
        entries.withLock { $0.count }
    }

    /// Runs under the lock. Expired entries go first; if that is not enough,
    /// the least recently loaded go in a batch of a sixteenth of the bound,
    /// so the O(n log n) sort is paid once per batch.
    private func enforceBound(_ entries: inout [SessionID: Entry], now: Date) {
        guard entries.count > maxEntries else { return }
        for (id, entry) in entries where entry.expiresAt <= now {
            entries.removeValue(forKey: id)
        }
        guard entries.count > maxEntries else { return }
        let excess = entries.count - maxEntries + max(1, maxEntries / 16)
        let oldest = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }.prefix(excess)
        for (id, _) in oldest {
            entries.removeValue(forKey: id)
        }
    }
}
