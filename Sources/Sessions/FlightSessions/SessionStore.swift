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
