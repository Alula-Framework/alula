import Foundation

/// The WebSocket upgrade hook (§6.1): a module that wants to own a
/// long-lived WebSocket connection implements this, without Flight Web
/// needing to know *why* — Channels is one consumer, a raw
/// `@WebSocketRoute` handler is another.
///
/// Named for the protocol it hands you, deliberately. An upgrade is not one
/// thing: RFC 8441 generalizes HTTP/2's CONNECT into a family (`websocket`,
/// `connect-udp`, WebTransport), and those kinds do not share a useful
/// connection shape — WebTransport is streams *plus* datagrams, not a frame
/// sequence. So each kind gets its own handler protocol and its own
/// connection type, and ``UpgradeResponse`` is the discriminated seam that
/// carries whichever kind a route produced. When WebTransport lands it will
/// be a sibling (`WebTransportUpgradeHandler`), not a change to this one.
///
/// Dependency direction, stated explicitly (§6.1): consumer → Flight Web →
/// Flight Core, never the reverse — Web only ever sees this protocol, never
/// a specific consumer's own types.
public protocol WebSocketUpgradeHandler: Sendable {
    /// Takes ownership of the now-upgraded connection for its lifetime.
    /// Flight Web's involvement ends the moment this is called — no further
    /// middleware runs, no response encoding happens on Web's side.
    func handle(upgraded connection: WebSocketConnection, context: RequestContext) async throws
}

/// The pre-generalization name, from when WebSocket was the only upgrade
/// kind and the generic name did not yet have to be shared.
@available(*, deprecated, renamed: "WebSocketUpgradeHandler")
public typealias ConnectionUpgradeHandler = WebSocketUpgradeHandler

/// One WebSocket frame, post protocol-handling: the transport owns
/// fragmentation reassembly, masking, and the close handshake; the developer
/// owns message semantics (§6.1).
public enum WebSocketFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
    /// Delivered for observability; the transport already answered with a
    /// pong (RFC 6455 §5.5.2) before delivering it.
    case ping(Data)
    case pong(Data)
    /// The peer initiated (or acknowledged) closing. Delivered last; the
    /// frame stream finishes immediately after.
    case close(code: WebSocketCloseCode, reason: String)
}

public struct WebSocketCloseCode: Sendable, Equatable, RawRepresentable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let normalClosure = WebSocketCloseCode(1000)
    public static let goingAway = WebSocketCloseCode(1001)
    public static let protocolError = WebSocketCloseCode(1002)
    public static let unacceptableData = WebSocketCloseCode(1003)
    /// RFC 6455: a close frame may omit the code entirely.
    public static let noStatus = WebSocketCloseCode(1005)
}

/// A thin `Sendable` wrapper over async send/receive of WebSocket frames
/// (§6.1). Closure-backed so any transport — the NIO default, an in-memory
/// test pair — can construct one without Flight Web knowing its internals.
/// The same shape regardless of which HTTP version carried the handshake:
/// RFC 6455's `Upgrade:` and RFC 8441's extended CONNECT differ only below
/// this type, which is what lets an HTTP/2 transport serve every existing
/// handler unmodified.
///
/// `frames` is a single-consumer sequence: iterate it from exactly one task
/// (normally the `WebSocketUpgradeHandler` body). It finishes when the peer
/// closes or the transport shuts the connection down.
public struct WebSocketConnection: Sendable {
    /// Inbound frames, protocol frames already handled by the transport.
    public let frames: WebSocketFrames

    private let sendFrame: @Sendable (WebSocketFrame) async throws -> Void
    private let closeConnection: @Sendable (WebSocketCloseCode, String) async throws -> Void

    public init(
        frames: WebSocketFrames,
        send: @escaping @Sendable (WebSocketFrame) async throws -> Void,
        close: @escaping @Sendable (WebSocketCloseCode, String) async throws -> Void
    ) {
        self.frames = frames
        self.sendFrame = send
        self.closeConnection = close
    }

    /// Builds one over a stream, for a transport that already has one in hand.
    ///
    /// Carries a buffer, and therefore no backpressure — what the stream's
    /// producer puts in it is bounded only by the producer. Fine for an
    /// in-memory pair in a test, wrong for a socket: see ``WebSocketFrames``.
    public init(
        frames: AsyncStream<WebSocketFrame>,
        send: @escaping @Sendable (WebSocketFrame) async throws -> Void,
        close: @escaping @Sendable (WebSocketCloseCode, String) async throws -> Void
    ) {
        self.init(frames: WebSocketFrames(frames), send: send, close: close)
    }

