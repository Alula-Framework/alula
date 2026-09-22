import Foundation

/// Where sessions are kept. The whole cross-store contract, and deliberately
/// `Data`-valued: a store moves opaque bytes and has no opinion about what a
/// session contains — the same choice Cache and PubSub make.
///
/// **Every method throws, unlike `Cache`.** A cache that fails is answered by
/// the real computation behind it; there is nothing behind a session. A store
/// that silently read empty would turn "signed in" into "signed out", and a
/// save that silently dropped would turn a login into nothing — both without
/// a single error anywhere. So a store says when it cannot answer, and the
/// middleware refuses the request with a 503 rather than guessing.
///
/// `InMemorySessionStore` ships here and is the default. `FlightSessionsValkey`
/// in flight-data implements this over Valkey for deployments with more than
/// one replica, and `FlightSessionsTesting`'s `RecordingSessionStore` is the
/// one for tests.
public protocol SessionStore: Sendable {
    /// The bytes stored under `id`, or `nil` when there is no live session
    /// there — never stored, deleted, or expired. Absence is normal, not an
    /// error.
    func load(_ id: SessionID) async throws -> Data?

    /// Stores `record` under `id`, replacing whatever was there, to be
    /// dropped once `ttl` has passed. The middleware has already decided the
    /// TTL from configuration; a store applies it and never consults
    /// configuration itself.
    func save(_ id: SessionID, _ record: Data, ttl: Duration) async throws

    /// Removes the session. Idempotent: deleting an absent id is not an error.
    func delete(_ id: SessionID) async throws
}

/// A store's own failure, with detail for the internal log. The wire never
/// sees it — the middleware answers 503 with a generic body.
public struct SessionStoreError: Error, Sendable, CustomStringConvertible {
    public enum Operation: String, Sendable {
        case load, save, delete
    }

    public let operation: Operation
    public let reason: String

    public init(operation: Operation, reason: String) {
        self.operation = operation
        self.reason = reason
    }

    public var description: String {
        "session store \(operation.rawValue) failed: \(reason)"
    }
}

/// A store that also knows whose session each one is, and so can end every
/// session one person has — "sign out everywhere", after a password change
/// or when an account is disabled.
///
/// A capability rather than a requirement of ``SessionStore``: a store is
/// handed opaque bytes, and indexing them by owner is extra work a store
/// opts into. The middleware hands an indexing store the owner on every
/// save; a store that does not index keeps working unchanged, and asking it
/// to revoke says so (``SessionRevocationUnsupported``) rather than quietly
/// ending nothing.
public protocol OwnerIndexedSessionStore: SessionStore {
    /// ``SessionStore/save(_:_:ttl:)``, recording that `id` belongs to
    /// `owner` — replacing whatever owner it had, and forgetting it when
    /// `owner` is nil.
    func save(_ id: SessionID, _ record: Data, ttl: Duration, owner: String?) async throws

    /// Deletes every live session belonging to `owner` except `keeping`,
    /// and says how many went. Absent or expired ones are not an error.
    @discardableResult
    func deleteSessions(ownedBy owner: String, keeping: SessionID?) async throws -> Int
}

/// Asked to end someone's sessions, a store that does not index them by
/// owner. Surfaced, never swallowed: a "sign out everywhere" that silently
/// signed nobody out is the failure this exists to prevent.
public struct SessionRevocationUnsupported: Error, Sendable, CustomStringConvertible {
    public let storeType: String

    public init(storeType: String) { self.storeType = storeType }

    public var description: String {
        "\(storeType) does not index sessions by owner, so it cannot end every session one "
            + "person has. Use a store that conforms to OwnerIndexedSessionStore."
    }
}
