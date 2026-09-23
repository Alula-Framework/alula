import AsyncHTTPClient
import AlulaCore
import AlulaSessions
import AlulaWeb
import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import Testing

@testable import AlulaSecurityCore

/// OIDC sign-in against a real Keycloak, driven end to end: the provider's
/// redirect, Keycloak's own login form, the callback, the code exchange, the
/// ID token.
///
/// The unit suite proves the protocol logic against fakes; this proves the
/// seam holds against the thing it exists to plug into. Run with:
///
///     ./CI/keycloak/start.sh
///     ALULA_TEST_KEYCLOAK_URL=http://localhost:8089 swift test --enable-all-traits --filter KeycloakSignIn
private let keycloakURL = ProcessInfo.processInfo.environment["ALULA_TEST_KEYCLOAK_URL"]

@Suite(
    "OIDC sign-in against a real Keycloak",
    .enabled(if: keycloakURL != nil, "set ALULA_TEST_KEYCLOAK_URL; see CI/keycloak/start.sh"))
struct KeycloakSignInTests {
    private var issuer: String { "\(keycloakURL!)/realms/alula-test" }

    private func provider(
        client: String = "alula-test-app", fetchUserInfo: Bool = true,
        scopes: [String] = OIDCSignInConfiguration.defaultScopes
    ) throws -> OIDCSignIn {
        OIDCSignIn(
            configuration: try OIDCSignInConfiguration(
                issuer: issuer, clientID: client, clientSecret: "alula-test-secret",
                redirectURI: URL(string: "http://localhost:8080/auth/callback")!,
                postLogoutRedirectURI: URL(string: "http://localhost:8080/")!,
                scopes: scopes, transport: .allowInsecureLoopback, fetchUserInfo: fetchUserInfo))
    }

    private func context(_ session: Session, target: String = "/auth/callback") -> RequestContext {
        RequestContext(
            request: Request(path: target), session: session, logger: Logger(label: "test"))
    }

    /// A browser's worth of HTTP: cookies kept, redirects not followed, so
    /// each hop can be inspected.
    private final class Browser: @unchecked Sendable {
        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: .init(redirectConfiguration: .disallow))
        var cookies: [String: String] = [:]

        func send(_ url: String, method: HTTPMethod = .GET, form: String? = nil) async throws
            -> (status: Int, location: String?, body: String)
        {
            var request = HTTPClientRequest(url: url)
            request.method = method
            if !cookies.isEmpty {
                request.headers.add(
                    name: "Cookie",
                    value: cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
            }
            if let form {
                request.headers.add(
                    name: "Content-Type", value: "application/x-www-form-urlencoded")
                request.body = .bytes(ByteBuffer(string: form))
            }
            let response = try await client.execute(request, timeout: .seconds(20))
            for value in response.headers["Set-Cookie"] {
                let pair = value.split(separator: ";").first ?? ""
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { cookies[parts[0]] = parts[1] }
            }
            let body = try await response.body.collect(upTo: 2 << 20)
            return (
                Int(response.status.code), response.headers.first(name: "Location"),
                String(buffer: body)
            )
        }

        func shutdown() async throws { try await client.shutdown() }
    }

    /// Keycloak's login form's `action`, unescaped.
    private func formAction(in html: String) throws -> String {
        let marker = #"id="kc-form-login""#
        let form = try #require(html.range(of: marker), "no login form in Keycloak's page")
        let tail = html[form.upperBound...]
        let actionStart = try #require(tail.range(of: #"action=""#))
        let rest = tail[actionStart.upperBound...]
        let end = try #require(rest.firstIndex(of: "\""))
        return String(rest[..<end]).replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Begin, then sign in on Keycloak's own page, returning the callback
    /// target the provider sent the browser back to.
    private func signInAtKeycloak(
        _ provider: OIDCSignIn, _ session: Session, password: String = "correct horse"
    ) async throws -> String? {
        guard
            case .redirect(let authorize) = try await provider.beginSignIn(
                context(session), returnTo: "/rooms")
        else {
            Issue.record("expected a redirect")
            return nil
        }

        let browser = Browser()
        defer { Task { try? await browser.shutdown() } }
        let page = try await browser.send(authorize.absoluteString)
        #expect(page.status == 200, "Keycloak's login page")
        let action = try formAction(in: page.body)
        let submitted = try await browser.send(
            action, method: .POST,
            form: "username=ada&password=\(FormEncoding.encode(password))&credentialId=")
        guard submitted.status == 302, let location = submitted.location,
            location.hasPrefix("http://localhost:8080/auth/callback")
        else { return nil }
        let callback = try #require(URLComponents(string: location))
        return "/auth/callback?" + (callback.percentEncodedQuery ?? "")
    }

    @Test("a real sign-in yields the same standard claims the password provider produces")
    func signsIn() async throws {
        let provider = try provider()
        let session = Session()
        let target = try #require(try await signInAtKeycloak(provider, session))

        let result = try await provider.signIn(context(session, target: target))
        let principal = result.principal
        #expect(principal.issuer == issuer)
        #expect(!principal.subject.isEmpty)
        #expect(principal.email == "ada@example.com")
        #expect(principal.emailVerified)
        #expect(principal.name == "Ada Lovelace")
        #expect(principal.preferredUsername == "ada")
        #expect(principal.hasRole("author"))
        #expect(result.returnTo == "/rooms")
        #expect(try session.principal()?.email == "ada@example.com", "and the session keeps them")
    }

    @Test("a wrong password never reaches the callback")
    func wrongPassword() async throws {
        let target = try await signInAtKeycloak(try provider(), Session(), password: "wrong")
        #expect(target == nil)
    }

    @Test("the callback cannot be replayed against Keycloak either")
    func replay() async throws {
        let provider = try provider()
        let session = Session()
        let target = try #require(try await signInAtKeycloak(provider, session))
        _ = try await provider.completeSignIn(context(session, target: target))
        await #expect(throws: OIDCSignInError.self) {
            try await provider.completeSignIn(context(session, target: target))
        }
    }

    @Test("sign-out goes to Keycloak's end-session endpoint")
    func signOut() async throws {
        let step = try await provider().beginSignOut(context(Session()))
        guard case .redirect(let url) = step else {
            Issue.record("expected a redirect")
            return
        }
        #expect(url.absoluteString.hasPrefix("\(issuer)/protocol/openid-connect/logout"))
    }

    @Test("a client whose ID token carries no profile claims gets them from UserInfo")
    func userInfoAgainstKeycloak() async throws {
        // alula-test-userinfo maps email, name and preferred_username into
        // UserInfo only — the shape OIDC Core §5.4 describes for the code flow.
        // Only `openid`: the client offers no profile or email scope, which is
        // why its mappers are what put the claims in UserInfo.
        let bare = try provider(
            client: "alula-test-userinfo", fetchUserInfo: false, scopes: ["openid"])
        let session = Session()
        let target = try #require(try await signInAtKeycloak(bare, session))
        let idTokenOnly = try await bare.completeSignIn(context(session, target: target))
        #expect(idTokenOnly.principal.email == nil, "the ID token really does leave them out")

        let provider = try provider(client: "alula-test-userinfo", scopes: ["openid"])
        let second = Session()
        let callback = try #require(try await signInAtKeycloak(provider, second))
        let principal = try await provider.completeSignIn(context(second, target: callback))
            .principal
        #expect(principal.subject == idTokenOnly.principal.subject)
        #expect(principal.email == "ada@example.com")
        #expect(principal.emailVerified)
        #expect(principal.name == "Ada Lovelace")
        #expect(principal.preferredUsername == "ada")
    }
}
