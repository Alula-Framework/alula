import AlulaCore
import HTTPTypes
import Testing

@testable import AlulaWeb

@Suite("WebSocket Origin policy")
struct WebSocketOriginsTests {

    private func handshake(
        authority: String, origin: String, forwardedHost: String? = nil, peer: String = "10.0.0.5"
    ) -> Request {
        var head = HTTPRequest(method: .get, scheme: nil, authority: authority, path: "/ws")
        head.headerFields[.origin] = origin
        if let forwardedHost {
            head.headerFields[HTTPField.Name("X-Forwarded-Host")!] = forwardedHost
        }
        return Request(head: head, remoteAddress: PeerAddress(host: peer))
    }

    @Test("configuration: unset is same-origin, a list adds to it, * alone turns it off")
    func configuration() throws {
        let unset = try WebSocketOrigins(configuration: Configuration())
        #expect(!unset.allowsAnyOrigin && unset.additional == nil)

        let listed = try WebSocketOrigins(
            configuration: Configuration(values: [
                "web.websocket.allowed-origins": "https://a.example, https://b.example"
            ]))
        #expect(listed.permits(handshake(authority: "api.example", origin: "https://b.example"), trustedProxies: .none))
        #expect(!listed.permits(handshake(authority: "api.example", origin: "https://c.example"), trustedProxies: .none))

        let off = try WebSocketOrigins(
            configuration: Configuration(values: ["web.websocket.allowed-origins": "*"]))
        #expect(off.allowsAnyOrigin)

        #expect(throws: (any Error).self) {
            try WebSocketOrigins(
                configuration: Configuration(values: [
                    "web.websocket.allowed-origins": "*, https://a.example"
                ]))
        }
    }

    @Test("X-Forwarded-Host counts only from a trusted proxy")
    func forwardedHostNeedsTrust() throws {
        let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
        // nginx's default rewrites Host to the upstream name.
        let viaProxy = handshake(
            authority: "app-upstream:8080", origin: "https://app.example.com",
            forwardedHost: "app.example.com")
        #expect(WebSocketOrigins.sameOrigin.permits(viaProxy, trustedProxies: proxies))

        // The same header from an untrusted peer is anyone's to set.
        let direct = handshake(
            authority: "app-upstream:8080", origin: "https://evil.example",
            forwardedHost: "evil.example", peer: "203.0.113.9")
        #expect(!WebSocketOrigins.sameOrigin.permits(direct, trustedProxies: proxies))
    }

    @Test("configuration defaults to same-origin; a hand-built runtime checks nothing")
    func defaults() throws {
        #expect(WebRuntime.default.webSocketOrigins.allowsAnyOrigin)
        #expect(!(try WebSocketOrigins(configuration: Configuration())).allowsAnyOrigin)
    }
}
