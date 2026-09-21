import FlightSessions
import Foundation
import Synchronization

/// A `SessionStore` that records every operation and serves from a plain
/// dictionary — for asserting what a request did to its session without a
/// real store. The analogue of `FlightCacheTesting.RecordingCache`.
///
/// `misbehave()` makes every subsequent call throw, which is what a downed
/// store looks like and is the path the middleware's 503 exists for.
public final class RecordingSessionStore: SessionStore, Sendable {
    public enum Operation: Sendable, Equatable {
        case load(SessionID)
        case save(SessionID, ttl: Duration)
        case delete(SessionID)
    }

    private struct State {
        var entries: [SessionID: (data: Data, ttl: Duration?)] = [:]
        var operations: [Operation] = []
        var misbehaving = false
    }

    private let state = Mutex<State>(State())

    public init() {}

    public func load(_ id: SessionID) async throws -> Data? {
        try state.withLock { state in
            state.operations.append(.load(id))
            guard !state.misbehaving else {
                throw SessionStoreError(operation: .load, reason: "store is misbehaving")
            }
            return state.entries[id]?.data
        }
    }

    public func save(_ id: SessionID, _ record: Data, ttl: Duration) async throws {
        try state.withLock { state in
            state.operations.append(.save(id, ttl: ttl))
            guard !state.misbehaving else {
                throw SessionStoreError(operation: .save, reason: "store is misbehaving")
            }
            state.entries[id] = (record, ttl)
        }
    }

    public func delete(_ id: SessionID) async throws {
        try state.withLock { state in
            state.operations.append(.delete(id))
            guard !state.misbehaving else {
                throw SessionStoreError(operation: .delete, reason: "store is misbehaving")
            }
            state.entries.removeValue(forKey: id)
        }
    }

    // MARK: - Seeding and inspection

    /// Stores a record directly, as if a previous request had saved it.
    public func seed(_ id: SessionID, record: SessionRecord) throws {
        let data = try record.encoded()
        state.withLock { $0.entries[id] = (data, nil) }
    }

    /// Stores raw bytes — for staging something that does not decode.
    public func seed(_ id: SessionID, data: Data) {
        state.withLock { $0.entries[id] = (data, nil) }
    }

    /// From now on, every call throws.
    public func misbehave() {
        state.withLock { $0.misbehaving = true }
    }

    public var operations: [Operation] {
        state.withLock { $0.operations }
    }

    /// The record under `id`, decoded; `nil` when nothing is stored there.
    public func record(for id: SessionID) throws -> SessionRecord? {
        guard let data = state.withLock({ $0.entries[id]?.data }) else { return nil }
        return try SessionRecord(decoding: data)
    }

    public func data(for id: SessionID) -> Data? {
        state.withLock { $0.entries[id]?.data }
    }

    /// The TTL the last `save` for `id` carried; `nil` when it was seeded
    /// rather than saved. Absent when nothing is stored there.
    public func ttl(for id: SessionID) -> Duration?? {
        state.withLock { $0.entries[id]?.ttl }
    }

    public var entryCount: Int {
        state.withLock { $0.entries.count }
    }

    /// Every id currently stored — for the common assertion that exactly
    /// one session exists and reading it without knowing its id.
    public var storedIDs: [SessionID] {
        state.withLock { Array($0.entries.keys) }
    }
}
