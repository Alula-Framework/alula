import AlulaWeb
import Foundation

/// How an interactive sign-in happens — the seam that lets an application
/// start on its own passwords and move to Keycloak, Auth0 or any OpenID
/// Connect provider by changing which module it lists, not its routes.
///
/// Every provider answers the same two questions. **What does starting look
/// like?** Either "show a form with these fields" (``PasswordSignIn``) or
/// "send the browser there" (``OIDCSignIn``). **What does finishing look
/// like?** A ``Principal`` carrying the same ``Principal/StandardClaim``s
/// whichever provider produced it, which the route puts in the session.
///
/// ```swift
/// @Inject var provider: any SignInProvider
///
/// @GetRoute("/sign-in")
/// func begin(_ context: RequestContext) async throws -> Response {
///     try await provider.beginSignIn(context, returnTo: context.request.queryParam("return-to"))
///         .response()
/// }
///
/// @PostRoute("/sign-in", pipelines: [.default, "csrf"])   // the password provider posts here
/// func submit(_ context: RequestContext) async throws -> Response {
///     try await provider.signIn(context).response()
/// }
///
/// @GetRoute("/sign-in/callback")                          // an OIDC provider returns here
/// func callback(_ context: RequestContext) async throws -> Response {
///     try await provider.signIn(context).response()
/// }
/// ```
///
/// A front end written against this — ask to begin, then either render the
/// form it describes or follow the redirect — needs no change when the
/// provider does. That is the one part of a switch that would otherwise leak
/// into the UI.
public protocol SignInProvider: Sendable {
    /// Starts a sign-in. `returnTo` is where the browser goes afterwards; it
    /// must be a path on this site (see ``SignInReturnPath``), and a provider
    /// that leaves the site carries it through the round trip.
    func beginSignIn(_ context: RequestContext, returnTo: String?) async throws -> SignInStep

    /// Finishes a sign-in: a submitted form, or a callback from an external
    /// provider. Does not touch the session — ``signIn(_:)`` does that.
    func completeSignIn(_ context: RequestContext) async throws -> SignInResult

    /// What signing out means beyond the local session: nothing for a local
    /// provider, the provider's own logout endpoint for an external one.
    func beginSignOut(_ context: RequestContext) async throws -> SignOutStep
}

extension SignInProvider {
    /// ``completeSignIn(_:)``, then `Session.signIn(_:)` — which regenerates
    /// the session id, so an id planted before sign-in never becomes the
    /// signed-in one.
    public func signIn(_ context: RequestContext) async throws -> SignInResult {
        let result = try await completeSignIn(context)
        try context.requireSession().signIn(result.principal)
        return result
    }

    /// Asks the provider where signing out leads — which may read the
    /// session, as an OIDC provider does for its ID token hint — and then
    /// signs the session out.
    public func signOut(_ context: RequestContext) async throws -> SignOutStep {
        let step = try await beginSignOut(context)
        try context.requireSession().signOut()
        return step
    }
}

/// What starting a sign-in looks like.
public enum SignInStep: Sendable, Equatable {
    /// Show a form with these fields and post it back.
    case form(SignInForm)
    /// Send the browser here — an external provider's sign-in page.
    case redirect(URL)

    /// A form is `200` with its description as JSON; a redirect is `303`.
    public func response() throws -> Response {
        switch self {
        case .form(let form): try .json(form)
        case .redirect(let url): .redirect(to: url.absoluteString, .seeOther)
        }
    }
}

/// The fields a sign-in form needs, described rather than rendered — Alula
/// has no templating, and a front end already knows how to draw a field.
public struct SignInForm: Sendable, Equatable, Codable {
    public struct Field: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable {
            case text, email, password
        }
        public var name: String
        public var kind: Kind
        /// The `autocomplete` token browsers and password managers key on.
        public var autocomplete: String

        public init(name: String, kind: Kind, autocomplete: String) {
            self.name = name
            self.kind = kind
            self.autocomplete = autocomplete
        }
    }

    public var fields: [Field]
    /// Carried back in the submission so the result can say where to go.
    public var returnTo: String?

    public init(fields: [Field], returnTo: String? = nil) {
        self.fields = fields
        self.returnTo = returnTo
    }
}

/// A finished sign-in.
public struct SignInResult: Sendable {
    public var principal: Principal
    /// The validated path the browser asked to return to, if any.
    public var returnTo: String?

    public init(principal: Principal, returnTo: String? = nil) {
        self.principal = principal
        self.returnTo = returnTo
    }

    /// `303` to `returnTo`, or `204` when there is nowhere to go — the shape
    /// a script-driven sign-in wants.
    public func response() -> Response {
        guard let returnTo else { return .status(.noContent) }
        return .redirect(to: returnTo, .seeOther)
    }
}

/// What signing out looks like beyond the local session.
public enum SignOutStep: Sendable, Equatable {
    /// Nothing more: the session is all there was.
    case done
    /// The provider's own logout, so its session ends too.
    case redirect(URL)

    public func response() -> Response {
        switch self {
        case .done: .status(.noContent)
        case .redirect(let url): .redirect(to: url.absoluteString, .seeOther)
        }
    }
}

/// Where a sign-in may send the browser afterwards: a path on this site and
/// nothing else.
///
/// `returnTo` arrives from the request, so an unchecked one is an open
/// redirect — a link on this site's own sign-in page that ends somewhere
/// else, which is how phishing borrows a domain's trust. Anything that is not
/// a plain absolute path is dropped, not rejected: a bad `returnTo` should
/// cost the user a landing page, not their sign-in.
public enum SignInReturnPath {
    /// `raw` if it is a path on this site, nil otherwise.
    ///
    /// Refused: a scheme (`https://evil`), a protocol-relative `//evil`, a
    /// backslash (`/\evil`, which browsers normalize to `//`), control
    /// characters, and anything not starting with `/`.
    public static func validated(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), !raw.hasPrefix("//"),
            !raw.contains("\\"),
            !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return raw
    }
}
