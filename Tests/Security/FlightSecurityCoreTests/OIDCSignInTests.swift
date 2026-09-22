import FlightCore
import FlightSessions
import FlightWeb
import Foundation
import HTTPTypes
import JWTKit
import Logging
import Synchronization
import Testing

@testable import FlightSecurityCore

/// Serves the discovery document from memory.
private final class FakeHTTP: HTTPGetting, Sendable {
    private let documents: Mutex<[String: Data]>
    init(_ documents: [String: Data]) { self.documents = Mutex(documents) }
    func getJSON(_ url: URL) async throws -> Data {
        guard let data = documents.withLock({ $0[url.absoluteString] }) else {
            throw URLError(.fileDoesNotExist)
        }
        return data
    }
}

/// The token endpoint, answering with whatever the test sets.
private final class FakeTokenEndpoint: HTTPFormPosting, Sendable {
    struct Call: Sendable {
        let url: URL
        let fields: [String: String]
        let basicUser: String?
        let basicPassword: String?
    }
    private let calls = Mutex<[Call]>([])
    private let answer = Mutex<(Int, Data)>((500, Data()))

    var last: Call? { calls.withLock { $0.last } }
    func respond(status: Int = 200, json: String) {
        answer.withLock { $0 = (status, Data(json.utf8)) }
    }

    func postForm(
        _ url: URL, fields: [(String, String)],
        basicAuthorization: (user: String, password: String)?
    ) async throws -> (status: Int, body: Data) {
        calls.withLock {
            $0.append(
                Call(
                    url: url, fields: Dictionary(fields, uniquingKeysWith: { $1 }),
                    basicUser: basicAuthorization?.user, basicPassword: basicAuthorization?.password
                ))
        }
        let (status, body) = answer.withLock { $0 }
        return (status, body)
    }
}

@Suite("OIDCSignIn")
struct OIDCSignInTests {
    private let clock = TestClock()
    private let identity = TestIdentity(kid: "k1")
    private let tokens = FakeTokenEndpoint()

    private static let discovery = """
        {"issuer":"\(testIssuer)",
         "authorization_endpoint":"https://idp.example.com/authorize?prompt=login",
         "token_endpoint":"https://idp.example.com/token",
         "end_session_endpoint":"https://idp.example.com/logout",
         "code_challenge_methods_supported":["S256"]}
        """

    private func provider(
        secret: String? = nil, discovery: String = discovery
    ) throws -> OIDCSignIn {
        let configuration = try OIDCSignInConfiguration(
            issuer: testIssuer, clientID: "my-app", clientSecret: secret,
            redirectURI: URL(string: "https://app.example.com/auth/callback")!,
            postLogoutRedirectURI: URL(string: "https://app.example.com/")!)
        return OIDCSignIn(
            configuration: configuration,
            http: FakeHTTP([
                testIssuer + "/.well-known/openid-configuration": Data(discovery.utf8)
            ]),
            poster: tokens,
            jwksSource: try InMemoryJWKSSource(json: jwksJSON([identity])),
            now: clock.nowProvider)
    }