    /// Sends one frame. Throws `WebSocketError.connectionClosed` once the
    /// connection is gone.
    public func send(_ frame: WebSocketFrame) async throws {
        try await sendFrame(frame)
    }

    public func send(_ text: String) async throws {
        try await sendFrame(.text(text))
    }

    public func send(_ binary: Data) async throws {
        try await sendFrame(.binary(binary))
    }

    /// Initiates the closing handshake. Idempotent: closing an already
    /// closed connection is a no-op, not an error.
    public func close(
        code: WebSocketCloseCode = .normalClosure,
        reason: String = ""
    ) async throws {
        try await closeConnection(code, reason)
    }
}

public enum WebSocketError: Error, Sendable, Equatable, CustomStringConvertible {
    case connectionClosed
    case invalidUTF8InTextFrame

    public var description: String {
        switch self {
        case .connectionClosed:
            return "The WebSocket connection is closed."
        case .invalidUTF8InTextFrame:
            return "Peer sent a text frame that is not valid UTF-8 (RFC 6455 §8.1)."
        }
    }
}


/// The pre-generalization name for ``WebSocketConnection``, from when it
/// was the only upgraded-connection type Flight had.
@available(*, deprecated, renamed: "WebSocketConnection")
public typealias UpgradedConnection = WebSocketConnection

/// Which protocol an upgrade route hands the connection to. One case today;
/// WebTransport and other RFC 8441 `:protocol` kinds are additive cases. In
/// the route table (``RouteRegistration/Kind``) this is what will let a
/// bootstrap check refuse a route the active transport cannot serve —
/// at composition, not at the first request that hits it.
public enum UpgradeKind: Sendable, Equatable, CaseIterable {
    case webSocket
}


/// Inbound frames, pulled one at a time.
///
/// **Pull-based on purpose**, and for the reason the HTTP body path already
/// gives: the obvious shape — a task reading the socket and feeding an
/// `AsyncStream` — carries an unbounded buffer, so the feeder races ahead of
/// the handler and a peer that sends faster than the handler works grows the
/// server's memory without limit. A per-message size cap does not help; it
/// bounds each message, not how many are queued.
///
/// Pulling one frame per demand instead puts backpressure where it belongs:
/// a handler that has not asked for the next frame is a handler that is not
/// reading the socket, and TCP slows the peer down. The cost is that a slow
/// handler is now visible as a slow *client* rather than as memory growth,
/// which is the trade worth making — one of those is a bug report and the
/// other is an outage.
///
/// Single-consumer: iterate from exactly one task.
public struct WebSocketFrames: AsyncSequence, Sendable {
    public typealias Element = WebSocketFrame

    private let pull: @Sendable () async -> WebSocketFrame?

    /// Builds one from a source that yields a frame per demand and `nil` when
    /// the connection is done. A transport's own constructor.
    public init(pulling next: @escaping @Sendable () async -> WebSocketFrame?) {
        self.pull = next
    }

    /// Adapts a stream, for transports and harnesses that produce one. The
    /// stream's buffering is then what bounds memory, which for an
    /// `AsyncStream` built with `makeStream()` is nothing at all.
    public init(_ stream: AsyncStream<WebSocketFrame>) {
        let source = StreamSource(stream)
        self.init(pulling: { await source.next() })
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(pull: pull)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let pull: @Sendable () async -> WebSocketFrame?
        public mutating func next() async -> WebSocketFrame? { await pull() }
    }

    /// Holds a stream's iterator, which is neither `Sendable` nor safe to
    /// advance concurrently.
    ///
    /// Outside any actor because `next()` is `mutating` and `async`, which an
    /// actor-isolated property cannot offer. Access is serialized by this
    /// sequence's single-consumer contract instead — the same attestation,
    /// for the same reason, as `BodyPuller` on the request-body side.
    private final class StreamSource: @unchecked Sendable {
        private var iterator: AsyncStream<WebSocketFrame>.AsyncIterator

        init(_ stream: AsyncStream<WebSocketFrame>) {
            self.iterator = stream.makeAsyncIterator()
        }

        func next() async -> WebSocketFrame? {
            await iterator.next()
        }
    }
}
