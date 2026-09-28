import protocol AlulaWeb.WebSocketUpgradeHandler
import struct AlulaWeb.WebSocketConnection
import enum AlulaWeb.WebSocketError
import struct AlulaWeb.RequestContext
import struct AlulaWeb.RouteRegistration
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Synchronization
import Testing

/// Real-socket WebSocket sessions against a bound `AlulaTransport` (§6.1),
/// driven by NIO's own typed client upgrader.
@Suite("AlulaTransport WebSocket wire behavior", .serialized)
struct WebSocketWireTests {

    enum ClientUpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case notUpgraded
    }

    /// Performs the client-side handshake and hands the frame channel to `body`.
    private func withWebSocket(
        port: Int,
        path: String,
        headers: [(String, String)] = [],
        response: (@Sendable (HTTPResponseHead) -> Void)? = nil,
        _ body: @escaping @Sendable (
            NIOAsyncChannelInboundStream<WebSocketFrame>,
            NIOAsyncChannelOutboundWriter<WebSocketFrame>
        ) async throws -> Void
    ) async throws {
        let upgradeResult: EventLoopFuture<ClientUpgradeResult> = try await ClientBootstrap(
            group: MultiThreadedEventLoopGroup.singleton
        )
        .connect(host: "127.0.0.1", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                let upgrader = NIOTypedWebSocketClientUpgrader<ClientUpgradeResult>(
                    upgradePipelineHandler: { channel, head in
                        response?(head)
                        return channel.eventLoop.makeCompletedFuture {
                            .websocket(
                                try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                    wrappingChannelSynchronously: channel
                                )
                            )
                        }
                    }
                )
                let requestHead = HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: path,
                    headers: HTTPHeaders([("Host", "localhost"), ("Content-Length", "0")] + headers)
                )
                let configuration = NIOTypedHTTPClientUpgradeConfiguration(
                    upgradeRequestHead: requestHead,
                    upgraders: [upgrader],
                    notUpgradingCompletionHandler: { channel in
                        channel.eventLoop.makeCompletedFuture { .notUpgraded }
                    }
                )
                return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                    configuration: .init(upgradeConfiguration: configuration)
                )
            }
        }

        switch try await upgradeResult.get() {
        case .notUpgraded:
            Issue.record("server refused the upgrade for \(path)")
        case .websocket(let channel):
            try await channel.executeThenClose { inbound, outbound in
                try await body(inbound, outbound)
            }
        }
    }

    private func maskedText(_ text: String) -> WebSocketFrame {
        WebSocketFrame(
            fin: true,
            opcode: .text,
            maskKey: WebSocketMaskingKey([0x0a, 0x0b, 0x0c, 0x0d]),
            data: ByteBuffer(string: text)
        )
    }

    private func text(of frame: WebSocketFrame) -> String? {
        guard frame.opcode == .text else { return nil }
        var data = frame.unmaskedData
        return data.readString(length: data.readableBytes)
    }

    /// The raw-socket half of this suite, for the tests where the server
    /// speaks first.
    ///
    /// NIO's typed client upgrader loses a frame that arrives in the same
    /// read as the `101` response — under load, 12 runs in 25 lost the
    /// server's first message. A raw socket with nothing interpreting the
    /// bytes received it every time, so the server is right and the client
    /// harness is not; these tests read the frames themselves.
    private func handshake(_ path: String, extra: String = "") -> String {
        "GET \(path) HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\(extra)\r\n"
    }

    /// The text of each unmasked, unfragmented server frame after the
    /// response headers, as far as `transcript` goes.
    private func serverTexts(in received: [UInt8]) -> [String] {
        guard let end = received.firstRange(of: Array("\r\n\r\n".utf8)) else { return [] }
        var bytes = Array(received[end.upperBound...])
        var texts: [String] = []
        while bytes.count >= 2 {
            let opcode = bytes[0] & 0x0F
            let length = Int(bytes[1] & 0x7F)
            guard length < 126, bytes.count >= 2 + length else { break }
            if opcode == 0x1 { texts.append(String(decoding: bytes[2..<(2 + length)], as: UTF8.self)) }
            bytes.removeFirst(2 + length)
        }
        return texts
    }

    /// A masked client text frame, as RFC 6455 requires of a client.
    private func maskedTextBytes(_ text: String) -> Data {
        let payload = Array(text.utf8)
        let mask: [UInt8] = [0x0a, 0x0b, 0x0c, 0x0d]
        return Data([0x81, 0x80 | UInt8(payload.count)] + mask
            + payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }

    @Test func upgradeHandshakeAndEcho() async throws {
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(self.handshake("/ws/lobby"))
                _ = try await session.readUntil("joined lobby")
                #expect(self.serverTexts(in: session.receivedBytes) == ["joined lobby"])
                try await session.sendBytes(self.maskedTextBytes("hi"))
                _ = try await session.readUntil("echo: hi")
                #expect(self.serverTexts(in: session.receivedBytes) == ["joined lobby", "echo: hi"])
            }
        }
    }

    struct SubprotocolHandler: WebSocketUpgradeHandler {
        var subprotocols: [String] { ["chat.v2"] }
        func handle(upgraded connection: WebSocketConnection, context: RequestContext) async throws {
            try await connection.send(connection.subprotocol ?? "none")
        }
    }

    @Test("the agreed subprotocol is in the 101 response")
    func subprotocolOnTheWire() async throws {
        let route = RouteRegistration(
            method: .get, path: "/chat", kind: .upgrade(.webSocket), source: "t"
        ) { context in .upgrade(handler: SubprotocolHandler(), context: context) }
        try await withRunningServer(routes: [route]) { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    self.handshake("/chat", extra: "Sec-WebSocket-Protocol: chat.v1, chat.v2\r\n"))
                let transcript = try await session.readToEnd()
                let head = transcript.components(separatedBy: "\r\n\r\n").first ?? ""
                #expect(head.lowercased().contains("sec-websocket-protocol: chat.v2"))
                #expect(self.serverTexts(in: session.receivedBytes) == ["chat.v2"])
            }
        }
    }

    @Test func aBurstSurvivesASlowHandler() async throws {
        // The inbound pump now reads only what the handler has asked for, so
        // a client that outruns the handler is throttled by TCP rather than
        // queued in this process. What must not change is delivery: nothing
        // dropped, nothing reordered, however far behind the handler falls.
        try await withRunningServer { port in
            try await withWebSocket(port: port, path: "/ws-slow") { inbound, outbound in
                var iterator = inbound.makeAsyncIterator()
                let count = 20
                for index in 0..<count {
                    try await outbound.write(self.maskedText("m\(index)"))
                }
                var received: [String] = []
                for _ in 0..<count {
                    guard let frame = try await iterator.next(),
                        let text = self.text(of: frame)
                    else { break }
                    received.append(text)
                }
                #expect(received == (0..<count).map { "echo: m\($0)" })
            }
        }
    }

    @Test func pingIsAutoPonged() async throws {
        try await withRunningServer { port in
            try await withWebSocket(port: port, path: "/ws/lobby") { inbound, outbound in
                var iterator = inbound.makeAsyncIterator()
                _ = try await iterator.next()  // welcome

                try await outbound.write(
                    WebSocketFrame(
                        fin: true,
                        opcode: .ping,
                        maskKey: WebSocketMaskingKey([1, 2, 3, 4]),
                        data: ByteBuffer(string: "marco")
                    )
                )
                let pong = try await iterator.next()
                #expect(pong?.opcode == .pong)
                var pongData = pong?.unmaskedData ?? ByteBuffer()
                #expect(pongData.readString(length: pongData.readableBytes) == "marco")
            }
        }
    }

    @Test func serverInitiatedCloseCompletesHandshake() async throws {
        try await withRunningServer { port in
            try await withWebSocket(port: port, path: "/ws/lobby") { inbound, outbound in
                var iterator = inbound.makeAsyncIterator()
                _ = try await iterator.next()  // welcome

                try await outbound.write(self.maskedText("please close"))
                let close = try await iterator.next()
                #expect(close?.opcode == .connectionClose)
                var data = close?.unmaskedData ?? ByteBuffer()
                #expect(data.readInteger(as: UInt16.self) == 1000)
            }
        }
    }

    struct SendAfterCloseHandler: WebSocketUpgradeHandler {
        static let error = Mutex<String?>(nil)
        func handle(upgraded connection: WebSocketConnection, context: RequestContext) async throws {
            try await connection.close(code: .normalClosure, reason: "done")
            do {
                try await connection.send("too late")
                Self.error.withLock { $0 = "no error" }
            } catch let error as WebSocketError {
                Self.error.withLock { $0 = "\(error)" }
            } catch {
                Self.error.withLock { $0 = "unmapped: \(type(of: error))" }
            }
        }
    }

    @Test("a send after the handler's own close throws connectionClosed, not a NIO error")
    func sendAfterCloseIsConnectionClosed() async throws {
        let route = RouteRegistration(
            method: .get, path: "/closing", kind: .upgrade(.webSocket), source: "t"
        ) { context in .upgrade(handler: SendAfterCloseHandler(), context: context) }
        try await withRunningServer(routes: [route]) { port in
            try await withWebSocket(port: port, path: "/closing") { inbound, _ in
                var iterator = inbound.makeAsyncIterator()
                let close = try await iterator.next()
                #expect(close?.opcode == .connectionClose)
            }
        }
        // The handler finishes on its own task; give it a moment to record.
        for _ in 0..<100 where SendAfterCloseHandler.error.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            SendAfterCloseHandler.error.withLock { $0 }
                == "\(WebSocketError.connectionClosed)")
    }

    @Test func fragmentedMessageIsReassembled() async throws {
        try await withRunningServer { port in
            try await withWebSocket(port: port, path: "/ws/lobby") { inbound, outbound in
                var iterator = inbound.makeAsyncIterator()
                _ = try await iterator.next()  // welcome

                try await outbound.write(WebSocketFrame(
                    fin: false, opcode: .text,
                    maskKey: WebSocketMaskingKey([9, 9, 9, 9]),
                    data: ByteBuffer(string: "frag")
                ))
                try await outbound.write(WebSocketFrame(
                    fin: true, opcode: .continuation,
                    maskKey: WebSocketMaskingKey([7, 7, 7, 7]),
                    data: ByteBuffer(string: "mented")
                ))
                let echo = try await iterator.next()
                #expect(echo.flatMap(self.text) == "echo: fragmented")
            }
        }
    }
}
