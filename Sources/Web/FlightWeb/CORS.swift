import Foundation
import HTTPTypes

// Cross-origin resource sharing.
//
// The first concrete `Middleware` this package ships, and it is here rather
// than left to applications for one reason: a hand-rolled CORS layer that is
// subtly wrong does not fail like other code. It either blocks a request the
// developer meant to allow — visible, annoying, fixed in an afternoon — or it
// allows one they did not, which is silent and is a security bug. The rules
// that decide which are not interesting enough to be worth rediscovering, and
// two of them (`*` with credentials, and `Vary`) are routinely missed.
//
// What this does not do is decide policy. The origins, the methods and the
// headers come from the application; nothing here has a permissive default.

/// Which origins may read a response from this service.
public enum AllowedOrigins: Sendable {
    /// Any origin, answered as a literal `*`.
    ///
    /// Valid only without credentials: a browser rejects `*` on a credentialed
    /// request outright, so the combination cannot work and is refused at
    /// construction rather than at three in the morning.
    case any

    /// An exact set, matched whole and case-sensitively — an origin is a
    /// scheme, host and port ("https://app.example.com"), never a path.
    case exact(Set<String>)

    /// Decided per request, for the cases a set cannot express (a tenant
    /// per subdomain, a list read from configuration at runtime).
    ///
    /// It is given the raw `Origin` header. Be stricter than `hasSuffix`:
    /// `"https://evil-example.com".hasSuffix("example.com")` is true, and
    /// that mistake is the whole of several CVEs.
    case matching(@Sendable (String) -> Bool)

    func allows(_ origin: String) -> Bool {
        switch self {
        case .any: return true
        case .exact(let set): return set.contains(origin)
        case .matching(let predicate): return predicate(origin)
        }
    }

    /// Whether the answer depends on the request, which is what decides
    /// `Vary: Origin`. Only a literal `*` does not.
    var isConstant: Bool {
        if case .any = self { return true }
        return false
    }
}

/// Which request headers a cross-origin caller may send.
public enum AllowedHeaders: Sendable {
    /// Whatever the preflight asked for, echoed back.
    ///
    /// Convenient and common; it does mean the service states no opinion, so
    /// prefer ``exact(_:)`` where the set is known.
    case reflectingRequest

    /// An exact list. The safe headers a browser sends anyway (`Accept`,
    /// `Content-Type` in its simple forms, and the rest of CORS' own
    /// safelist) need not appear here — they are never preflighted.
    case exact([HTTPField.Name])
}

/// Cross-origin resource sharing, as a middleware.
///
/// ```swift
/// MiddlewareRegistration.lane(.default, [
///     CORS(
///         allowedOrigins: .exact(["https://app.example.com"]),
///         allowedMethods: [.get, .post, .patch, .delete],
///         allowedHeaders: .exact([.contentType, .authorization]),
///         allowCredentials: true,
///         maxAge: .seconds(600))
/// ])
/// ```
///
/// ## Put it in every lane that serves a browser
///
/// Dispatch routes *first* and then runs the matched route's own lane, so a
/// middleware in `.default` does not run for a route that names
/// `pipelines: [.authenticated]`. A preflight still works — `OPTIONS` matches
/// no route, and the no-match path runs the default lane — which makes the
/// failure a confusing one: the preflight passes and the actual request comes
/// back without `Access-Control-Allow-Origin`. List `CORS` in each lane that
/// answers cross-origin traffic.
///
/// ## What it answers
///
/// A **preflight** (`OPTIONS` carrying `Access-Control-Request-Method`) never
/// reaches the router: it is answered here, `204` with the negotiated
/// headers, or `403` when the origin or the method is not allowed. A 403 is
/// not required — the browser blocks an unanswered preflight either way — but
/// a refusal that says which of the two was wrong is worth more in a log than
/// a 405 from the router.
///
/// Any **other request** passes through untouched, and the headers are added
/// to whatever comes back, error responses included. A request with no
/// `Origin` is not a cross-origin request and is left entirely alone.
public struct CORS: Middleware {
    public let allowedOrigins: AllowedOrigins
    public let allowedMethods: [HTTPRequest.Method]
    public let allowedHeaders: AllowedHeaders
    /// Response headers JavaScript may read. The safelist (`Content-Type`,
    /// `Cache-Control`, and four others) is readable without being listed.
    public let exposedHeaders: [HTTPField.Name]
    /// Whether cookies and `Authorization` may ride along.
    public let allowCredentials: Bool
    /// How long a browser may cache a preflight. Browsers clamp this to their
    /// own ceiling (Chrome: 2 hours, Firefox: 24), so a larger value is a
    /// request, not a guarantee.
    public let maxAge: Duration?

