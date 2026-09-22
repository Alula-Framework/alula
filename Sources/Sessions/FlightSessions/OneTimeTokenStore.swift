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
/// binding, redeeming — is FlightSecurityCore's `OneTimeTokens`; this is only
/// where the bytes live, so a store needs nothing security-specific to
/// implement it.
///
/// The one property that matters is **``take(_:)`` is atomic**: a record is
/// returned to exactly one caller and is gone for every other, even when two
/// requests race with the same link. A store that gets and then deletes in two
/// steps lets one link be redeemed twice.
public protocol OneTimeTokenStore: Sendable {
    /// Stores `record` under `key`, to be dropped once `ttl` has passed.
    func put(_ key: String, _ record: Data, ttl: Duration) async throws

    /// Removes the record under `key` and returns it, atomically — or nil
    /// when there is none, or it has expired.
    func take(_ key: String) async throws -> Data?
}

/// A ``OneTimeTokenStore`` in memory: bounded, with lazy expiry. Right for
/// one replica, development and tests.
public final class InMemoryOneTimeTokenStore: OneTimeTokenStore, Sendable {
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
                record: record, expiresAt: now.addingTimeInterval(ttl.timeInterval))
            guard entries.count > maxEntries else { return }
            for (key, entry) in entries where entry.expiresAt <= now {
                entries.removeValue(forKey: key)
            }
            // Still over: the soonest to expire go first — they are the ones
            // least likely to still be redeemed.
            if entries.count > maxEntries {
                let excess = entries.count - maxEntries
                for (key, _) in entries.sorted(by: { $0.value.expiresAt < $1.value.expiresAt })
                    .prefix(excess)
                {
                    entries.removeValue(forKey: key)
                }
            }
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

    public var count: Int { entries.withLock { $0.count } }
}
