// Every shape Docs/sign-in.md claims, compiled. A rename that invalidates the
// prose breaks the build.

import FlightCore
import FlightRateLimit
import FlightSecurityCore
import FlightSessions
import FlightWeb
import Foundation

// The routes, written once against the seam.
@Controller("/auth")
private struct SignInController {
    @Inject var provider: any SignInProvider

    @GetRoute("/sign-in")
    func begin(_ context: RequestContext) async throws -> Response {
        try await provider.beginSignIn(context, returnTo: context.request.queryParam("return-to"))
            .response()
    }

    @PostRoute("/sign-in", pipelines: [.default, "csrf"])
    func submit(_ context: RequestContext) async throws -> Response {
        try await provider.signIn(context).response()
    }

    @GetRoute("/callback")
    func callback(_ context: RequestContext) async throws -> Response {
        try await provider.signIn(context).response()
    }

    @PostRoute("/sign-out", pipelines: [.default, "csrf"])
    func signOut(_ context: RequestContext) async throws -> Response {
        try await provider.signOut(context).response()
    }
}

// A credential store over the application's own accounts.
private struct Account {
    let id: UUID
    let email: String
    let passwordHash: String?
    let roles: [String]
    let disabledAt: Date?
    let emailVerifiedAt: Date?
    let displayName: String?
}

private protocol AccountRepository: Sendable {
    func find(email: String) async throws -> Account?
    func setPasswordHash(_ hash: String, id: UUID) async throws
}

private struct AccountCredentials: CredentialStore {
    let accounts: any AccountRepository

    func credential(forIdentifier identifier: String) async throws -> StoredCredential? {
        guard let account = try await accounts.find(email: identifier) else { return nil }
        return StoredCredential(
            subject: account.id.uuidString,
            passwordHash: account.passwordHash,
            roles: Set(account.roles),
            isDisabled: account.disabledAt != nil,
            email: account.email, emailVerified: account.emailVerifiedAt != nil,
            name: account.displayName)
    }

    func updatePasswordHash(_ hash: String, forSubject subject: String) async throws {
        try await accounts.setPasswordHash(hash, id: UUID(uuidString: subject)!)
    }
}

// The pieces by hand, as the modules assemble them.
func signInShapes(configuration: Configuration, store: any CredentialStore, limiter: RateLimiter)
    throws
{
    let authenticator = PasswordAuthenticator(store: store, issuer: "local", limiter: limiter)
    _ = try authenticator.hashNewPassword("correct horse")
    let _: any SignInProvider = PasswordSignIn(authenticator: authenticator)
    _ = try FlightPasswordSignInModule(configuration: configuration, store: store, limiter: limiter)

    let oidc = try OIDCSignInConfiguration(
        issuer: "https://keycloak.example.com/realms/main", clientID: "my-app",
        clientSecret: "…", redirectURI: URL(string: "https://app.example.com/auth/callback")!,
        postLogoutRedirectURI: URL(string: "https://app.example.com/")!)
    let _: any SignInProvider = OIDCSignIn(configuration: oidc)
    _ = SignInReturnPath.validated("/rooms")
}

// One-time links and signing out everywhere.
func oneTimeShapes(
    tokenStore: any OneTimeTokenStore, sessions: SessionRuntime, context: RequestContext,
    subject: String, passwordHash: String
) async throws {
    let tokens = OneTimeTokens(store: tokenStore)
    let token = try await tokens.issue(
        for: subject, purpose: .passwordReset, lifetime: .seconds(3600), binding: passwordHash)
    _ = try await tokens.redeem(token, purpose: .passwordReset) { _ in passwordHash }
    _ = InMemoryOneTimeTokenStore()

    try await sessions.revokeSessions(ownedBy: subject, keeping: context.requireSession().id)
    try await sessions.revokeSessions(ownedBy: subject)
}

// The 0.33 session settings, and a metrics factory for tests.
func sessionHardeningShapes(store: any SessionStore) throws {
    let settings = try SessionSettings(
        ttl: .seconds(14 * 24 * 3600), authenticatedLifetime: .seconds(12 * 3600),
        cookieHostPrefix: true)
    _ = settings.effectiveCookieName  // "__Host-session"
    _ = SessionRuntime(store: store, settings: settings)
    _ = SessionMetrics.created
    _ = SignInMetrics.attempts
}
