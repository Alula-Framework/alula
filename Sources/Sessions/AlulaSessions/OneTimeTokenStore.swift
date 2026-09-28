import AlulaSupport
import Foundation
import Synchronization

/// Short-lived, single-use records under an opaque key — what a
/// password-reset link, an email-verification link or a magic sign-in link
/// is redeemed against.
///
/// Here, beside ``SessionStore``, because it is the same kind of thing:
/// server-side state with a lifetime, which a Valkey or in-memory store
/// already knows how to keep, and which must be shared across replicas the
/// moment there is more than one. The token logic — generating, hashing,
/// binding, redeeming — is AlulaSecurityCore's `OneTimeTokens`; this is only
/// where the bytes live, so a store needs nothing security-specific to
/// implement it.
///
/// The one property that matters is **``take(_:)`` is atomic**: a record is
/// returned to exactly one caller and is gone for every other, even when two
/// requests race with the same link. A store that gets and then deletes in two
/// steps lets one link be redeemed twice.
///
/// Both methods throw when the store cannot answer, rather than reading as
/// absent: `OneTimeTokens` passes the error through, so an outage is not
/// reported to the user as an invalid link. Whether a `take` that threw
/// consumed the record is the store's to say — a network store may have
/// deleted it before the reply was lost — so treat the link as possibly
/// spent.
public protocol OneTimeTokenStore: Sendable {
    /// Stores `record` under `key`, replacing any record already there, to
    /// be dropped once `ttl` has passed.
    func put(_ key: String, _ record: Data, ttl: Duration) async throws

    /// Removes the record under `key` and returns it, atomically — or nil
    /// when there is none, or it has expired.
    func take(_ key: String) async throws -> Data?
}

/// A ``OneTimeTokenStore`` in memory: bounded, with lazy expiry. Right for
/// one replica, development and tests — not shared across instances, and
/// lost on restart, so a link issued by one replica cannot be redeemed on
/// another.
///
/// ``take(_:)`` is atomic under one lock. Past ``maxEntries``, expired
/// records go first and then the soonest to expire, in a batch of a
/// sixteenth of the bound so the sort is not paid on every put while the
/// store is full. A link evicted that way simply stops working, with no
/// error to anyone.
public final class InMemoryOneTimeTokenStore: OneTimeTokenStore, Sendable {
    /// The bound ``init(maxEntries:now:)`` uses when given none.
    public static let defaultMaxEntries = 100_000

    private struct Entry {
        var record: Data
        var expiresAt: Date
    }

    private let entries = Mutex<[String: Entry]>([:])
    private let now: @Sendable () -> Date
    public let maxEntries: Int

    public init(
        maxEntries: Int = InMemoryOneTimeTokenStore.defaultMaxEntries,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(
            maxEntries > 0, "InMemoryOneTimeTokenStore is bounded — maxEntries must be positive.")
        self.maxEntries = maxEntries
        self.now = now
    }

    public func put(_ key: String, _ record: Data, ttl: Duration) async throws {
        let now = now()
        entries.withLock { entries in
            entries[key] = Entry(
                record: record, expiresAt: now.addingTimeInterval(ttl.inSeconds))
            // Still over after the expired go: the soonest to expire next —
            // they are the ones least likely to still be redeemed.
            BoundedEviction.enforce(
                &entries, maxEntries: maxEntries, isExpired: { $0.expiresAt <= now },
                order: \.expiresAt)
        }
    }

    public func take(_ key: String) async throws -> Data? {
        let now = now()
        return entries.withLock { entries in
            guard let entry = entries.removeValue(forKey: key), entry.expiresAt > now else {
                return nil
            }
            return entry.record
        }
    }

    /// Records held, expired ones included until taken or swept —
    /// introspection for tests.
    public var count: Int { entries.withLock { $0.count } }
}
