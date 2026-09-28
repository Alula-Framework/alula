import AlulaSessions
import AlulaSupport

/// The token this session's state-changing requests must carry, and the
/// place it lives.
///
/// The synchronizer pattern: the value exists once, server-side, in the
/// session — not in a second cookie, the way the double-submit variant
/// needs. A response hands it to whatever will submit the next unsafe
/// request, the application's own choice how: a hidden form field, a
/// `<meta>` tag a script reads, a field in a JSON body. Nothing here
/// prescribes that part, because it depends entirely on what the response
/// is.
extension Session {
    private static let csrfTokenKey = "alula.csrf-token"

    /// The token to embed in whatever this response is about to send —
    /// generated once, on first call, and stored for the rest of the
    /// session's life. Safe to call from a request that will not write
    /// anything else: like every other `Session` write, nothing is
    /// persisted until the request actually modifies something, and
    /// calling this is exactly that.
    ///
    /// Not rotated by `regenerate()` or a sign-in: the token is a
    /// session value, and values move to the new id with the rest. It ends
    /// with the session — destroyed, emptied, or expired.
    public func csrfToken() throws -> String {
        if let existing = try get(Self.csrfTokenKey, as: String.self) {
            return existing
        }
        let token = CSRFToken.generate()
        try set(Self.csrfTokenKey, token)
        return token
    }
}

enum CSRFToken {
    /// 256 bits, unpadded base64url — the same shape `SessionID.generate()`
    /// produces, from the same generator. A session id and a CSRF token are
    /// different values with different lifetimes; they share only the
    /// primitive.
    static func generate() -> String {
        SecureRandom.token()
    }

    /// Whether `provided` is the same string as `expected`, in time that
    /// does not depend on *where* they first differ — a plain `==` leaks
    /// enough through response timing to recover a valid token one byte at
    /// a time.
    static func matches(_ provided: String, _ expected: String) -> Bool {
        ConstantTime.equals(provided, expected)
    }
}
