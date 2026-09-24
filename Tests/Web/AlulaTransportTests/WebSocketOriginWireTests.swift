import AlulaWeb
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing

/// Cross-site WebSocket hijacking, over a real socket: the check reads the
/// handshake's `Host` from where the transport puts it, which only the wire
/// can confirm.
@Suite("WebSocket Origin check on the wire", .serialized)
struct WebSocketOriginWireTests {

    private enum Outcome { case upgraded, refused }

    private func handshake(port: Int, host: String, origin: String?) async throws -> Outcome {
        let result: EventLoopFuture<Outcome> = try await ClientBootstrap(
            group: MultiThreadedEventLoopGroup.singleton
        )
        .connect(host: "127.0.0.1", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                let upgrader = NIOTypedWebSocketClientUpgrader<Outcome>(
                    upgradePipelineHandler: { channel, _ in
                        channel.close().map { .upgraded }
                    })
                var headers = HTTPHeaders([("Host", host), ("Content-Length", "0")])
                if let origin { headers.add(name: "Origin", value: origin) }
                let configuration = NIOTypedHTTPClientUpgradeConfiguration(
                    upgradeRequestHead: HTTPRequestHead(
                        version: .http1_1, method: .GET, uri: "/ws/lobby", headers: headers),
                    upgraders: [upgrader],
                    notUpgradingCompletionHandler: { channel in
                        channel.close().map { .refused }
                    })
                return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                    configuration: .init(upgradeConfiguration: configuration))
            }
        }
        return try await result.get()
    }

    private func outcome(port: Int, host: String, origin: String?) async -> Outcome? {
        try? await handshake(port: port, host: host, origin: origin)
    }

    private let sameOriginOnly = WebRuntime(webSocketOrigins: .sameOrigin)

    @Test("a page on another site cannot open a socket")
    func crossSiteRefused() async throws {
        try await withRunningServer(web: sameOriginOnly) { port in
            let outcome = try await handshake(
                port: port, host: "app.example.com", origin: "https://evil.example")
            #expect(outcome == .refused)
        }
    }

    @Test("the page's own origin can, default port spelled or not")
    func sameOriginAllowed() async throws {
        try await withRunningServer(web: sameOriginOnly) { port in
            #expect(await outcome(port: port, host: "app.example.com", origin: "https://app.example.com") == .upgraded)
            #expect(await outcome(port: port, host: "app.example.com:443", origin: "https://App.Example.com") == .upgraded)
        }
    }

    @Test("a lookalike suffix is not the same origin")
    func suffixLookalikeRefused() async throws {
        try await withRunningServer(web: sameOriginOnly) { port in
            #expect(await outcome(port: port, host: "example.com", origin: "https://evil-example.com") == .refused)
            #expect(await outcome(port: port, host: "example.com", origin: "null") == .refused)
        }
    }

    @Test("no Origin means no browser page, so nothing to hijack")
    func noOriginAllowed() async throws {
        try await withRunningServer(web: sameOriginOnly) { port in
            #expect(await outcome(port: port, host: "app.example.com", origin: nil) == .upgraded)
        }
    }

    @Test("a listed origin is allowed besides this one")
    func listedOriginAllowed() async throws {
        let web = WebRuntime(
            webSocketOrigins: .sameOrigin(or: .exact(["https://admin.example.com"])))
        try await withRunningServer(web: web) { port in
            #expect(await outcome(port: port, host: "api.example.com", origin: "https://admin.example.com") == .upgraded)
            #expect(await outcome(port: port, host: "api.example.com", origin: "https://other.example.com") == .refused)
        }
    }
}
