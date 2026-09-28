import AlulaCore
import AlulaHTTPClientTesting
import Foundation
import HTTPTypes
import Synchronization
import Testing

@testable import AlulaHTTPClient

@Suite("Client credentials: service-account tokens, cached and renewed")
struct ClientCredentialsTests {
    static let tokenURL = URL(string: "https://id.example.com/realms/main/token")!
    static let api = URL(string: "https://api.example.com/invoices")!

    final class Clock: Sendable {
        let value = Mutex(Date(timeIntervalSince1970: 1_000_000))
        var now: @Sendable () -> Date { { self.value.withLock { $0 } } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    }

    /// A token endpoint issuing `token-1`, `token-2`, …, and an API that
    /// accepts only `acceptedToken` (every token when nil).
    final class Server: Sendable {
        final class State: Sendable {
            let issued = Mutex(0)
            let accepted = Mutex<String?>(nil)
        }
        let state = State()
        let transport: StubHTTPTransport

        init(tokenStatus: Int = 200, tokenBody: String? = nil, expiresIn: Int = 300) {
            let state = self.state
            transport = StubHTTPTransport { request in
                if request.url.path.hasSuffix("/.well-known/openid-configuration") {
                    return .init(
                        status: .ok,
                        body: Data(#"{"token_endpoint":"https://id.example.com/realms/main/token"}"#.utf8))
                }
                if request.url == ClientCredentialsTests.tokenURL {
                    if let tokenBody {
                        return .init(status: .init(code: tokenStatus), body: Data(tokenBody.utf8))
                    }
                    let number = state.issued.withLock { $0 += 1; return $0 }
                    return .init(
                        status: .ok,
                        body: Data(#"{"access_token":"token-\#(number)","expires_in":\#(expiresIn)}"#.utf8))
                }
                let presented = request.headers[.authorization]
                let wanted = state.accepted.withLock { $0 }
                if let wanted, presented != "Bearer \(wanted)" { return .init(status: .unauthorized) }
                return .init(status: .ok, body: Data("ok".utf8))
            }
        }

        var tokenRequests: [OutboundRequest] {
            transport.requests.filter { $0.url == ClientCredentialsTests.tokenURL }
        }
    }

    func settings(
        _ endpoint: ClientCredentialsSettings.Endpoint = .tokenURL(tokenURL),
        authentication: ClientCredentialsSettings.ClientAuthentication = .basic
    ) -> ClientCredentialsSettings {
        ClientCredentialsSettings(
            endpoint: endpoint, clientID: "billing worker", clientSecret: "s3cr&t", scope: "invoices:write",
            clientAuthentication: authentication)
    }

    @Test("one request to the token endpoint however many callers ask at once")
    func singleFlight() async throws {
        let server = Server()
        let tokens = ClientCredentialsTokenSource(
            settings: settings(), http: OutboundHTTPClient(transport: server.transport))
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await tokens.token() } }
            for try await token in group { #expect(token == "token-1") }
        }
        #expect(server.tokenRequests.count == 1)
    }

    @Test("a token is kept until shortly before it expires, then renewed")
    func renewedBeforeExpiry() async throws {
        let server = Server(expiresIn: 300)
        let clock = Clock()
        let tokens = ClientCredentialsTokenSource(
            settings: settings(), http: OutboundHTTPClient(transport: server.transport), now: clock.now)
        #expect(try await tokens.token() == "token-1")
        clock.advance(250)
        #expect(try await tokens.token() == "token-1")
        clock.advance(25)  // 25 s left: inside the 30 s renewal margin
        #expect(try await tokens.token() == "token-2")
    }

    /// `renewBefore` was read as whole seconds: 1.5 s acted as 1 s, and
    /// anything under a second as no margin at all.
    @Test("a sub-second part of the renewal margin counts")
    func fractionalRenewalMargin() async throws {
        let server = Server(expiresIn: 10)
        let clock = Clock()
        var settings = settings()
        settings.renewBefore = .milliseconds(1500)
        let tokens = ClientCredentialsTokenSource(
            settings: settings, http: OutboundHTTPClient(transport: server.transport), now: clock.now)
        #expect(try await tokens.token() == "token-1")
        clock.advance(8.75)  // 1.25 s left: inside 1.5 s, outside a truncated 1 s
        #expect(try await tokens.token() == "token-2")
    }

    @Test("a 401 renews the token once and retries; a second 401 is the answer")
    func unauthorizedRenewsOnce() async throws {
        let server = Server()
        let http = OutboundHTTPClient(transport: server.transport)
        let tokens = ClientCredentialsTokenSource(settings: settings(), http: http)
        let client = AuthorizedHTTPClient(http: http, tokens: tokens)
        _ = try await tokens.token()  // token-1 cached
        server.state.accepted.withLock { $0 = "token-2" }  // e.g. token-1 was revoked
        #expect(try await client.send(OutboundRequest(url: Self.api)).status == .ok)
        server.state.accepted.withLock { $0 = "never" }
        #expect(try await client.send(OutboundRequest(url: Self.api)).status == .unauthorized)
    }

    @Test("client authentication: HTTP Basic by default, or in the form body")
    func clientAuthentication() async throws {
        let basic = Server()
        _ = try await ClientCredentialsTokenSource(
            settings: settings(), http: OutboundHTTPClient(transport: basic.transport)
        ).token()
        let request = try #require(basic.tokenRequests.first)
        let expected = Data("billing%20worker:s3cr%26t".utf8).base64EncodedString()
        #expect(request.headers[.authorization] == "Basic \(expected)")
        let form = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(form == "grant_type=client_credentials&scope=invoices%3Awrite")

        let post = Server()
        _ = try await ClientCredentialsTokenSource(
            settings: settings(authentication: .post), http: OutboundHTTPClient(transport: post.transport)
        ).token()
        let posted = String(decoding: try #require(post.tokenRequests.first).body ?? Data(), as: UTF8.self)
        #expect(posted.contains("client_id=billing%20worker&client_secret=s3cr%26t"))
        #expect(try #require(post.tokenRequests.first).headers[.authorization] == nil)
    }

    /// `CharacterSet.alphanumerics` is every Unicode letter and digit, so a
    /// non-ASCII secret went out unencoded in a body that must be ASCII.
    @Test("a non-ASCII client id or secret is percent-encoded as UTF-8")
    func nonASCIIFormEncoding() async throws {
        let post = Server()
        _ = try await ClientCredentialsTokenSource(
            settings: ClientCredentialsSettings(
                endpoint: .tokenURL(Self.tokenURL), clientID: "façade", clientSecret: "秘密",
                clientAuthentication: .post),
            http: OutboundHTTPClient(transport: post.transport)
        ).token()
        let posted = String(decoding: try #require(post.tokenRequests.first).body ?? Data(), as: UTF8.self)
        #expect(posted.contains("client_id=fa%C3%A7ade&client_secret=%E7%A7%98%E5%AF%86"))

        let basic = Server()
        _ = try await ClientCredentialsTokenSource(
            settings: ClientCredentialsSettings(
                endpoint: .tokenURL(Self.tokenURL), clientID: "façade", clientSecret: "秘密"),
            http: OutboundHTTPClient(transport: basic.transport)
        ).token()
        let expected = Data("fa%C3%A7ade:%E7%A7%98%E5%AF%86".utf8).base64EncodedString()
        #expect(try #require(basic.tokenRequests.first).headers[.authorization] == "Basic \(expected)")
    }

    @Test("an issuer's token endpoint is discovered once")
    func discovery() async throws {
        let server = Server()
        let tokens = ClientCredentialsTokenSource(
            settings: settings(.issuer(URL(string: "https://id.example.com/realms/main")!)),
            http: OutboundHTTPClient(transport: server.transport))
        _ = try await tokens.token()
        await tokens.invalidate("token-1")
        _ = try await tokens.token()
        let discoveries = server.transport.requests.filter { $0.url.path.contains(".well-known") }
        #expect(discoveries.count == 1)
        #expect(server.tokenRequests.count == 2)
    }

    @Test("a refusal names the endpoint, the client and the server's reason, never the secret")
    func refusal() async throws {
        let server = Server(
            tokenStatus: 401,
            tokenBody: #"{"error":"invalid_client","error_description":"Invalid client credentials"}"#)
        let tokens = ClientCredentialsTokenSource(
            settings: settings(), http: OutboundHTTPClient(transport: server.transport))
        do {
            _ = try await tokens.token()
            Issue.record("a refused token was returned")
        } catch let error as ClientCredentialsError {
            #expect(
                error.description
                    == "the token endpoint https://id.example.com/realms/main/token refused client 'billing worker' (401): invalid_client: Invalid client credentials")
            #expect(!error.description.contains("s3cr"))
            #expect(!error.isTemporarilyUnavailable, "configuration: retrying will not help")
        }
    }

    @Test("an authorization server that is down is temporarily unavailable")
    func outage() async throws {
        let server = Server(tokenStatus: 503, tokenBody: "")
        let tokens = ClientCredentialsTokenSource(
            settings: settings(),
            http: OutboundHTTPClient(transport: server.transport, policy: OutboundHTTPPolicy(maxAttempts: 1)))
        await #expect {
            _ = try await tokens.token()
        } throws: { error in
            (error as? ClientCredentialsError)?.isTemporarilyUnavailable == true
        }
    }

    @Test("configuration: one endpoint, an id and a secret, from http-client.client-credentials")
    func configuration() throws {
        let values = [
            "http-client.client-credentials.issuer": "https://id.example.com/realms/main",
            "http-client.client-credentials.client-id": "worker",
            "http-client.client-credentials.client-secret": "x",
        ]
        let parsed = try ClientCredentialsSettings(configuration: Configuration(values: values))
        #expect(parsed.endpoint == .issuer(URL(string: "https://id.example.com/realms/main")!))
        #expect(parsed.clientAuthentication == .basic)
        #expect(throws: ClientCredentialsConfigurationError.self) {
            try ClientCredentialsSettings(
                configuration: Configuration(
                    values: values.merging([
                        "http-client.client-credentials.token-url": "https://id.example.com/token"
                    ]) { $1 }))
        }
        #expect(throws: ClientCredentialsConfigurationError.self) {
            try ClientCredentialsSettings(
                configuration: Configuration(
                    values: values.filter { $0.key != "http-client.client-credentials.client-secret" }))
        }
    }
}
