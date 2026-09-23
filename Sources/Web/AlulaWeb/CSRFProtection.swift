import HTTPTypes

/// Refuses a state-changing request that does not carry the session's own
/// CSRF token.
///
/// ```swift
/// MiddlewareRegistration.lane(.default, [
///     Sessions(runtime: sessions.runtime),
///     CSRFProtection(),
/// ])
/// ```
///
/// The synchronizer pattern. A response hands the session's token to
/// whatever will submit the next request — a hidden form field, a `<meta>`
/// tag, a JSON field — and that value has to come back on
/// `X-CSRF-Token` for the request to be believed:
///
/// ```swift
/// @GetRoute("/transfer")
/// func form(_ context: RequestContext) throws -> TransferForm {
///     TransferForm(csrfToken: try context.requireSession().csrfToken())
/// }
///
/// @PostRoute("/transfer", pipelines: [.authenticated])
/// func submit(_ context: RequestContext, body: TransferRequest) async throws -> Response { … }
/// ```
///
/// **Why this is enough, and why nothing here reads a form field.** The
/// attack this defends against is a browser's *ambient* authority — a
/// cookie it attaches automatically, to a request an attacker's page
/// triggers without the visitor's knowledge. A script on an attacker's own
/// site cannot read `X-CSRF-Token` off *your* page to attach it, because
/// the Same-Origin Policy is exactly what stops that read — so requiring
/// the header is already the whole defense, whether the value reaches the
/// client via a form field, a script tag, or a response header of its own.
/// Reading the token back out of a submitted form body is more parsing for
/// no more security, and it never happened here for that reason, not by
/// oversight — an application still doing classic multipart form posts can
/// have its own middleware move the value from a field into the header
/// before this one runs.
///
/// **Safe methods are exempt**, by RFC 9110's own definition of "safe": GET,
/// HEAD, OPTIONS, and TRACE must not have side effects, and a route that
/// mutates state on one of those is a bug this cannot and should not paper
/// over.
///
/// **A request with no session is left alone.** CSRF protects ambient,
/// cookie-carried authority; a route with no `Sessions` in its lane has
/// none to protect — a bearer-token API is already immune, since a script
/// cannot make a browser attach a header it never told the browser to send,
/// the same property `X-CSRF-Token` itself relies on. Conforming to
/// ``SessionReading`` still matters here: a lane that lists this ahead of
/// `Sessions` by mistake would see `nil` on every request and silently
/// protect nothing, which is exactly the failure composition catches for
/// `Authentication` and is why this asks for the identical check.
public struct CSRFProtection: Middleware, SessionReading {
    private static let safeMethods: Set<HTTPRequest.Method> = [.get, .head, .options, .trace]

    public init() {}

    public func handle(_ context: RequestContext, next: Next) async throws -> Response {
        guard !Self.safeMethods.contains(context.request.method) else {
            return try await next(context)
        }
        guard let session = context.session else {
            return try await next(context)
        }
        let expected = try session.csrfToken()
        guard let provided = context.request.headers[.xCSRFToken],
            CSRFToken.matches(provided, expected)
        else {
            throw CSRFError.tokenMismatch
        }
        return try await next(context)
    }
}

/// The token was missing or did not match. Rendered as a bare 403 — the
/// same error hygiene as `SecurityError`: a client learns that it was
/// refused, never why in enough detail to help it guess again.
public struct CSRFError: Error, Sendable, Equatable, HTTPErrorRepresentable, CustomStringConvertible
{
    public static let tokenMismatch = CSRFError()

    public var httpStatus: HTTPResponse.Status { .forbidden }
    public var httpMessage: String { "Forbidden" }
    public var description: String { "CSRF token missing or did not match the session's" }
}

extension HTTPField.Name {
    /// Force-unwrapped: a literal, pinned valid by `HeaderNameTests`.
    static let xCSRFToken = HTTPField.Name("x-csrf-token")!
}
