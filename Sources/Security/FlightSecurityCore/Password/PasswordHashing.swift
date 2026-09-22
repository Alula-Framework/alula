/// Turns a password into something safe to store, and checks one against
/// what was stored.
///
/// The seam is narrow on purpose, and it is deliberately about the
/// algorithm alone: nothing here knows about a `CredentialStore`, an
/// account, or a login attempt. Those are a later, larger piece; this is
/// the one primitive underneath all of them, isolated so it can be
/// swapped, tested, and reasoned about on its own.
///
/// ``Argon2idHashing`` ships here as the default. Bring your own only for a
/// case this one genuinely does not cover — migrating hashes an older
/// system produced with a different algorithm, most commonly.
public protocol PasswordHashing: Sendable {
    /// Hashes `password`, returning a string that carries everything needed
    /// to verify it later: the algorithm, its parameters, the salt, and the
    /// hash itself. Store this whole string; there is nothing else to keep
    /// beside it.
    ///
    /// A fresh, cryptographically random salt is generated on every call,
    /// which is why hashing the same password twice produces two different
    /// strings — both verify correctly.
    func hash(_ password: String) throws -> String

    /// Whether `password` produces `hash`. Constant-time in the comparison
    /// that matters: a mismatch and a match take indistinguishable time, so
    /// a timing side channel cannot narrow down which byte of a guess was
    /// wrong.
    ///
    /// Never throws: a hash that does not parse, or was produced by a
    /// different algorithm entirely, is simply not a match. There is no
    /// question here whose honest answer is "error" rather than "no."
    func verify(_ password: String, against hash: String) -> Bool

    /// Whether `hash` was produced under weaker parameters than this
    /// instance is configured with now — a lower time cost, less memory, a
    /// different algorithm version. `true` means the caller should hash the
    /// password again and store the new result, which is only possible
    /// exactly when a request already has the plaintext in hand: right
    /// after a successful ``verify(_:against:)``, never on its own.
    ///
    /// This is what lets a deployment raise its cost parameters over time —
    /// hardware gets faster, the safe minimum rises with it — without a
    /// migration that touches every stored hash at once. Each account
    /// upgrades itself the next time its owner signs in.
    func needsRehash(_ hash: String) -> Bool
}

/// A hash string that ``PasswordHashing`` could not use — malformed, or not
/// produced by this implementation. Detail for the internal log; the
/// caller-facing answer is always "no match," never this.
public struct PasswordHashingError: Error, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { "password hashing failed: \(reason)" }
}
