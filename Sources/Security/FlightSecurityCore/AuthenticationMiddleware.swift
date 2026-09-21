import FlightCore
import FlightSessions
import FlightWeb
import HTTPTypes

/// Extracts the bearer token, validates it, and writes the resulting
/// ``Principal`` onto the copy of the request context it passes downstream.
/// Registered by ``FlightSecurityModule``.
///
/// Authentication is deliberately not enforcement: requests with no token,
/// and requests whose token fails validation, both continue as
/// unauthenticated. Rejection is ``RequireAuthentication``'s job (or a
/// handler-level guard), so public routes stay public.
///
/// A request with no bearer token but a session carrying a principal —
/// one `Session.signIn(_:)` stored — is authenticated from the session.
/// That is how a browser, which has a cookie and no token, is signed in. A
/// bearer token, when present, always wins: it is the fresher claim, and a
/// request that goes to the trouble of sending one means it. This layer
/// therefore conforms to `SessionReading`, and composition refuses a lane
/// that runs it ahead of `Sessions`.
///
/// `validator` arrives through the initializer like any other dependency —
/// there is no longer a separate "explicit validator, for manual wiring or
/// tests" entry point, because that entry point existed only to work around
/// a closure's inability to hold one. `Authentication(validator: someMock)`
/// is now the same call for both cases.
// flight:module-registered — `FlightSecurityModule` provides this, not the
// application's scan. It injects `(any TokenValidator)`, which only a security
// module supplies, so composing it into an app that includes no security
// module could not succeed; the marker keeps the build's scan from treating it
// as an app component of its own.
@Middleware
public struct Authentication: Sendable, SessionReading {
    // Parenthesized: the macro's generated `init(_flight:)` resolves this by
    // appending `.self` to the type text, and `any TokenValidator.self`
    // (unparenthesized) parses as a lookup for a nested type named `self`
    // inside the TokenValidator protocol, not as that existential's
    // metatype.
    // flight:hand-registered — the validator is registered by
    // FlightSecurityModule (or the application's own module), never scanned.
    @Inject var validator: (any TokenValidator)

    /// For manual wiring or tests, where `@Inject` has nothing to
    /// resolve from.
    public init(validator: any TokenValidator) {
        self.validator = validator
    }

    public func handle(_ context: RequestContext, next: Next) async throws -> Response {
        guard let token = context.request.bearerToken else {
            // No token. A session may still say who this is.
            if let session = context.session {
                do {
                    if let principal = try session.principal() {
                        return try await next(context.authenticated(as: principal))
                    }
                } catch {
                    // A stored principal that no longer decodes — a format
                    // change, or something else writing under the key.
                    // Anonymous rather than a 500 on every request until the
                    // cookie expires; the next sign-in overwrites it.
                    context.logger.warning(
                        "stored session principal did not decode; treating the request as anonymous",
                        metadata: ["reason": "\(error)"])
                }
            }
            // No credential: unauthenticated, not an error.
            return try await next(context)
        }
        do {
            let principal = try await validator.validate(token)
            return try await next(context.authenticated(as: principal))
        } catch {
            // Error hygiene: the specific reason stays in the internal log;
            // the wire sees nothing here, and enforcement points return a
            // generic 401.
            context.logger.info(
                "token validation failed",
                metadata: ["reason": "\(error)"]
            )
            var rejected = context
            rejected.identity = .invalidCredential
            return try await next(rejected)
        }
    }
}

extension RequestContext {
    /// One local copy carrying both the identity and the stamped logger to
    /// everything downstream. `RequestContext` is a value and the chain is
    /// layered, so writing into the copy handed to `next` is what makes the
    /// principal visible to the handler — no shared mutable holder, and
    /// nothing to resolve out of a scope.
    ///
    /// The subject is stamped onto the logger so downstream lines correlate;
    /// it is the IdP's opaque id, not PII Flight invents.
    fileprivate func authenticated(as principal: Principal) -> RequestContext {
        var authenticated = self
        authenticated.identity = .authenticated(principal)
        authenticated.logger[metadataKey: "auth.subject"] = "\(principal.subject)"
        return authenticated
    }
}

/// Rejects requests with no valid principal. Enforcement of
/// *authentication*, not authorization — "is there anyone here", not "is
/// this the right someone".
///
/// Not installed by ``FlightSecurityModule`` — an application adds it to its
/// own lane (after ``Authentication`` — it needs the
/// principal *this* request's authentication decided, not some other
/// request's) for the routes it wants protected. For selective protection,
/// use the handler-level guards (`context.requirePrincipal()` /
/// `requireRole` / `requireScope`) instead.
///
/// Responses carry an RFC 6750 `WWW-Authenticate: Bearer` challenge;
/// `error="invalid_token"` distinguishes a rejected credential from an
/// absent one — and nothing more (design: no detail reaches the wire).
// flight:module-registered — registered by `FlightSecurityModule` alongside
// `Authentication`. It has no dependencies of its own, so scanning it was
// harmless; it travels with `Authentication` because the two are one
// decision, and a half-registered pair is a confusing thing to debug.
@Middleware
public struct RequireAuthentication: Sendable {
    public init() {}

    public func handle(_ context: RequestContext, next: Next) async throws -> Response {
        switch context.authenticationState {
        case .authenticated:
            return try await next(context)
        case .anonymous:
            return .problem(status: .unauthorized, message: "Unauthorized")
                .settingHeader(.wwwAuthenticate, "Bearer")
        case .invalidCredential:
            return .problem(status: .unauthorized, message: "Unauthorized")
                .settingHeader(.wwwAuthenticate, #"Bearer error="invalid_token""#)
        }
    }
}
