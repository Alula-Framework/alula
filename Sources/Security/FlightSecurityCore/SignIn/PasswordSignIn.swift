import FlightWeb

/// Sign-in against the application's own ``CredentialStore``: a form of two
/// fields, checked by a ``PasswordAuthenticator``.
///
/// The submission is JSON or form-encoded — `identifier`, `password`, and
/// optionally `returnTo` — so both a script and a plain HTML form can post
/// it. That second one is why the route it posts to belongs on the `csrf`
/// lane: a form on any site can submit the same shape (see `Docs/web.md`,
/// "Guard sign-in too").
public struct PasswordSignIn: SignInProvider {
    public let authenticator: PasswordAuthenticator

    public init(authenticator: PasswordAuthenticator) {
        self.authenticator = authenticator
    }

    /// What the form posts. Field names match ``form``.
    public struct Submission: Decodable, Sendable {
        public var identifier: String
        public var password: String
        public var returnTo: String?
    }

    /// The two fields, with the `autocomplete` tokens password managers key
    /// on — `username` rather than `email`, because the store decides what
    /// an identifier is.
    public static let form = SignInForm(fields: [
        .init(name: "identifier", kind: .text, autocomplete: "username"),
        .init(name: "password", kind: .password, autocomplete: "current-password"),
    ])

    public func beginSignIn(_ context: RequestContext, returnTo: String?) async throws -> SignInStep
    {
        var form = Self.form
        form.returnTo = SignInReturnPath.validated(returnTo)
        return .form(form)
    }

    public func completeSignIn(_ context: RequestContext) async throws -> SignInResult {
        let submission = try decodeRequestBody(Submission.self, from: context)
        let principal = try await authenticator.authenticate(
            identifier: submission.identifier, password: submission.password,
            clientAddress: context.clientAddress?.host)
        return SignInResult(
            principal: principal, returnTo: SignInReturnPath.validated(submission.returnTo))
    }

    public func beginSignOut(_ context: RequestContext) async throws -> SignOutStep { .done }
}