    private func context(_ session: Session, query: String = "") -> RequestContext {
        RequestContext(
            request: Request(path: "/auth/callback" + (query.isEmpty ? "" : "?" + query)),
            session: session, logger: Logger(label: "test"))
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    /// Begins a sign-in and returns the parameters the provider was sent.
    private func begin(
        _ provider: OIDCSignIn, _ session: Session, returnTo: String? = "/rooms/general"
    ) async throws -> [String: String] {
        guard
            case .redirect(let url) = try await provider.beginSignIn(
                context(session), returnTo: returnTo)
        else {
            Issue.record("expected a redirect")
            return [:]
        }
        return query(url)
    }

    private func idToken(
        nonce: String?, audience: String = "my-app", extra: [String: JSONValue] = [:]
    ) async throws -> String {
        var claims = extra
        if let nonce { claims["nonce"] = .string(nonce) }
        claims["email"] = .string("ada@example.com")
        claims["email_verified"] = .bool(true)
        claims["name"] = .string("Ada Lovelace")
        claims["preferred_username"] = .string("ada")
        claims["roles"] = .array([.string("author")])
        return try await identity.sign(
            standardClaims(
                now: clock.now, subject: "kc-123", audience: .string(audience), extra: claims))
    }

    // MARK: PKCE

    @Test("the S256 challenge matches RFC 7636 Appendix B's test vector")
    func pkceVector() {
        #expect(
            OIDCSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("random tokens are 43 base64url characters and differ")
    func randomTokens() {
        let token = OIDCSignIn.randomToken()
        #expect(token.count == 43)
        #expect(!token.contains("+") && !token.contains("/") && !token.contains("="))
        #expect(token != OIDCSignIn.randomToken())
    }

    // MARK: Begin

    @Test("beginning sends the browser to the provider with code flow, PKCE, state and nonce")
    func beginRedirects() async throws {
        let session = Session()
        let parameters = try await begin(try provider(), session)
        #expect(parameters["response_type"] == "code")
        #expect(parameters["client_id"] == "my-app")
        #expect(parameters["redirect_uri"] == "https://app.example.com/auth/callback")
        #expect(parameters["scope"] == "openid profile email")
        #expect(parameters["code_challenge_method"] == "S256")
        #expect(parameters["prompt"] == "login", "the endpoint's own query survives")
        let pending = try #require(
            try session.get(PendingSignIn.sessionKey, as: [PendingSignIn].self)?.first)
        #expect(parameters["state"] == pending.state)
        #expect(parameters["nonce"] == pending.nonce)
        #expect(parameters["code_challenge"] == OIDCSignIn.challenge(for: pending.verifier))
        #expect(pending.returnTo == "/rooms/general")
    }

    @Test("a returnTo that leaves the site is dropped, not carried")
    func unsafeReturnTo() async throws {
        let session = Session()
        _ = try await begin(try provider(), session, returnTo: "//evil.example.com/")
        let pending = try #require(
            try session.get(PendingSignIn.sessionKey, as: [PendingSignIn].self)?.first)
        #expect(pending.returnTo == nil)
    }

    @Test("at most five sign-ins are open at once; the oldest goes")
    func pendingIsBounded() async throws {
        let session = Session()
        let provider = try provider()
        var states: [String] = []
        for _ in 0..<7 { states.append(try await begin(provider, session)["state"]!) }
        let open = try #require(try session.get(PendingSignIn.sessionKey, as: [PendingSignIn].self))
        #expect(open.map(\.state) == Array(states.suffix(5)))
    }

    // MARK: Complete

