import Synchronization

/// What an application's own user storage knows about one account, as a
/// password sign-in needs to see it.
///
/// Not a user model. The application's users table — its columns, its ORM,
/// its idea of what an account is — stays the application's. A
/// ``CredentialStore`` maps whatever it has onto this and nothing more, which
/// is what keeps the sign-in code identical across every schema, and is what
/// makes the four claims here the same four an external identity provider
/// emits (``Principal/StandardClaim``).
public struct StoredCredential: Sendable, Equatable {
    /// The stable, opaque id this account is known by — becomes
    /// ``Principal/subject``. **Never the email address.** Addresses change,
    /// and when this application moves to an external identity provider, the
    /// subject is what every row keyed by user survives the move on.
    public var subject: String
    /// A ``PasswordHashing`` output, or nil for an account that has no
    /// password — invited and not yet set, or signing in some other way. A
    /// nil hash never authenticates.
    public var passwordHash: String?
    public var roles: Set<String>
    /// A disabled account is refused *after* its password verifies, so the
    /// refusal tells nothing to someone who does not know the password.
    public var isDisabled: Bool
    public var email: String?
    public var emailVerified: Bool
    public var name: String?
    public var preferredUsername: String?

    public init(
        subject: String,
        passwordHash: String?,
        roles: Set<String> = [],
        isDisabled: Bool = false,
        email: String? = nil,
        emailVerified: Bool = false,
        name: String? = nil,
        preferredUsername: String? = nil
    ) {
        self.subject = subject
        self.passwordHash = passwordHash
        self.roles = roles
        self.isDisabled = isDisabled
        self.email = email
        self.emailVerified = emailVerified
        self.name = name
        self.preferredUsername = preferredUsername
    }

    /// The standard claims, named as OIDC names them.
    var standardClaims: [String: any Sendable] {
        var claims: [String: any Sendable] = [:]
        claims[Principal.StandardClaim.email] = email
        if email != nil { claims[Principal.StandardClaim.emailVerified] = emailVerified }
        claims[Principal.StandardClaim.name] = name
        claims[Principal.StandardClaim.preferredUsername] = preferredUsername
        return claims
    }
}

/// Where password sign-in looks accounts up. The application implements it
/// over its own storage; alula-data ships a Postgres one for an application
/// that has none yet.
///
/// Two operations, because that is all a sign-in needs: find by what the
/// user typed, and save a stronger hash after a successful sign-in under
/// weaker parameters. Registration, profile edits and deletion are the
/// application's business and never pass through here.
public protocol CredentialStore: Sendable {
    /// The account the user typed, or nil. `identifier` arrives trimmed and
    /// Unicode-normalized (NFC); **case-folding is the store's decision** —
    /// a `citext` column, a lowered index, or exact match — because only the
    /// store knows whether "Ada" and "ada" are one account.
    func credential(forIdentifier identifier: String) async throws -> StoredCredential?

    /// Replaces the stored hash after a sign-in found it weaker than the
    /// current parameters. A failure here is logged, never surfaced: the
    /// user did sign in, and the upgrade is retried at the next one.
    func updatePasswordHash(_ hash: String, forSubject subject: String) async throws
}

/// A ``CredentialStore`` in memory — for tests, and for a prototype that has
/// no database yet. Identifiers match case-insensitively.
public final class InMemoryCredentialStore: CredentialStore, Sendable {
    private struct State {
        var bySubject: [String: StoredCredential] = [:]
        var subjectByIdentifier: [String: String] = [:]
    }
    private let state = Mutex(State())

    public init() {}

    /// Adds or replaces `credential`, reachable by each of `identifiers` —
    /// an email and a username, say.
    public func insert(_ credential: StoredCredential, identifiers: [String]) {
        state.withLock { state in
            state.bySubject[credential.subject] = credential
            for identifier in identifiers {
                state.subjectByIdentifier[Self.key(identifier)] = credential.subject
            }
        }
    }

    public func credential(forIdentifier identifier: String) async throws -> StoredCredential? {
        state.withLock { state in
            state.subjectByIdentifier[Self.key(identifier)].flatMap { state.bySubject[$0] }
        }
    }

    public func updatePasswordHash(_ hash: String, forSubject subject: String) async throws {
        state.withLock { $0.bySubject[subject]?.passwordHash = hash }
    }

    /// The stored credential for `subject` — what a test asserts on.
    public func credential(forSubject subject: String) -> StoredCredential? {
        state.withLock { $0.bySubject[subject] }
    }

    private static func key(_ identifier: String) -> String { identifier.lowercased() }
}
