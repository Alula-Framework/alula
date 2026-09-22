import FlightSessions
import FlightSessionsTesting
import Foundation
import Synchronization
import Testing

/// A clock the test moves.
private final class TestClock: Sendable {
    private let storage: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_750_000_000)) {
        storage = Mutex(start)
    }

    var now: Date { storage.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        storage.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var nowProvider: @Sendable () -> Date {
        { self.now }
    }
}

@Suite("InMemorySessionStore")
struct InMemorySessionStoreTests {
    private let bytes = Data("record".utf8)

    @Test("a saved record loads until its TTL passes, then reads as absent and is dropped")
    func expiry() async throws {
        let clock = TestClock()
        let store = InMemorySessionStore(maxEntries: 10, now: clock.nowProvider)
        let id = SessionID.generate()
        try await store.save(id, bytes, ttl: .seconds(60))
        #expect(try await store.load(id) == bytes)

        clock.advance(by: 59)
        #expect(try await store.load(id) == bytes)
        clock.advance(by: 1)
        #expect(try await store.load(id) == nil)
        #expect(store.count == 0, "an expired entry is removed when loaded")
    }

    @Test("saving again refreshes the TTL")
    func refresh() async throws {
        let clock = TestClock()
        let store = InMemorySessionStore(maxEntries: 10, now: clock.nowProvider)
        let id = SessionID.generate()
        try await store.save(id, bytes, ttl: .seconds(60))
        clock.advance(by: 50)
        try await store.save(id, bytes, ttl: .seconds(60))
        clock.advance(by: 50)
        #expect(try await store.load(id) == bytes)
    }

    @Test("delete is idempotent")
    func delete() async throws {
        let store = InMemorySessionStore(maxEntries: 10)
        let id = SessionID.generate()
        try await store.save(id, bytes, ttl: .seconds(60))
        try await store.delete(id)
        try await store.delete(id)
        #expect(try await store.load(id) == nil)
    }

    @Test("past the bound, expired entries go before live ones")
    func boundSweepsExpiredFirst() async throws {
        let clock = TestClock()
        let store = InMemorySessionStore(maxEntries: 4, now: clock.nowProvider)
        let expired = (0..<3).map { _ in SessionID.generate() }
        for id in expired { try await store.save(id, bytes, ttl: .seconds(10)) }
        clock.advance(by: 20)
        let live = SessionID.generate()
        try await store.save(live, bytes, ttl: .seconds(60))
        // Four entries, at the bound; the fifth is over it.
        let fifth = SessionID.generate()
        try await store.save(fifth, bytes, ttl: .seconds(60))

        #expect(try await store.load(live) == bytes)
        #expect(try await store.load(fifth) == bytes)
        #expect(store.count == 2)
    }

    @Test("past the bound with nothing expired, the least recently loaded go")
    func boundEvictsLeastRecentlyLoaded() async throws {
        let clock = TestClock()
        let store = InMemorySessionStore(maxEntries: 4, now: clock.nowProvider)
        let ids = (0..<4).map { _ in SessionID.generate() }
        for id in ids {
            try await store.save(id, bytes, ttl: .seconds(600))
            clock.advance(by: 1)
        }
        // Touch the oldest so it is no longer the eviction candidate.
        _ = try await store.load(ids[0])
        clock.advance(by: 1)
        try await store.save(SessionID.generate(), bytes, ttl: .seconds(600))

        #expect(try await store.load(ids[0]) == bytes, "recently loaded survives")
        #expect(try await store.load(ids[1]) == nil, "the least recently loaded went")
        #expect(store.count <= 4)
    }

    @Test("deleting by owner ends only that owner's sessions, keeping the one asked")
    func deleteByOwner() async throws {
        let store = InMemorySessionStore()
        let (a1, a2, b) = (SessionID.generate(), SessionID.generate(), SessionID.generate())
        try await store.save(a1, Data("1".utf8), ttl: .seconds(60), owner: "ada")
        try await store.save(a2, Data("2".utf8), ttl: .seconds(60), owner: "ada")
        try await store.save(b, Data("3".utf8), ttl: .seconds(60), owner: "grace")
        #expect(try await store.deleteSessions(ownedBy: "ada", keeping: a1) == 1)
        #expect(try await store.load(a1) != nil)
        #expect(try await store.load(a2) == nil)
        #expect(try await store.load(b) != nil)
    }
}

@Suite("RecordingSessionStore")
struct RecordingSessionStoreTests {

    @Test("records every operation and serves what was saved")
    func records() async throws {
        let store = RecordingSessionStore()
        let id = SessionID.generate()
        let bytes = Data("r".utf8)
        #expect(try await store.load(id) == nil)
        try await store.save(id, bytes, ttl: .seconds(5))
        #expect(try await store.load(id) == bytes)
        try await store.delete(id)
        #expect(
            store.operations == [.load(id), .save(id, ttl: .seconds(5)), .load(id), .delete(id)])
        #expect(store.entryCount == 0)
    }

    @Test("misbehaving makes every call throw")
    func misbehave() async throws {
        let store = RecordingSessionStore()
        store.misbehave()
        await #expect(throws: SessionStoreError.self) {
            try await store.load(SessionID.generate())
        }
    }
}
