import Foundation
import Synchronization

/// One request's view of its session: read and write values, flash a message
/// for the next request, regenerate the id on login, destroy it on logout.
///
/// A reference type on purpose. `RequestContext` is a value copied per
/// middleware layer, and a handler's writes have to reach the middleware that
/// persists them after the handler returns — so the context carries a
/// reference to this object, and the middleware reads back what the handler
/// did through ``commit(now:ttl:)``. A task-local would work too, and is what
/// `Principal.current` is; it is second-class there for the same reason it
/// would be here: a value on the context is readable without an ambient
/// lookup.
///
/// Nothing is persisted until something is written. A request that only
/// reads an empty session leaves no record and sets no cookie, so anonymous
/// traffic cannot fill the store.
///
/// Values are encoded as JSON as they are set — with the ``Coding`` this
/// session was given, plain `JSONEncoder`/`JSONDecoder` by default. A value
/// that fails to decode on the way back throws rather than returning
/// `nil`: a session holding bytes that no longer decode as the type asked
/// for is a programming error worth surfacing, not an absent key.
public final class Session: Sendable {

    /// How values are turned into the bytes a store holds.
    public struct Coding: Sendable {
        public var encoder: JSONEncoder
        public var decoder: JSONDecoder

        public init(encoder: JSONEncoder, decoder: JSONDecoder) {
            self.encoder = encoder
            self.decoder = decoder
        }

        /// Plain `JSONEncoder`/`JSONDecoder` defaults — what a session built
        /// outside a web pipeline uses.
        public static let json = Coding(encoder: JSONEncoder(), decoder: JSONDecoder())
    }

    /// What the record this session came from looked like, for deciding what
    /// to do when the request ends.
    private struct Loaded {
        let id: SessionID
        let createdAt: Date
        let expiresAt: Date
        let hadFlash: Bool
    }

    private struct State {
        var loaded: Loaded?
        var values: [String: Data]
        var owner: String?
        /// Flash written by the previous request, readable during this one.
        var flash: [String: Data]
        /// Flash written during this request, for the next one.
        var nextFlash: [String: Data] = [:]
        var isModified = false
        var regenerateRequested = false
        var isDestroyed = false
        /// Set by `commit` so `id` answers after a save.
        var committedID: SessionID?

        func record(createdAt: Date, now: Date, ttl: Duration) -> SessionRecord {
            SessionRecord(
                values: values, flash: nextFlash, createdAt: createdAt,
                expiresAt: now.addingTimeInterval(ttl.timeInterval), owner: owner)
        }
    }

    private let state: Mutex<State>
    private let coding: Coding

    /// An empty session no store has heard of — what a request with no
    /// cookie, or a cookie naming nothing, starts with.
    public init(coding: Coding = .json) {
        self.coding = coding
        self.state = Mutex(State(loaded: nil, values: [:], flash: [:]))
    }

    /// A session loaded from `record`, stored under `id`.
    public init(id: SessionID, record: SessionRecord, coding: Coding = .json) {
        self.coding = coding
        self.state = Mutex(
            State(
                loaded: Loaded(
                    id: id, createdAt: record.createdAt, expiresAt: record.expiresAt,
                    hadFlash: !record.flash.isEmpty),
                values: record.values,
                owner: record.owner,
                flash: record.flash))
    }

    // MARK: - Identity

    /// The id this session is stored under, or `nil` for one nothing has
    /// persisted yet. Assigned when the middleware commits a new session, so
    /// a handler that needs the id of a session it just created does not
    /// have one — call ``regenerate()`` first if the id must exist during the
    /// request, or key off something the application owns instead.
    public var id: SessionID? {
        state.withLock { $0.committedID ?? $0.loaded?.id }
    }

    /// `true` until the session has been persisted once.
    public var isNew: Bool {
        state.withLock { $0.loaded == nil }
    }

    public var isDestroyed: Bool {
        state.withLock { $0.isDestroyed }
    }

    // MARK: - Owner

    /// Whose session this is: an opaque id, usually the signed-in subject.
    /// `Session.signIn(_:)` in FlightSecurityCore sets it and `signOut()`
    /// clears it, so an application using that never touches this.
    public var owner: String? {
        state.withLock { $0.owner }
    }

    /// Records whose session this is, so a store that indexes by owner
    /// (``OwnerIndexedSessionStore``) can end every one of them at once.
    /// Setting what is already there does not mark the session modified.
    public func setOwner(_ owner: String?) {
        state.withLock { state in
            guard state.owner != owner else { return }
            state.owner = owner
            state.isModified = true
        }
    }

    // MARK: - Values

    public var keys: Set<String> {
        state.withLock { Set($0.values.keys) }
    }

    public var isEmpty: Bool {
        state.withLock { $0.values.isEmpty }
    }

