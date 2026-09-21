import FlightSessions

/// A session as the place a signed-in identity lives between requests.
///
/// The bearer-token path establishes identity per request from a credential
/// the client sends every time. A browser has no such credential; it has a
/// cookie. So the credential check happens once — a password form, an OIDC
/// callback, a magic link, whatever the application does — and the
/// resulting ``Principal`` is stored here. From then on ``Authentication``
/// finds it in the session on every request that carries the cookie, and
/// `context.principal`, `requirePrincipal()` and `roles:` all work exactly as
/// they do for a token.
extension Session {
    /// The key the principal is stored under. Reserved: an application that
    /// writes its own value here signs someone in.
    public static let principalKey = "flight.principal"

    /// Stores `principal` and regenerates the session id.
    ///
    /// Regeneration is not optional and not separate: a session id handed
    /// out before authentication must not be the id that is authenticated
    /// afterwards, or whoever planted it holds the signed-in session. The
    /// session's other values survive — a cart filled before signing in is
    /// still there after.
    public func signIn(_ principal: Principal) throws {
        try set(Self.principalKey, principal)
        regenerate()
    }

    /// Forgets the principal and regenerates the id, keeping the rest.
    /// `destroy()` is the stronger form, for a logout that should leave
    /// nothing behind.
    public func signOut() {
        remove(Self.principalKey)
        regenerate()
    }

    /// The stored principal, or `nil` when nobody is signed in. Throws when
    /// the stored bytes do not decode as one — a format change, or another
    /// writer under the reserved key.
    public func principal() throws -> Principal? {
        try get(Self.principalKey, as: Principal.self)
    }
}
