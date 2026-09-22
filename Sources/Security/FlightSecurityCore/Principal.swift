/// The authenticated identity.
///
/// A `Principal` is produced by a ``TokenValidator`` from an externally
/// issued identity token. `roles`, `scopes`, and `claims` are surfaced
/// directly from the validated token — Flight parses data it already has,
/// it does not build an identity model.
public struct Principal: Sendable {
    /// The IdP's stable user id (JWT `sub`).
    public let subject: String

    /// Which IdP asserted this identity (JWT `iss`).
    public let issuer: String

    /// Roles from the token's roles/groups claim(s).
    public let roles: Set<String>

    /// OAuth2 scopes, if present on the token.
    public let scopes: Set<String>

    /// Remaining claims, for application use. Values are the standard JSON
    /// bridges: `String`, `Int`, `Double`, `Bool`, `[any Sendable]`, and
    /// `[String: any Sendable]`. Claims whose value is JSON `null` are
    /// omitted.
    public let claims: [String: any Sendable]

    public init(
        subject: String,
        issuer: String,
        roles: Set<String> = [],
        scopes: Set<String> = [],
        claims: [String: any Sendable] = [:]
    ) {
        self.subject = subject
        self.issuer = issuer
        self.roles = roles
        self.scopes = scopes
        self.claims = claims
    }

    public func hasRole(_ role: String) -> Bool { roles.contains(role) }

    public func hasScope(_ scope: String) -> Bool { scopes.contains(scope) }

    /// Typed access to an application claim: `principal.claim("email", as: String.self)`.
    public func claim<T: Sendable>(_ name: String, as type: T.Type = T.self) -> T? {
        claims[name] as? T
    }
}

/// The claims every sign-in path agrees on.
///
/// A principal can come from a validated bearer token, from an OIDC sign-in,
/// or from a password checked against the application's own store — and an
/// application should not be able to tell which. These four names are OpenID
/// Connect Core §5.1's standard claims, so an external identity provider
/// already emits them, and every sign-in provider in this package emits the
/// same names with the same types. Code reading `principal.email` keeps
/// working when the application switches from its own passwords to Keycloak,
/// or back.
extension Principal {
    public enum StandardClaim {
        public static let email = "email"
        public static let emailVerified = "email_verified"
        public static let name = "name"
        public static let preferredUsername = "preferred_username"

        /// The claims a session keeps. See `Codable` below.
        static let persisted = [email, emailVerified, name, preferredUsername]
    }

    public var email: String? { claim(StandardClaim.email) }

    /// False when absent: an address nobody asserted was verified is not.
    public var emailVerified: Bool { claim(StandardClaim.emailVerified) ?? false }

    public var name: String? { claim(StandardClaim.name) }

    public var preferredUsername: String? { claim(StandardClaim.preferredUsername) }
}

/// The stable identity, persistable: `subject`, `issuer`, `roles`, `scopes`,
/// and the four ``StandardClaim``s.
///
/// Other claims are deliberately not encoded. They are `[String: any Sendable]`
/// straight off a token — arbitrary JSON the IdP chose to include — and a
/// session is the wrong place to keep a copy of it: the token it came from
/// expires, the session does not, and a claim read from the session a week
/// later is a fact about a token nobody has any more.
///
/// The standard profile claims are the exception, because they are what makes
/// sign-in paths interchangeable: a browser signed in by session would
/// otherwise have no `email` while the same user arriving by bearer token
/// did, and every screen that shows who is signed in would have to know
/// which path produced the principal. They describe the person rather than
/// the token, and they are exactly what the principal was built with at
/// sign-in. Sessions written before these were kept decode without them.
extension Principal: Codable {
    private enum CodingKeys: String, CodingKey {
        case subject, issuer, roles, scopes
        case email
        case emailVerified = "email_verified"
        case name
        case preferredUsername = "preferred_username"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var claims: [String: any Sendable] = [:]
        claims[StandardClaim.email] = try container.decodeIfPresent(String.self, forKey: .email)
        claims[StandardClaim.emailVerified] = try container.decodeIfPresent(
            Bool.self, forKey: .emailVerified)
        claims[StandardClaim.name] = try container.decodeIfPresent(String.self, forKey: .name)
        claims[StandardClaim.preferredUsername] = try container.decodeIfPresent(
            String.self, forKey: .preferredUsername)
        self.init(
            subject: try container.decode(String.self, forKey: .subject),
            issuer: try container.decode(String.self, forKey: .issuer),
            roles: try container.decode(Set<String>.self, forKey: .roles),
            scopes: try container.decode(Set<String>.self, forKey: .scopes),
            claims: claims)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subject, forKey: .subject)
        try container.encode(issuer, forKey: .issuer)
        try container.encode(roles, forKey: .roles)
        try container.encode(scopes, forKey: .scopes)
        try container.encodeIfPresent(email, forKey: .email)
        // Only when asserted: absent and false read the same, and writing
        // `false` for every principal would claim an assertion nobody made.
        if let verified: Bool = claim(StandardClaim.emailVerified) {
            try container.encode(verified, forKey: .emailVerified)
        }
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(preferredUsername, forKey: .preferredUsername)
    }
}

extension Principal {
    /// The ambient principal for the current task tree.
    ///
    /// Bound with `Principal.$current.withValue(...)`, most conveniently via
    /// `RequestContext.withPrincipal { ... }` inside a handler. The value
    /// propagates to structured child tasks (`async let`, task groups) but
    /// **not** across `Task.detached` boundaries — which is correct: a
    /// detached background job should not silently inherit the requester's
    /// identity.
    ///
    /// Note: the authentication middleware does not bind this task-local
    /// around the handler. It once could not — the chain was a flat sequence
    /// of returns — but `compose(_:around:)` folds it into layers now, so
    /// each middleware's `next(context)` runs inside its own extent and a
    /// binding there would reach the handler. It stays unbound because the
    /// principal travels on the context instead, which is readable without
    /// an ambient lookup. Inside handlers and middleware read
    /// `context.principal`; use this task-local for services called under
    /// `withPrincipal`.
    @TaskLocal public static var current: Principal?
}