    public func contains(_ key: String) -> Bool {
        state.withLock { $0.values[key] != nil }
    }

    /// The value under `key`, or `nil` when there is none. Throws when the
    /// stored bytes do not decode as `T`.
    public func get<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        guard let data = state.withLock({ $0.values[key] }) else { return nil }
        return try coding.decoder.decode(type, from: data)
    }

    /// Stores `value` under `key`. Setting what is already there — byte for
    /// byte — does not mark the session modified, so a handler that writes
    /// the same thing on every request costs no store write.
    public func set<T: Encodable>(_ key: String, _ value: T) throws {
        let data = try coding.encoder.encode(value)
        state.withLock { state in
            guard state.values[key] != data else { return }
            state.values[key] = data
            state.isModified = true
        }
    }

    public func remove(_ key: String) {
        state.withLock { state in
            guard state.values.removeValue(forKey: key) != nil else { return }
            state.isModified = true
        }
    }

    // MARK: - Flash

    /// Stores `value` for the next request only. The classic use is a notice
    /// written before a redirect and shown by the page redirected to.
    public func flash<T: Encodable>(_ key: String, _ value: T) throws {
        let data = try coding.encoder.encode(value)
        state.withLock { state in
            state.nextFlash[key] = data
            state.isModified = true
        }
    }

    /// A value flashed by the previous request. Readable any number of times
    /// during this request; gone once this request ends.
    public func flashed<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        guard let data = state.withLock({ $0.flash[key] }) else { return nil }
        return try coding.decoder.decode(type, from: data)
    }

    /// The keys the previous request flashed.
    public var flashedKeys: Set<String> {
        state.withLock { Set($0.flash.keys) }
    }

    // MARK: - Lifecycle

    /// Keeps the values and moves them under a new id, deleting the old one.
    /// Call it when the session's privilege changes — on login above all:
    /// a session id handed out before authentication must not be the one
    /// that is authenticated afterwards, or an attacker who planted it holds
    /// the signed-in session (fixation).
    public func regenerate() {
        state.withLock { state in
            state.regenerateRequested = true
            state.isModified = true
        }
    }

    /// Ends the session: the store entry is deleted and the cookie expired.
    /// Values written afterwards in the same request are discarded.
    public func destroy() {
        state.withLock { $0.isDestroyed = true }
    }

    // MARK: - Commit

    /// What the middleware must do once the handler has returned. Called
    /// once per request, after `next`; the answer folds together everything
    /// the handler did and the sliding-expiry rule.
    ///
    /// - A fresh session nothing was written to is ``SessionCommit/nothing``:
    ///   no record, no cookie.
    /// - A loaded session left untouched is also nothing — unless it has
    ///   less than half of `ttl` left, in which case it is saved as-is to
    ///   renew it. Renewing on every request would cost a write per request;
    ///   renewing only past the half-life bounds the writes an idle session
    ///   costs to one per half-TTL and still never lets an active session
    ///   expire.
    /// - A modified session is saved, under a new id if ``regenerate()`` was
    ///   called, with the old id named for deletion.
    /// - A loaded session whose last value was removed is deleted rather
    ///   than stored empty.
    /// - A destroyed session is deleted if it was ever stored, and is nothing
    ///   otherwise.
    public func commit(now: Date, ttl: Duration) -> SessionCommit {
        state.withLock { state in
            if state.isDestroyed {
                return state.loaded.map { .delete($0.id) } ?? .nothing
            }
            let hasContent = !state.values.isEmpty || !state.nextFlash.isEmpty
            guard let loaded = state.loaded else {
                guard hasContent else { return .nothing }
                let id = SessionID.generate()
                state.committedID = id
                return .save(
                    id: id, record: state.record(createdAt: now, now: now, ttl: ttl), replacing: nil
                )
            }
            let renewalDue = loaded.expiresAt.timeIntervalSince(now) < ttl.timeInterval / 2
            let needsSave = state.isModified || loaded.hadFlash || renewalDue
            guard needsSave else { return .nothing }
            guard hasContent else { return .delete(loaded.id) }
            let id = state.regenerateRequested ? SessionID.generate() : loaded.id
            state.committedID = id
            return .save(
                id: id,
                record: state.record(createdAt: loaded.createdAt, now: now, ttl: ttl),
                replacing: state.regenerateRequested ? loaded.id : nil)
        }
    }
}

/// The middleware's instructions once a request's handler has returned.
public enum SessionCommit: Sendable, Equatable {
    /// No store call and no cookie.
    case nothing
    /// Store `record` under `id` and set the cookie to it. `replacing` names
    /// the id a regenerated session used to live under, to be deleted.
    case save(id: SessionID, record: SessionRecord, replacing: SessionID?)
    /// Delete the entry and expire the cookie.
    case delete(SessionID)
}

extension Duration {
    /// Seconds, as `Date` arithmetic wants them.
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
