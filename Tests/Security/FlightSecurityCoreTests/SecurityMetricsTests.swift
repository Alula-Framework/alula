import FlightCore
import FlightRateLimit
import FlightRateLimitTesting
import FlightSessions
import FlightSessionsTesting
import FlightWeb
import FlightWebTesting
import Foundation
import Logging
import MetricsTestKit
import Testing

@testable import FlightSecurityCore

/// The counters the audit asked for, asserted through an injected factory —
/// never the process-wide `MetricsSystem`, which suites running in parallel
/// would share.
@Suite("Security metrics")
struct SecurityMetricsTests {
    private let metrics = TestMetrics()
    private let fast = Argon2idHashing(
        parameters: .init(timeCost: 1, memoryCost: 8, parallelism: 1))

    private func total(_ label: String, _ dimensions: [(String, String)] = []) -> Int64 {
        (try? metrics.expectCounter(label, dimensions).totalValue) ?? 0
    }

    @Test("password sign-in counts each outcome by a closed name, and rehashes")
    func passwordOutcomes() async throws {
        let store = InMemoryCredentialStore()
        let weaker = Argon2idHashing(parameters: .init(timeCost: 1, memoryCost: 8, parallelism: 1))
        let stronger = Argon2idHashing(
            parameters: .init(timeCost: 2, memoryCost: 16, parallelism: 1))
        store.insert(
            StoredCredential(subject: "u", passwordHash: try weaker.hash("pw")), identifiers: ["u"])
        let auth = PasswordAuthenticator(
            store: store, issuer: "local", hasher: stronger,
            limiter: RateLimiter(store: RecordingRateLimitStore()),
            throttle: .init(perIdentifier: .perMinute(2), perAddress: .perMinute(100)),
            metrics: metrics)

        _ = try await auth.authenticate(identifier: "u", password: "pw", clientAddress: nil)
        _ = try? await auth.authenticate(identifier: "u", password: "wrong", clientAddress: nil)
        _ = try? await auth.authenticate(identifier: "u", password: "pw", clientAddress: nil)

        let attempt = { (outcome: String) in
            total(SignInMetrics.attempts, [("provider", "password"), ("outcome", outcome)])
        }
        #expect(attempt("success") == 1)
        #expect(attempt("invalid_credentials") == 1)
        #expect(attempt("throttled") == 1)
        #expect(total(SignInMetrics.passwordRehashes) == 1)
    }

    @Test("one-time token redemptions keep the difference the caller is never told")
    func tokenOutcomes() async throws {
        let clock = TestClock()
        let tokens = OneTimeTokens(
            store: InMemoryOneTimeTokenStore(now: clock.nowProvider), now: clock.nowProvider,
            metrics: metrics)
        let a = try await tokens.issue(for: "u", purpose: .passwordReset, lifetime: .seconds(60))
        _ = try await tokens.redeem(a, purpose: .passwordReset)
        _ = try? await tokens.redeem(a, purpose: .passwordReset)
        let b = try await tokens.issue(
            for: "u", purpose: .emailVerification, lifetime: .seconds(60))
        _ = try? await tokens.redeem(b, purpose: .passwordReset)
        let c = try await tokens.issue(
            for: "u", purpose: .passwordReset, lifetime: .seconds(60), binding: "h1")
        _ = try? await tokens.redeem(c, purpose: .passwordReset) { _ in "h2" }

        let redeemed = { (outcome: String) in
            total(
                SignInMetrics.tokensRedeemed, [("purpose", "password-reset"), ("outcome", outcome)])
        }
        #expect(total(SignInMetrics.tokensIssued, [("purpose", "password-reset")]) == 2)
        #expect(redeemed("redeemed") == 1)
        #expect(redeemed("unknown_or_used") == 1)
        #expect(redeemed("wrong_purpose") == 1)
        #expect(redeemed("binding_mismatch") == 1)
    }

    @Test("an OIDC callback with a forged state counts as invalid_callback")
    func oidcOutcome() async throws {
        struct NoHTTP: HTTPGetting {
            func getJSON(_ url: URL) async throws -> Data {
                Data(
                    #"{"issuer":"\#(testIssuer)","authorization_endpoint":"https://idp.example.com/a","token_endpoint":"https://idp.example.com/t"}"#
                        .utf8)
            }
        }
        struct NoPost: HTTPFormPosting {
            func postForm(
                _ url: URL, fields: [(String, String)],
                basicAuthorization: (user: String, password: String)?
            ) async throws -> (status: Int, body: Data) { (500, Data()) }
            func getWithBearer(_ url: URL, token: String) async throws -> (status: Int, body: Data)
            { (500, Data()) }
        }
        let provider = OIDCSignIn(
            configuration: try OIDCSignInConfiguration(
                issuer: testIssuer, clientID: "my-app",
                redirectURI: URL(string: "https://app.example.com/cb")!),
            http: NoHTTP(), poster: NoPost(),
            jwksSource: try InMemoryJWKSSource(json: jwksJSON([])),
            metrics: metrics)
        let session = Session()
        let context = RequestContext(
            request: Request(path: "/cb"), session: session, logger: Logger(label: "t"))
        _ = try await provider.beginSignIn(context, returnTo: nil)
        _ = try? await provider.completeSignIn(
            RequestContext(
                request: Request(path: "/cb?code=x&state=forged"), session: session,
                logger: Logger(label: "t")))
        #expect(total(SignInMetrics.started, [("provider", "oidc")]) == 1)
        #expect(
            total(SignInMetrics.attempts, [("provider", "oidc"), ("outcome", "invalid_callback")])
                == 1)
    }

    @Test("sessions count creation, regeneration, revocation and expiry of a sign-in")
    func sessionCounters() async throws {
        let clock = TestClock()
        let runtime = SessionRuntime(
            store: InMemorySessionStore(now: clock.nowProvider),
            settings: try SessionSettings(
                ttl: .seconds(86_400), cookieSecure: false, authenticatedLifetime: .seconds(60)),
            now: clock.nowProvider, metrics: metrics)
        let routes = [
            RouteRegistration(method: .post, path: "/visit", source: "t") { context in
                try context.requireSession().set("k", 1)
                return .status(.noContent)
            },
            RouteRegistration(method: .post, path: "/login", source: "t") { context in
                try context.requireSession().signIn(testPrincipal(subject: "ada"), at: clock.now)
                return .status(.noContent)
            },
            RouteRegistration(method: .get, path: "/me", source: "t", pipelines: [.authenticated]) {
                context in
                .text(try context.requirePrincipal().subject)
            },
        ]
        let client = try TestClient(
            routes: routes,
            middleware: MiddlewareRegistration.lane(.default, [Sessions(runtime: runtime)])
                + FlightSecurityModule(validator: nil, sessions: runtime).middleware)
        let visit = await client.post("/visit")
        let cookie = try #require(
            visit.headerValues("Set-Cookie").first?.split(separator: ";").first.map(String.init))
        let login = await client.post("/login", headers: [.cookie: cookie])
        let signedIn = try #require(
            login.headerValues("Set-Cookie").first?.split(separator: ";").first.map(String.init))
        _ = try await runtime.revokeSessions(ownedBy: "nobody")
        clock.advance(by: 61)
        #expect(await client.get("/me", headers: [.cookie: signedIn]).status == .unauthorized)

        #expect(total(SessionMetrics.created) == 1)
        #expect(total(SessionMetrics.regenerated) >= 1)
        #expect(total(SignInMetrics.expired) == 1)
        #expect(total(SessionMetrics.revoked) == 0)
    }
}