    @Test("the callback exchanges the code with the verifier and yields the standard claims")
    func completes() async throws {
        let session = Session()
        let provider = try provider()
        let sent = try await begin(provider, session)
        tokens.respond(
            json:
                #"{"id_token":"\#(try await idToken(nonce: sent["nonce"]))","token_type":"Bearer"}"#
        )

        let result = try await provider.completeSignIn(
            context(session, query: "code=abc&state=\(sent["state"]!)"))
        #expect(result.principal.subject == "kc-123")
        #expect(result.principal.issuer == testIssuer)
        #expect(result.principal.email == "ada@example.com")
        #expect(result.principal.emailVerified)
        #expect(result.principal.name == "Ada Lovelace")
        #expect(result.principal.preferredUsername == "ada")
        #expect(result.principal.roles == ["author"])
        #expect(result.returnTo == "/rooms/general")

        let call = try #require(tokens.last)
        #expect(call.url.absoluteString == "https://idp.example.com/token")
        #expect(call.fields["grant_type"] == "authorization_code")
        #expect(call.fields["code"] == "abc")
        #expect(call.fields["redirect_uri"] == "https://app.example.com/auth/callback")
        #expect(
            OIDCSignIn.challenge(for: call.fields["code_verifier"] ?? "") == sent["code_challenge"])
        #expect(call.fields["client_id"] == "my-app", "a public client names itself in the body")
        #expect(call.basicUser == nil)
    }

    @Test("a confidential client authenticates with HTTP Basic, not the body")
    func confidentialClient() async throws {
        let session = Session()
        let provider = try provider(secret: "s3cret")
        let sent = try await begin(provider, session)
        tokens.respond(json: #"{"id_token":"\#(try await idToken(nonce: sent["nonce"]))"}"#)
        _ = try await provider.completeSignIn(
            context(session, query: "code=abc&state=\(sent["state"]!)"))
        let call = try #require(tokens.last)
        #expect(call.basicUser == "my-app")
        #expect(call.basicPassword == "s3cret")
        #expect(call.fields["client_id"] == nil)
    }

    @Test("signIn puts the principal in the session and regenerates its id")
    func signInWritesSession() async throws {
        let session = Session()
        let provider = try provider()
        let sent = try await begin(provider, session)
        tokens.respond(json: #"{"id_token":"\#(try await idToken(nonce: sent["nonce"]))"}"#)
        _ = try await provider.signIn(context(session, query: "code=abc&state=\(sent["state"]!)"))
        #expect(try session.principal()?.subject == "kc-123")
        #expect(try session.principal()?.email == "ada@example.com")
    }

    // MARK: Refusals

    @Test("a callback is single use: replaying it finds nothing")
    func replay() async throws {
        let session = Session()
        let provider = try provider()
        let sent = try await begin(provider, session)
        tokens.respond(json: #"{"id_token":"\#(try await idToken(nonce: sent["nonce"]))"}"#)
        let callback = context(session, query: "code=abc&state=\(sent["state"]!)")
        _ = try await provider.completeSignIn(callback)
        await #expect(throws: OIDCSignInError.invalidCallback("unknown or expired state")) {
            try await provider.completeSignIn(callback)
        }
    }

    @Test("a state this session never issued is refused before any exchange")
    func unknownState() async throws {
        let session = Session()
        let provider = try provider()
        _ = try await begin(provider, session)
        await #expect(throws: OIDCSignInError.invalidCallback("unknown or expired state")) {
            try await provider.completeSignIn(context(session, query: "code=abc&state=forged"))
        }
        #expect(tokens.last == nil, "nothing was sent to the token endpoint")
    }

    @Test("a sign-in older than its lifetime has expired")
    func expired() async throws {
        let session = Session()
        let provider = try provider()
        let sent = try await begin(provider, session)
        clock.advance(by: 601)
        await #expect(throws: OIDCSignInError.invalidCallback("unknown or expired state")) {
            try await provider.completeSignIn(
                context(session, query: "code=abc&state=\(sent["state"]!)"))
        }
    }

    @Test("an ID token carrying another sign-in's nonce is refused")
    func nonceMismatch() async throws {
        let session = Session()
        let provider = try provider()
        let sent = try await begin(provider, session)
        tokens.respond(json: #"{"id_token":"\#(try await idToken(nonce: "someone-elses"))"}"#)
        await #expect(throws: OIDCSignInError.invalidIDToken("nonce does not match")) {
            try await provider.completeSignIn(
                context(session, query: "code=abc&state=\(sent["state"]!)"))
        }
    }

    @Test("an ID token issued to another client is refused")
    func wrongAudience() async throws {
        let session = Session()
        let provider = try provider()
        let sent = try await begin(provider, session)
        tokens.respond(
            json:
                #"{"id_token":"\#(try await idToken(nonce: sent["nonce"], audience: "other-app"))"}"#
        )
        do {
            _ = try await provider.completeSignIn(
                context(session, query: "code=abc&state=\(sent["state"]!)"))
            Issue.record("expected a refusal")
        } catch OIDCSignInError.invalidIDToken {}
    }

    @Test("the provider sending back an error is a refusal, not a fault")
    func providerError() async throws {
        let session = Session()
        _ = try await begin(try provider(), session)
        await #expect(throws: OIDCSignInError.providerRefused("access_denied")) {
            try await provider().completeSignIn(
                context(session, query: "error=access_denied&state=x"))
        }
        #expect(OIDCSignInError.providerRefused("access_denied").httpStatus == .unauthorized)
    }

    @Test("a token endpoint that refuses is a 502 with its error code in the log detail")
    func exchangeRefused() async throws {
        let session = Session()
        let provider = try provider()
        let sent = try await begin(provider, session)
        tokens.respond(status: 400, json: #"{"error":"invalid_grant"}"#)
        await #expect(throws: OIDCSignInError.tokenExchange("HTTP 400: invalid_grant")) {
            try await provider.completeSignIn(
                context(session, query: "code=abc&state=\(sent["state"]!)"))
        }
        #expect(OIDCSignInError.tokenExchange("x").httpStatus == .badGateway)
        #expect(OIDCSignInError.tokenExchange("x").httpMessage == "Sign-in provider unavailable")
    }

    // MARK: Discovery

    @Test("a discovery document asserting another issuer is refused")
    func discoveryIssuerMismatch() async throws {
        let forged = Self.discovery.replacingOccurrences(
            of: "\"issuer\":\"\(testIssuer)\"", with: "\"issuer\":\"https://evil.example.com\"")
        do {
            _ = try await provider(discovery: forged).beginSignIn(context(Session()), returnTo: nil)
            Issue.record("expected a refusal")
        } catch OIDCSignInError.discovery {}
    }

    @Test("a plaintext token endpoint is refused under the default transport policy")
    func plaintextEndpoint() async throws {
        let downgraded = Self.discovery.replacingOccurrences(
            of: "https://idp.example.com/token", with: "http://idp.example.com/token")
        do {
            _ = try await provider(discovery: downgraded).beginSignIn(
                context(Session()), returnTo: nil)
            Issue.record("expected a refusal")
        } catch OIDCSignInError.discovery {}
    }

    // MARK: Sign out

    @Test("signing out redirects to the provider's end-session endpoint and clears the session")
    func signOut() async throws {
        let session = Session()
        try session.signIn(Principal(subject: "kc-123", issuer: testIssuer))
        let step = try await provider().signOut(context(session))
        guard case .redirect(let url) = step else {
            Issue.record("expected a redirect")
            return
        }
        #expect(url.host == "idp.example.com")
        #expect(query(url)["client_id"] == "my-app")
        #expect(query(url)["post_logout_redirect_uri"] == "https://app.example.com/")
        #expect(try session.principal() == nil)
    }

    // MARK: Configuration

    @Test("configuration is read from security.oidc, in either spelling")
    func configuration() throws {
        let configuration = try OIDCSignInConfiguration(
            configuration: Configuration(values: [
                "security.oidc.issuer": testIssuer,
                "security.oidc.client-id": "my-app",
                "security.oidc.client_secret": "s3cret",
                "security.oidc.redirect-uri": "https://app.example.com/auth/callback",
                "security.oidc.sign-in-scopes": "openid email",
            ]))
        #expect(configuration.clientID == "my-app")
        #expect(configuration.clientSecret == "s3cret")
        #expect(configuration.scopes == ["openid", "email"])
        #expect(
            configuration.validation.audience == "my-app", "an ID token's audience is the client")
    }

    @Test("missing client-id, a relative redirect-uri, or scopes without openid fail composition")
    func configurationRefusals() {
        let base: [String: String] = [
            "security.oidc.issuer": testIssuer,
            "security.oidc.client-id": "my-app",
            "security.oidc.redirect-uri": "https://app.example.com/cb",
        ]
        for (key, value) in [
            ("security.oidc.client-id", nil), ("security.oidc.redirect-uri", "/cb"),
            ("security.oidc.sign-in-scopes", "profile email"),
        ] as [(String, String?)] {
            var values = base
            values[key] = value
            #expect(throws: OIDCSignInError.self) {
                try OIDCSignInConfiguration(configuration: Configuration(values: values))
            }
        }
    }
}
