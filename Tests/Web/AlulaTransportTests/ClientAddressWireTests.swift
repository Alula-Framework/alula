import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Foundation
import Testing

@Controller("/")
private struct ClientAddressWireController {
    @GetRoute("/whoami")
    func whoami(_ context: RequestContext) -> String {
        "remote=\(context.request.remoteAddress?.host ?? "nil") "
            + "client=\(context.clientAddress?.host ?? "nil")"
    }
}

/// The one thing nothing else in this package proves: that
/// `channel.remoteAddress` really does reach `Request.remoteAddress` in
/// `AlulaTransport`, over an actual socket. Everything about
/// `TrustedProxies`' own logic is proven without a socket in
/// `TrustedProxiesTests`; this proves the wire is plugged in at all.
@Suite("AlulaTransport client address wire behavior", .serialized)
struct ClientAddressWireTests {
    private let routes = ClientAddressWireController.alulaRoutes { _ in
        ClientAddressWireController()
    }

    @Test("the raw peer address is the loopback address the test itself connects from")
    func rawPeerIsLoopback() async throws {
        try await withRunningServer(routes: routes) { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "GET /whoami HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                let response = try await session.readToEnd()
                #expect(response.contains("remote=127.0.0.1"), Comment(rawValue: response))
                // With no trusted proxies configured, clientAddress echoes it.
                #expect(response.contains("client=127.0.0.1"), Comment(rawValue: response))
            }
        }
    }

    @Test("with the loopback range trusted, X-Forwarded-For resolves the real client over the wire")
    func trustedProxyResolvesOverTheWire() async throws {
        let web = WebRuntime(trustedProxies: try TrustedProxies(cidrs: ["127.0.0.1/32"]))
        try await withRunningServer(routes: routes, web: web) { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "GET /whoami HTTP/1.1\r\nHost: localhost\r\n"
                        + "X-Forwarded-For: 203.0.113.9\r\nConnection: close\r\n\r\n")
                let response = try await session.readToEnd()
                // The test harness itself is the "trusted proxy" here — its
                // connection really does come from 127.0.0.1, so this is the
                // full path: a real socket's peer address, checked against a
                // real trust policy, resolving a real header.
                #expect(response.contains("remote=127.0.0.1"), Comment(rawValue: response))
                #expect(response.contains("client=203.0.113.9"), Comment(rawValue: response))
            }
        }
    }

    @Test("without the peer trusted, a forged header over the wire is ignored")
    func untrustedPeerIgnoredOverTheWire() async throws {
        // No trusted-proxies configuration at all — the default — so the
        // header the raw socket client sends must count for nothing.
        try await withRunningServer(routes: routes) { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "GET /whoami HTTP/1.1\r\nHost: localhost\r\n"
                        + "X-Forwarded-For: 1.2.3.4\r\nConnection: close\r\n\r\n")
                let response = try await session.readToEnd()
                #expect(response.contains("client=127.0.0.1"), Comment(rawValue: response))
            }
        }
    }
}
