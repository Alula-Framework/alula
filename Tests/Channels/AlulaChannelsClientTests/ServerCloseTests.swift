import AlulaChannelsClient
import AlulaChannelsProtocol
import Foundation
import Synchronization
import Testing

/// A transport whose "server" is the test: it answers joins, and ends the
/// socket the way the Alula server does — a WebSocket close frame with a
/// code, which a transport surfaces as the end of `incoming`.
final class ScriptedServerTransport: ChannelClientTransport, Sendable {
    private let live = Mutex<[AsyncThrowingStream<String, any Error>.Continuation]>([])
    private let dials = Mutex(0)

    var connectCount: Int { dials.withLock { $0 } }

    /// The server closes every open socket with `code`. The code is what
    /// the server wrote; the seam carries only that the socket ended.
    func serverCloses(code: UInt16) {
        let open = live.withLock { live in
            defer { live = [] }
            return live
        }
        for continuation in open { continuation.finish() }
    }

    /// The server sends one frame on every open socket.
    func serverSends(_ envelope: Envelope) throws {
        let text = try envelope.encodedText()
        for continuation in live.withLock({ $0 }) { continuation.yield(text) }
    }

    func connect(to url: URL) async throws -> ClientTransportConnection {
        dials.withLock { $0 += 1 }
        let (incoming, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        live.withLock { $0.append(continuation) }
        return ClientTransportConnection(
            incoming: incoming,
            send: { text in
                let envelope = try Envelope(text: text)
                // Answer joins; leave everything else unanswered, so a push
                // is in flight when the server closes.
                guard envelope.event == ReservedEvent.join.rawValue else { return }
                continuation.yield(
                    try Envelope(
                        ref: envelope.ref, topic: envelope.topic,
                        event: ReservedEvent.reply.rawValue, payload: .object([:])
                    ).encodedText())
            },
            close: { continuation.finish() }
        )
    }
}

@Suite("Swift client — the server ends a socket with a close code", .timeLimit(.minutes(1)))
struct ServerCloseTests {

    /// Every code the Alula server closes a channel socket with.
    static let serverCloseCodes: [UInt16] = [
        1000, 1001, ChannelCloseCode.heartbeatTimeout, ChannelCloseCode.protocolViolation,
        ChannelCloseCode.writeTimeout, ChannelCloseCode.outboundOverflow,
    ]

    private func client(_ transport: ScriptedServerTransport, reconnect: ReconnectPolicy) -> ChannelClient {
        ChannelClient(
            url: URL(string: "alula-test:///socket")!, transport: transport,
            configuration: ChannelClientConfiguration(
                heartbeatInterval: .seconds(30), pushTimeout: .seconds(10), reconnect: reconnect))
    }

    @Test("with no reconnect, the client ends .closed, pushes failed and channels unjoined",
          arguments: serverCloseCodes)
    func closeEndsTheClient(code: UInt16) async throws {
        let transport = ScriptedServerTransport()
        let client = client(transport, reconnect: .never)
        try await client.connect()
        let room = client.channel("room:1")
        try await room.join()
        let pending = Task { try await room.push("unanswered") }
        try await Task.sleep(for: .milliseconds(50))  // let the push register

        transport.serverCloses(code: code)

        await #expect(throws: ChannelClientError.disconnected) { _ = try await pending.value }
        #expect(await eventually { await client.connectionState == .closed })
        #expect(await !client.isJoined("room:1"))
        #expect(transport.connectCount == 1)
    }

    @Test("with a reconnect policy, the client re-dials and rejoins", arguments: serverCloseCodes)
    func closeIsADrop(code: UInt16) async throws {
        let transport = ScriptedServerTransport()
        let client = client(
            transport,
            reconnect: .exponentialBackoff(initial: .milliseconds(10), max: .milliseconds(50)))
        try await client.connect()
        try await client.channel("room:1").join()

        transport.serverCloses(code: code)

        #expect(await eventually { transport.connectCount == 2 })
        #expect(await eventually { await client.isJoined("room:1") })
        #expect(await client.connectionState == .connected)
        await client.disconnect()
    }

    @Test("an inbound alula:close is ignored: only the socket's close ends the session")
    func inboundCloseIsIgnored() async throws {
        // The Alula server never sends `alula:close`, and the client used to
        // treat one as a terminal disconnect — a second, unused way to end a
        // session that the JavaScript client did not share.
        let transport = ScriptedServerTransport()
        let client = client(transport, reconnect: .never)
        try await client.connect()
        try await client.channel("room:1").join()

        try transport.serverSends(
            Envelope(ref: nil, topic: ChannelProtocol.controlTopic, event: ReservedEvent.close.rawValue))
        try await Task.sleep(for: .milliseconds(100))

        #expect(await client.connectionState == .connected)
        #expect(await client.isJoined("room:1"))
        await client.disconnect()
    }
}
