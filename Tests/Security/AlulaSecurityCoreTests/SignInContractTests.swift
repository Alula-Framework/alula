import AlulaCore
import AlulaRateLimit
import AlulaRateLimitTesting
import AlulaSessionsTesting
import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import JWTKit
import Synchronization
import Testing

@testable import AlulaSecurityCore

/// One controller, written once against the seam. The contract suite runs it
/// with each provider and requires the same answers.
@Controller("/auth")
private struct SignInController {
    @Inject var provider: any SignInProvider

    struct Me: Codable, ResponseEncodable, Equatable {
        let subject: String
        let email: String?
        let emailVerified: Bool
        let name: String?
        let preferredUsername: String?
        let roles: [String]
    }

    @GetRoute("/sign-in")
    func begin(_ context: RequestContext) async throws -> Response {
        try await provider.beginSignIn(context, returnTo: context.request.queryParam("return-to"))
            .response()
    }

    @PostRoute("/sign-in")
    func submit(_ context: RequestContext) async throws -> Response {
        try await provider.signIn(context).response()
    }

    @GetRoute("/callback")
    func callback(_ context: RequestContext) async throws -> Response {
        try await provider.signIn(context).response()
    }

    @PostRoute("/sign-out")
    func signOut(_ context: RequestContext) async throws -> Response {
        try await provider.signOut(context).response()
    }

    @GetRoute("/me", pipelines: [.authenticated])
    func me(_ context: RequestContext) throws -> Me {
        let principal = try context.requirePrincipal()
        return Me(
            subject: principal.subject, email: principal.email,
            emailVerified: principal.emailVerified, name: principal.name,
            preferredUsername: principal.preferredUsername, roles: principal.roles.sorted())
    }
}

/// Serves discovery from memory.
private struct DiscoveryHTTP: HTTPGetting {
    let document: Data
    func getJSON(_ url: URL) async throws -> Data { document }
}

