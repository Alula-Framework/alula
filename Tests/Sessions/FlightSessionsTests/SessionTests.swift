import FlightSessions
import Foundation
import Testing

@Suite("Session")
struct SessionTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let ttl: Duration = .seconds(3600)

    private struct Cart: Codable, Equatable {
        var items: [String]
    }

    /// A session as the middleware would load it: stored a while ago, with
    /// plenty of TTL left.
    private func loaded(
        values: [String: Data] = [:], flash: [String: Data] = [:],
        expiresIn: Duration? = nil
    ) -> (id: SessionID, session: Session) {
        let id = SessionID.generate()
        let record = SessionRecord(
            values: values, flash: flash,
            createdAt: now.addingTimeInterval(-600),
            expiresAt: now.addingTimeInterval((expiresIn ?? ttl).timeIntervalForTest))
        return (id, Session(id: id, record: record))
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    // MARK: Fresh sessions

    @Test("a fresh session nothing was written to commits to nothing")
    func freshUntouched() {
        let session = Session()
        #expect(session.isNew)
        #expect(session.id == nil)
        #expect(session.commit(now: now, ttl: ttl) == .nothing)
    }

    @Test("a fresh session with a value is saved under a new id")
    func freshWritten() throws {
        let session = Session()
        try session.set("cart", Cart(items: ["apple"]))
        guard case .save(let id, let record, let replacing) = session.commit(now: now, ttl: ttl)
        else {
            Issue.record("expected a save")
            return
        }
        #expect(replacing == nil)
        #expect(session.id == id, "the id is readable once assigned")
        #expect(record.values["cart"] == (try encoded(Cart(items: ["apple"]))))
        #expect(record.createdAt == now)
        #expect(record.expiresAt == now.addingTimeInterval(3600))
        #expect(record.flash.isEmpty)
    }

    @Test("set then remove leaves nothing to store")
    func setThenRemove() throws {
        let session = Session()
        try session.set("k", 1)
        session.remove("k")
        #expect(session.commit(now: now, ttl: ttl) == .nothing)
    }

    @Test("a fresh session destroyed before it was ever stored commits to nothing")
    func destroyFresh() throws {
        let session = Session()
        try session.set("k", 1)
        session.destroy()
        #expect(session.isDestroyed)
        #expect(session.commit(now: now, ttl: ttl) == .nothing)
    }

    // MARK: Loaded sessions

    @Test("a loaded session left alone with most of its life left is not written")
    func loadedUntouched() throws {
        let (_, session) = loaded(values: ["k": try encoded(1)])
        #expect(!session.isNew)
        #expect(try session.get("k", as: Int.self) == 1)
        #expect(session.commit(now: now, ttl: ttl) == .nothing)
    }

    @Test("a loaded session past half its life is renewed as-is")
    func slidingRenewal() throws {
        let (id, session) = loaded(values: ["k": try encoded(1)], expiresIn: .seconds(1700))
        guard
            case .save(let savedID, let record, let replacing) = session.commit(now: now, ttl: ttl)
        else {
            Issue.record("expected a renewing save")
            return
        }
        #expect(savedID == id)
        #expect(replacing == nil)
        #expect(record.values["k"] == (try encoded(1)))
        #expect(record.expiresAt == now.addingTimeInterval(3600), "renewed for a full TTL")
        #expect(record.createdAt == now.addingTimeInterval(-600), "creation is preserved")
    }

    @Test("just over half its life left is not yet renewed")
    func notYetDue() throws {
        let (_, session) = loaded(values: ["k": try encoded(1)], expiresIn: .seconds(1801))
        #expect(session.commit(now: now, ttl: ttl) == .nothing)
    }

    @Test("setting what is already there is not a modification")
    func sameBytes() throws {
        let (_, session) = loaded(values: ["cart": try encoded(Cart(items: ["a"]))])
        try session.set("cart", Cart(items: ["a"]))
        #expect(session.commit(now: now, ttl: ttl) == .nothing)
    }

    @Test("a modified session is saved under the same id")
    func modified() throws {
        let (id, session) = loaded(values: ["k": try encoded(1)])
        try session.set("k", 2)
        guard
            case .save(let savedID, let record, let replacing) = session.commit(now: now, ttl: ttl)
        else {
            Issue.record("expected a save")
            return
        }
        #expect(savedID == id)
        #expect(replacing == nil)
        #expect(record.values["k"] == (try encoded(2)))
    }

    @Test("regenerate moves the values under a new id and names the old one for deletion")
    func regenerate() throws {
        let (old, session) = loaded(values: ["user": try encoded("ada")])
        session.regenerate()
        guard case .save(let newID, let record, let replacing) = session.commit(now: now, ttl: ttl)
        else {
            Issue.record("expected a save")
            return
        }
        #expect(newID != old)
        #expect(replacing == old)
        #expect(record.values["user"] == (try encoded("ada")))
        #expect(session.id == newID)
    }

    @Test("removing the last value deletes the session rather than storing it empty")
    func emptied() throws {
        let (id, session) = loaded(values: ["k": try encoded(1)])
        session.remove("k")
        #expect(session.isEmpty)
        #expect(session.commit(now: now, ttl: ttl) == .delete(id))
    }

    @Test("destroy deletes a loaded session and discards later writes")
    func destroyLoaded() throws {
        let (id, session) = loaded(values: ["k": try encoded(1)])
        session.destroy()
        try session.set("after", true)
        #expect(session.commit(now: now, ttl: ttl) == .delete(id))
    }

    // MARK: Flash

    @Test("flash written now is stored for the next request, not readable in this one")
    func flashWrite() throws {
        let session = Session()
        try session.flash("notice", "Saved.")
        #expect(try session.flashed("notice", as: String.self) == nil)
        guard case .save(_, let record, _) = session.commit(now: now, ttl: ttl) else {
            Issue.record("expected a save")
            return
        }
        #expect(record.flash["notice"] == (try encoded("Saved.")))
        #expect(record.values.isEmpty)
    }

    @Test("flash from the previous request is readable now and cleared by this request's save")
    func flashRead() throws {
        let (id, session) = loaded(
            values: ["k": try encoded(1)], flash: ["notice": try encoded("Saved.")])
        #expect(session.flashedKeys == ["notice"])
        #expect(try session.flashed("notice", as: String.self) == "Saved.")
        #expect(
            try session.flashed("notice", as: String.self) == "Saved.",
            "readable more than once within the request")
        // Untouched otherwise, but the flash has to be cleared, so this
        // request writes.
        guard case .save(let savedID, let record, _) = session.commit(now: now, ttl: ttl) else {
            Issue.record("expected a save that clears the flash")
            return
        }
        #expect(savedID == id)
        #expect(record.flash.isEmpty)
        #expect(record.values["k"] == (try encoded(1)))
    }

    @Test("a session holding only a stale flash is deleted, not stored empty")
    func flashOnly() throws {
        let (id, session) = loaded(flash: ["notice": try encoded("Saved.")])
        #expect(session.commit(now: now, ttl: ttl) == .delete(id))
    }

    // MARK: Decoding

    @Test("a value that does not decode as the type asked for throws rather than reading as absent")
    func decodeFailure() throws {
        let (_, session) = loaded(values: ["k": try encoded("not a number")])
        #expect(throws: (any Error).self) {
            try session.get("k", as: Int.self)
        }
        #expect(try session.get("absent", as: Int.self) == nil)
    }

    @Test("values are encoded with the coding the session was given")
    func customCoding() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        struct Profile: Codable, Equatable { var displayName: String }

        let session = Session(coding: .init(encoder: encoder, decoder: decoder))
        try session.set("profile", Profile(displayName: "Ada"))
        guard case .save(_, let record, _) = session.commit(now: now, ttl: ttl) else {
            Issue.record("expected a save")
            return
        }
        #expect(String(decoding: record.values["profile"]!, as: UTF8.self).contains("display_name"))
        #expect(try session.get("profile", as: Profile.self) == Profile(displayName: "Ada"))
    }

    // MARK: Record

    @Test("a record round-trips through its bytes")
    func recordRoundTrip() throws {
        let record = SessionRecord(
            values: ["k": try encoded(1)], flash: ["n": try encoded("x")],
            createdAt: now, expiresAt: now.addingTimeInterval(60))
        let decoded = try SessionRecord(decoding: try record.encoded())
        #expect(decoded == record)
    }
}

extension Duration {
    fileprivate var timeIntervalForTest: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
