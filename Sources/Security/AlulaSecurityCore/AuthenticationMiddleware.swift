import AlulaCore
import AlulaSessions
import AlulaWeb
import Foundation
import HTTPTypes
import TelemetryCore

/// Extracts the bearer token, validates it, and writes the resulting
/// ``Principal`` onto the copy of the request context it passes downstream.
/// Registered by ``AlulaSecurityModule``.
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
// alula:module-registered — `AlulaSecurityModule` provides this, not the
// application's scan. It injects `(any TokenValidator)`, which only a security
// module supplies, so composing it into an app that includes no security
// module could not succeed; the marker keeps the build's scan from treating it
// as an app component of its own.
@Middleware
public struct Authentication: Sendable, SessionReading {
    // Parenthesized: the macro's generated `init(_alula:)` resolves this by
    // appending `.self` to the type text, and `any TokenValidator.self`
    // (unparenthesized) parses as a lookup for a nested type named `self`
    // inside the TokenValidator protocol, not as that existential's
    // metatype.
    // alula:hand-registered — the validator is registered by
    // AlulaSecurityModule (or the application's own module), never scanned.
    @Inject var validator: (any TokenValidator)

    /// How long a session-backed sign-in lasts from the moment it happened,
    /// however active the session. Nil checks nothing — what a bearer-only
    /// stack, or a hand-built one, gets.
    private var authenticatedLifetime: Duration? = nil
    private var now: @Sendable () -> Date = Date.init

    /// For manual wiring or tests, where `@Inject` has nothing to
    /// resolve from.
    ///
    /// - Parameters:
    ///   - validator: How a bearer token is checked.
    ///   - authenticatedLifetime: The absolute lifetime of a session-backed
    ///     sign-in. `AlulaSecurityModule` passes
    ///     `sessions.authenticated-lifetime`.
    ///   - now: The clock the lifetime is measured on.
    ///
    /// A sign-in past its lifetime is reported as ``SignInEvents/Expired``.
    public init(
        validator: any TokenValidator,
        authenticatedLifetime: Duration? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.validator = validator
        self.authenticatedLifetime = authenticatedLifetime
        self.now = now
    }

    public func handle(_ context: RequestContext, next: Next) async throws -> Response {
        // Only establishing the identity is guarded here. `next` runs outside
        // every `do`: an error thrown further down the chain (CSRF, the
        // handler's middleware, a store) used to be caught as if the
        // credential had failed, logged as "token validation failed" or "did
        // not decode", and the rest of the chain run a second time — for a
        // bearer request, with a 401 in place of the real answer.
        try await next(authenticated(context))
    }

    /// The request with its identity settled: a principal, an invalid
    /// credential, or anonymous. Never throws for a bad credential.
    private func authenticated(_ context: RequestContext) async -> RequestContext {
        guard let token = context.request.bearerToken else {
            // No token. A session may still say who this is.
            guard let session = context.session else { return context }
            let principal: Principal?
            let withinLifetime: Bool
            do {
                principal = try session.principal()
                withinLifetime = principal == nil ? true : try isWithinLifetime(session)
            } catch {
                // A stored principal that no longer decodes — a format
                // change, or something else writing under the key.
                // Anonymous rather than a 500 on every request until the
                // cookie expires; the next sign-in overwrites it.
                context.logger.warning(
                    "stored session principal did not decode; treating the request as anonymous",
                    metadata: ["reason": "\(error)"])
                return context
            }
            guard let principal else { return context }
            guard withinLifetime else {
                // Past the absolute lifetime: signed out here, the rest of
                // the session kept, and the request goes on anonymous — a
                // protected route answers 401 and the browser signs in again.
                context.logger.info(
                    "session sign-in past its absolute lifetime; signing out",
                    metadata: ["subject": "\(principal.subject)"])
                session.signOut()
                Telemetry.emit(SignInEvents.Expired.self)
                return context
            }
            return context.authenticated(as: principal)
        }
        do {
            return context.authenticated(as: try await validator.validate(token))
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
            return rejected
        }
    }
}

extension Authentication {
    /// Whether the session's sign-in is still inside the absolute lifetime.
    ///
    /// A sign-in recorded before the time was kept has none; it is stamped
    /// now, once, rather than signed out — every browser signed in before an
    /// upgrade would otherwise be signed out at once. It gets one full
    /// lifetime from here, which is still a bound.
    fileprivate func isWithinLifetime(_ session: Session) throws -> Bool {
        guard let authenticatedLifetime else { return true }
        let now = now()
        guard let signedInAt = try session.authenticatedAt() else {
            try session.set(Session.authenticatedAtKey, now)
            return true
        }
        return now.timeIntervalSince(signedInAt) < authenticatedLifetime.timeIntervalValue
    }
}

extension Duration {
    fileprivate var timeIntervalValue: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
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
    /// it is the IdP's opaque id, not PII Alula invents.
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
/// Not installed by ``AlulaSecurityModule`` — an application adds it to its
/// own lane (after ``Authentication`` — it needs the
/// principal *this* request's authentication decided, not some other
/// request's) for the routes it wants protected. For selective protection,
/// use the handler-level guards (`context.requirePrincipal()` /
/// `requireRole` / `requireScope`) instead.
///
/// Responses carry an RFC 6750 `WWW-Authenticate: Bearer` challenge;
/// `error="invalid_token"` distinguishes a rejected credential from an
/// absent one — and nothing more (design: no detail reaches the wire).
// alula:module-registered — registered by `AlulaSecurityModule` alongside
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
