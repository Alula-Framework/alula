import FlightChannels
import FlightChannelsProtocol
import FlightCore
import FlightPubSub
import FlightWeb
import Foundation
import Logging
import Synchronization
import Testing

/// Pushes far more on join than a small outbound queue can hold, without
/// waiting for anything — the shape of a fan-out against a client that has
/// fallen behind.
private struct FloodChannel: Channel {
    let count: Int

    func join(_ topic: String, socket: Socket) async -> JoinResult {
        for index in 0..<count {
            socket.push(
                topic: topic, event: "flood", payload: ["i": .number(Double(index))])
        }
        return .ok(initialState: .null)
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult { .none }
}

/// Floods, and hands its socket back so a test can read what the socket
/// recorded about the flood.
private final class SocketBox: @unchecked Sendable {
    private let state = Mutex<Socket?>(nil)
    func set(_ socket: Socket) { state.withLock { $0 = socket } }
    var socket: Socket? { state.withLock { $0 } }
}

private struct ReportingFloodChannel: Channel {
    let count: Int
    let box: SocketBox

    func join(_ topic: String, socket: Socket) async -> JoinResult {
        box.set(socket)
        for index in 0..<count {
            socket.push(topic: topic, event: "flood", payload: ["i": .number(Double(index))])
        }
        return .ok(initialState: .null)
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult { .none }
}

private struct FloodModule: FlightModule {
    let channels: [ChannelRegistration] = [
        ChannelRegistration("flood:*", source: "FloodModule") { _ in FloodChannel(count: 200) }
    ]
}

/// `Mutex` is non-copyable, so shared test state travels as a reference.
private final class CloseBox: Sendable {
    private let state = Mutex<(code: UInt16, reason: String)?>(nil)
    func record(_ code: UInt16, _ reason: String) { state.withLock { $0 = (code, reason) } }
    var value: (code: UInt16, reason: String)? { state.withLock { $0 } }
}

private final class Counter: Sendable {
    private let state = Mutex(0)
    func increment() { state.withLock { $0 += 1 } }
    var value: Int { state.withLock { $0 } }
}

/// A connection whose writer is deliberately slower than the producer, so
/// the outbound queue actually fills. Records the close it is finally given.
private final class SlowPeer: Sendable {
    let connection: WebSocketConnection
    let frames: AsyncStream<WebSocketFrame>.Continuation
    let closed = CloseBox()

    init(perFrame: Duration = .milliseconds(30)) {
        let (stream, continuation) = AsyncStream<WebSocketFrame>.makeStream()
        let closed = self.closed
        self.frames = continuation
        self.connection = WebSocketConnection(
            frames: stream,
            send: { _ in try? await Task.sleep(for: perFrame) },
            close: { code, reason in closed.record(code.rawValue, reason) })
    }

    func send(_ envelope: Envelope) throws {
        frames.yield(.text(try envelope.encodedText()))
    }
}

private func makeHandler(
    overflow: String, bufferSize: Int
) throws -> ChannelSocketHandler {
    let configuration = Configuration(values: [
        "flight.channels.outbound-buffer-size": "\(bufferSize)",
        "flight.channels.outbound-overflow": overflow,
        // Long enough that the writer's own timeout cannot be what ends the
        // session — otherwise this suite would pass on the wrong close code.
        "flight.channels.write-timeout-seconds": "30",
        "flight.channels.heartbeat-timeout-seconds": "30",
    ])
    let pubsub = try FlightPubSubModule(configuration: configuration)
    let channels = try FlightChannelsModule(
        bus: pubsub.bus, configuration: configuration, channels: FloodModule().channels)
    return channels.sockets.handler(principal: nil)
}

private func makeContext() -> RequestContext {
    var logger = Logger(label: "flight.channels.overflow-test")
    logger.logLevel = .critical
    return RequestContext(
        request: Request(method: .get, path: "/socket"), logger: logger)
}

@Suite("Outbound overflow", .timeLimit(.minutes(1)))
struct OutboundOverflowTests {

    @Test("overflow closes the socket with 4410 rather than discarding quietly")
    func overflowCloses() async throws {
        // The gap this exists to close: a dropped frame leaves no trace a
        // client could notice, so its view goes silently wrong. A close it
        // can see, and the reconnect that follows re-joins and resyncs.
        let handler = try makeHandler(overflow: "close", bufferSize: 2)
        let peer = SlowPeer()
        let run = Task { try await handler.handle(upgraded: peer.connection, context: makeContext()) }
        try peer.send(Envelope(ref: "1", topic: "flood:a", event: ReservedEvent.join.rawValue))

        try await run.value
        let closed = peer.closed.value
        #expect(closed?.code == ChannelCloseCode.outboundOverflow)
        #expect(closed?.code == 4410)
        #expect(closed?.reason.contains("resynchronise") == true)
    }