/// A token endpoint that answers with an ID token minted on demand, for the
/// nonce the begin step sent.
private final class MintingTokenEndpoint: HTTPFormPosting, Sendable {
    let token = Mutex<String?>(nil)
    func postForm(
        _ url: URL, fields: [(String, String)],
        basicAuthorization: (user: String, password: String)?
    ) async throws -> (status: Int, body: Data) {
        guard let token = token.withLock({ $0 }) else {
            return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        return (200, Data(#"{"id_token":"\#(token)"}"#.utf8))
    }
    func getWithBearer(_ url: URL, token: String) async throws -> (status: Int, body: Data) {
        (404, Data())
    }
}

@Suite("Sign-in contract: one controller, either provider")
struct SignInContractTests {
    private let sessionStore = RecordingSessionStore()
    private let clock = TestClock()
    private static let expected = SignInController.Me(
        subject: "user-1", email: "ada@example.com", emailVerified: true, name: "Ada Lovelace",
        preferredUsername: "ada", roles: ["author"])

    /// The middleware an application composes: Sessions, and the security
    /// lanes with sessions and no bearer validator at all.
    private func client(_ provider: any SignInProvider) throws -> TestClient {
        let sessions = try AlulaSessionsModule(
            configuration: Configuration(values: ["sessions.cookie-secure": "false"]),
            store: sessionStore)
        let security = AlulaSecurityModule(validator: nil, sessions: sessions.runtime)
        return try TestClient(
            routes: SignInController.alulaRoutes { _ in SignInController(provider: provider) },
            middleware: sessions.middleware + security.middleware)
    }

    private func cookie(_ response: Response) -> String? {
        response.headerValues("Set-Cookie")
            .compactMap { $0.split(separator: ";").first.map(String.init) }
            .first { $0.hasPrefix("session=") }
    }

    // MARK: The two providers

    private func passwordProvider() throws -> PasswordSignIn {
        let fast = Argon2idHashing(parameters: .init(timeCost: 1, memoryCost: 8, parallelism: 1))
        let store = InMemoryCredentialStore()
        store.insert(
            StoredCredential(
                subject: "user-1", passwordHash: try fast.hash("correct horse"), roles: ["author"],
                email: "ada@example.com", emailVerified: true, name: "Ada Lovelace",
                preferredUsername: "ada"),
            identifiers: ["ada@example.com"])
        return PasswordSignIn(
            authenticator: PasswordAuthenticator(
                store: store, issuer: "local", hasher: fast,
                limiter: RateLimiter(store: RecordingRateLimitStore())))
    }

    private func oidcProvider() throws -> (OIDCSignIn, TestIdentity, MintingTokenEndpoint) {
        let identity = TestIdentity(kid: "k1")
        let endpoint = MintingTokenEndpoint()
        let discovery = """
            {"issuer":"\(testIssuer)","authorization_endpoint":"https://idp.example.com/authorize",
             "token_endpoint":"https://idp.example.com/token"}
            """
        let provider = OIDCSignIn(
            configuration: try OIDCSignInConfiguration(
                issuer: testIssuer, clientID: "my-app",
                redirectURI: URL(string: "https://app.example.com/auth/callback")!),
            http: DiscoveryHTTP(document: Data(discovery.utf8)), poster: endpoint,
            jwksSource: try InMemoryJWKSSource(json: jwksJSON([identity])), now: clock.nowProvider)
        return (provider, identity, endpoint)
    }

    // MARK: The contract

    @Test("password: begin describes a form, submit signs in, /me shows the standard claims")
    func passwordContract() async throws {
        let client = try client(try passwordProvider())
        #expect(await client.get("/auth/me").status == .unauthorized)

        let begin = await client.get("/auth/sign-in?return-to=/rooms")
        #expect(begin.status == .ok)
        let form = try begin.decodeJSON(SignInForm.self)
        #expect(form.fields.map(\.name) == ["identifier", "password"])
        #expect(form.returnTo == "/rooms")

        // Form-encoded, as a plain HTML form posts it.
        let submit = await client.post(
            "/auth/sign-in", headers: [.contentType: "application/x-www-form-urlencoded"],
            body: Data("identifier=ada%40example.com&password=correct+horse&returnTo=%2Frooms".utf8)
        )
        #expect(submit.status == .seeOther)
        #expect(submit.header("Location") == "/rooms")
        let session = try #require(cookie(submit))

        let me = await client.get("/auth/me", headers: [.cookie: session])
        #expect(try me.decodeJSON(SignInController.Me.self) == Self.expected)
    }

    @Test("OIDC: begin redirects, the callback signs in, /me shows the same standard claims")
    func oidcContract() async throws {
        let (provider, identity, endpoint) = try oidcProvider()
        let client = try client(provider)

        let begin = await client.get("/auth/sign-in?return-to=/rooms")
        #expect(begin.status == .seeOther)
        let location = try #require(begin.header("Location").flatMap(URL.init(string:)))
        let sent = Dictionary(
            (URLComponents(url: location, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let pendingCookie = try #require(cookie(begin), "the pending sign-in lives in the session")

        // What the provider asserts: the same person, by the same claim names.
        let token = try await identity.sign(
            standardClaims(
                now: clock.now, subject: "user-1", audience: .string("my-app"),
                extra: [
                    "nonce": .string(sent["nonce"]!), "email": .string("ada@example.com"),
                    "email_verified": .bool(true), "name": .string("Ada Lovelace"),
                    "preferred_username": .string("ada"), "roles": .array([.string("author")]),
                ]))
        endpoint.token.withLock { $0 = token }

        let callback = await client.get(
            "/auth/callback?code=abc&state=\(sent["state"]!)", headers: [.cookie: pendingCookie])
        #expect(callback.status == .seeOther)
        #expect(callback.header("Location") == "/rooms")
        let session = try #require(cookie(callback))

        let me = await client.get("/auth/me", headers: [.cookie: session])
        #expect(try me.decodeJSON(SignInController.Me.self) == Self.expected)
    }

    @Test("signing out through the seam ends the session for either provider")
    func signOutContract() async throws {
        let client = try client(try passwordProvider())
        let submit = try await client.post(
            "/auth/sign-in",
            json: ["identifier": "ada@example.com", "password": "correct horse"])
        #expect(submit.status == .noContent, "no returnTo: nowhere to go")
        let session = try #require(cookie(submit))
        let out = await client.post("/auth/sign-out", headers: [.cookie: session])
        #expect(out.status == .noContent)
        #expect(await client.get("/auth/me", headers: [.cookie: session]).status == .unauthorized)
    }

    // MARK: Without a bearer validator

    @Test("with no token validator, a bearer token is an invalid credential, not anonymous")
    func bearerWithoutValidator() async throws {
        let client = try client(try passwordProvider())
        let response = await client.get(
            "/auth/me", headers: [.authorization: "Bearer something"])
        #expect(response.status == .unauthorized)
    }

    // MARK: Return paths

    @Test("only a path on this site survives as a return path")
    func returnPaths() {
        #expect(SignInReturnPath.validated("/rooms/general?tab=2") == "/rooms/general?tab=2")
        for hostile in [
            "https://evil.example.com", "//evil.example.com", "/\\evil.example.com",
            "rooms", "", "/ok\r\nSet-Cookie: x", "javascript:alert(1)",
        ] {
            #expect(SignInReturnPath.validated(hostile) == nil, "\(hostile)")
        }
        #expect(SignInReturnPath.validated(nil) == nil)
    }
}
