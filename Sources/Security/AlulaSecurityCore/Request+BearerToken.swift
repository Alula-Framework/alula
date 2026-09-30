import AlulaWeb

extension Request {
    /// The bearer token from the `Authorization` header, or `nil` when the
    /// header is absent, uses another scheme, or is malformed.
    ///
    /// The scheme comparison is case-insensitive (`Bearer`, `bearer`, …);
    /// the credential itself is returned verbatim. A malformed value (empty
    /// token, embedded whitespace) yields `nil` — i.e. the request is
    /// treated as unauthenticated rather than rejected here; enforcement is
    /// a separate concern.
    ///
    /// `CSRFProtection` exempts a request by the same parse, so a header this
    /// returns `nil` for never skips the CSRF check.
    public var bearerToken: String? {
        guard let header = headers[.authorization] else { return nil }
        return Self.parseBearer(header)
    }
}