    @Test("dropOldest keeps the connection, as it always did")
    func dropOldestKeepsTheConnection() async throws {
        let handler = try makeHandler(overflow: "drop-oldest", bufferSize: 2)
        let peer = SlowPeer()
        let run = Task { try await handler.handle(upgraded: peer.connection, context: makeContext()) }
        try peer.send(Envelope(ref: "1", topic: "flood:a", event: ReservedEvent.join.rawValue))

        // Still serving: the client ends the session itself, and gets the
        // ordinary closure rather than an overflow code.
        try await Task.sleep(for: .milliseconds(200))
        #expect(peer.closed.value == nil, "overflow closed a drop-oldest socket")
        try peer.send(Envelope(ref: "2", topic: "flood:a", event: ReservedEvent.close.rawValue))

        try await run.value
        #expect(peer.closed.value?.code == 1000)
    }

    @Test("drop-oldest counts what it dropped, which is the only trace there is")
    func dropOldestCountsDrops() async throws {
        // `Socket.droppedEnvelopeCount` is what the documentation offers as
        // the reason dropping is not silent — "a subscriber falling behind is
        // visible rather than silent". Nothing asserted it ever moved.
        let box = SocketBox()
        let configuration = Configuration(values: [
            "flight.channels.outbound-buffer-size": "2",
            "flight.channels.outbound-overflow": "drop-oldest",
            "flight.channels.write-timeout-seconds": "30",
            "flight.channels.heartbeat-timeout-seconds": "30",
        ])
        let pubsub = try FlightPubSubModule(configuration: configuration)
        let channels = try FlightChannelsModule(
            bus: pubsub.bus, configuration: configuration,
            channels: [
                ChannelRegistration("flood:*", source: "T") { _ in
                    ReportingFloodChannel(count: 200, box: box)
                }
            ])
        let handler = channels.sockets.handler(principal: nil)
        let peer = SlowPeer()
        let run = Task { try await handler.handle(upgraded: peer.connection, context: makeContext()) }
        try peer.send(Envelope(ref: "1", topic: "flood:a", event: ReservedEvent.join.rawValue))

        try await Task.sleep(for: .milliseconds(250))
        let socket = try #require(box.socket)
        // 200 pushed into a queue of 2, against a writer that takes 30ms a
        // frame: most of them cannot have survived.
        #expect(socket.droppedEnvelopeCount > 0, "dropped nothing with a queue of 2")
        #expect(peer.closed.value == nil, "drop-oldest must not close")

        try peer.send(Envelope(ref: "2", topic: "flood:a", event: ReservedEvent.close.rawValue))
        try await run.value
    }

    @Test("an unknown policy keeps the safe default")
    func unknownPolicyIsSafe() throws {
        // A typo here would silently choose lossy delivery, which is the one
        // outcome nobody would notice.
        let settings = try ChannelsConfiguration(
            configuration: Configuration(values: [
                "flight.channels.outbound-overflow": "drop_oldest"  // wrong spelling
            ]))
        #expect(settings.outboundOverflow == .closeSocket)

        let correct = try ChannelsConfiguration(
            configuration: Configuration(values: [
                "flight.channels.outbound-overflow": "drop-oldest"
            ]))
        #expect(correct.outboundOverflow == .dropOldest)
        #expect(ChannelsConfiguration().outboundOverflow == .closeSocket)
    }

    @Test("everything already queued still reaches the client before the close")
    func queuedFramesAreFlushedFirst() async throws {
        // Teardown finishes the queue and the writer drains it before the
        // close frame goes out. A client that resyncs on reconnect does not
        // need this, but silently truncating what was already accepted would
        // be a second, quieter kind of loss.
        let handler = try makeHandler(overflow: "close", bufferSize: 4)
        let delivered = Counter()
        let closed = CloseBox()
        let (stream, frames) = AsyncStream<WebSocketFrame>.makeStream()
        let connection = WebSocketConnection(
            frames: stream,
            send: { _ in
                delivered.increment()
                try? await Task.sleep(for: .milliseconds(20))
            },
            close: { code, reason in closed.record(code.rawValue, reason) })

        let run = Task { try await handler.handle(upgraded: connection, context: makeContext()) }
        frames.yield(
            .text(try Envelope(ref: "1", topic: "flood:a", event: ReservedEvent.join.rawValue)
                .encodedText()))
        try await run.value

        #expect(closed.value?.code == 4410)
        #expect(delivered.value > 0, "the queue was discarded rather than drained")
    }
}