    public init(
        allowedOrigins: AllowedOrigins,
        allowedMethods: [HTTPRequest.Method] = [.get, .post, .put, .patch, .delete],
        allowedHeaders: AllowedHeaders = .reflectingRequest,
        exposedHeaders: [HTTPField.Name] = [],
        allowCredentials: Bool = false,
        maxAge: Duration? = nil
    ) {
        // Constructed at composition, so this fires at startup rather than on
        // a request. The alternative — quietly echoing the caller's origin
        // instead of `*` — is how "allow any origin" becomes "allow any
        // origin to act as any signed-in user", and it would look like it
        // worked.
        if allowCredentials, case .any = allowedOrigins {
            preconditionFailure(
                """
                CORS: allowedOrigins .any cannot be combined with allowCredentials. \
                A browser rejects `Access-Control-Allow-Origin: *` on a credentialed \
                request, so this configuration cannot work. Name the origins with \
                .exact([...]) or decide per request with .matching { ... }.
                """)
        }
        self.allowedOrigins = allowedOrigins
        self.allowedMethods = allowedMethods
        self.allowedHeaders = allowedHeaders
        self.exposedHeaders = exposedHeaders
        self.allowCredentials = allowCredentials
        self.maxAge = maxAge
    }

    public func handle(_ context: RequestContext, next: Next) async throws -> Response {
        guard let origin = context.request.headers[.origin] else {
            return try await next(context)  // not a cross-origin request
        }

        if isPreflight(context.request) {
            return preflightResponse(origin: origin, request: context.request)
        }

        let response = try await next(context)
        guard allowedOrigins.allows(origin) else {
            // No headers: the browser withholds the response from the page.
            // The request already ran, which is correct — CORS governs who
            // may *read* an answer, and has never been a request firewall.
            return vary(response, on: [.origin])
        }
        var answered = response
            .settingHeader(.accessControlAllowOrigin, allowOriginValue(for: origin))
        if allowCredentials {
            answered = answered.settingHeader(.accessControlAllowCredentials, "true")
        }
        if !exposedHeaders.isEmpty {
            answered = answered.settingHeader(
                .accessControlExposeHeaders,
                exposedHeaders.map(\.canonicalName).joined(separator: ", "))
        }
        return allowedOrigins.isConstant ? answered : vary(answered, on: [.origin])
    }

    /// `OPTIONS` alone is not a preflight — a service may route one — so the
    /// request method header is what distinguishes it (Fetch §3.2.2).
    private func isPreflight(_ request: Request) -> Bool {
        request.method == .options && request.headers[.accessControlRequestMethod] != nil
    }

    private func preflightResponse(origin: String, request: Request) -> Response {
        // Every preflight answer varies on all three, including the refusals:
        // a cache must not reuse one origin's refusal for another origin.
        let varyOn: [HTTPField.Name] = [
            .origin, .accessControlRequestMethod, .accessControlRequestHeaders,
        ]
        guard allowedOrigins.allows(origin) else {
            return vary(
                .problem(status: .forbidden, message: "origin '\(origin)' is not allowed"),
                on: varyOn)
        }
        let requested = request.headers[.accessControlRequestMethod].map {
            HTTPRequest.Method($0) ?? .get
        }
        guard let requested, allowedMethods.contains(requested) else {
            let named = request.headers[.accessControlRequestMethod] ?? "none"
            return vary(
                .problem(
                    status: .forbidden,
                    message: "method '\(named)' is not allowed for cross-origin requests"),
                on: varyOn)
        }

        var response = Response.status(.noContent)
            .settingHeader(.accessControlAllowOrigin, allowOriginValue(for: origin))
            .settingHeader(
                .accessControlAllowMethods,
                allowedMethods.map(\.rawValue).joined(separator: ", "))
        switch allowedHeaders {
        case .reflectingRequest:
            if let asked = request.headers[.accessControlRequestHeaders] {
                response = response.settingHeader(.accessControlAllowHeaders, asked)
            }
        case .exact(let names) where !names.isEmpty:
            response = response.settingHeader(
                .accessControlAllowHeaders,
                names.map(\.canonicalName).joined(separator: ", "))
        case .exact:
            break
        }
        if allowCredentials {
            response = response.settingHeader(.accessControlAllowCredentials, "true")
        }
        if let maxAge {
            response = response.settingHeader(
                .accessControlMaxAge, "\(maxAge.components.seconds)")
        }
        return vary(response, on: varyOn)
    }

    private func allowOriginValue(for origin: String) -> String {
        allowedOrigins.isConstant ? "*" : origin
    }

    /// Appending rather than replacing — a handler may have set its own
    /// (`Accept-Encoding`, `Accept-Language`), and overwriting it makes a
    /// shared cache serve one representation for all of them.
    private func vary(_ response: Response, on names: [HTTPField.Name]) -> Response {
        response.appendingVary(on: names)
    }
}
