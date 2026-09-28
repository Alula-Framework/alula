import Foundation

/// The WebSocket upgrade hook (§6.1): a module that wants to own a
/// long-lived WebSocket connection implements this, without Alula Web
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
/// Dependency direction, stated explicitly (§6.1): consumer → Alula Web →
/// Alula Core, never the reverse — Web only ever sees this protocol, never
/// a specific consumer's own types.
public protocol WebSocketUpgradeHandler: Sendable {
    /// The subprotocols this handler speaks (`Sec-WebSocket-Protocol`),
    /// most preferred first. The first one the client also offered is
    /// agreed in the handshake and handed over as
    /// ``WebSocketConnection/subprotocol``. None agreed, and the handshake
    /// carries no subprotocol, which a client that insisted on one treats
    /// as a failure (RFC 6455 §4.1). Empty by default.
    var subprotocols: [String] { get }

    /// Takes ownership of the now-upgraded connection for its lifetime.
    /// Alula Web's involvement ends the moment this is called — no further
    /// middleware runs, no response encoding happens on Web's side.
    ///
    /// The session lasts exactly as long as this call. Returning — or
    /// throwing — ends it: the NIO transport cancels its inbound reader and
    /// completes the close handshake with ``WebSocketCloseCode/normalClosure``
    /// unless the handler already closed with its own code. A thrown error
    /// does not reach the client and is logged only at `debug`, so a handler
    /// that wants a failure visible logs it itself. Conversely, the inbound
    /// side ending (peer close, server shutdown, protocol error) cancels this
    /// task, so work still running here sees `CancellationError` and further
    /// sends throw ``WebSocketError/connectionClosed``.
    func handle(upgraded connection: WebSocketConnection, context: RequestContext) async throws
}

/// The pre-generalization name, from when WebSocket was the only upgrade
/// kind and the generic name did not yet have to be shared.
extension WebSocketUpgradeHandler {
    public var subprotocols: [String] { [] }
}

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
    /// The inbound side ended. Delivered last; the frame stream finishes
    /// immediately after.
    ///
    /// On the NIO transport this is synthesized, and the code says why the
    /// stream ended rather than what the peer sent: ``WebSocketCloseCode/noStatus``
    /// for a clean close by the peer (the transport consumes the peer's own
    /// close frame, so its code is not recoverable), ``WebSocketCloseCode/goingAway``
    /// when the server is shutting down, and ``WebSocketCloseCode/protocolError``
    /// — with the transport's error as the reason — for an oversized message
    /// or a protocol violation. The in-memory test pair delivers whatever
    /// close the test sent, verbatim.
    case close(code: WebSocketCloseCode, reason: String)
}

/// A WebSocket close status code (RFC 6455 §7.4). Any `UInt16` is
/// accepted; the named constants are the ones Alula itself produces or
/// expects handlers to use.
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
/// test pair — can construct one without Alula Web knowing its internals.
/// The same shape regardless of which HTTP version carried the handshake:
/// RFC 6455's `Upgrade:` and RFC 8441's extended CONNECT differ only below
/// this type, which is what lets an HTTP/2 transport serve every existing
/// handler unmodified.
///
/// `frames` is a single-consumer sequence: iterate it from exactly one task
/// (normally the `WebSocketUpgradeHandler` body). It finishes when the peer
/// closes or the transport shuts the connection down; on the NIO transport
/// a final ``WebSocketFrame/close(code:reason:)`` saying which comes first.
public struct WebSocketConnection: Sendable {
    /// Inbound frames, protocol frames already handled by the transport.
    public let frames: WebSocketFrames
    /// The subprotocol agreed in the handshake, from the handler's
    /// ``WebSocketUpgradeHandler/subprotocols``; nil when none was.
    public private(set) var subprotocol: String?

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

    func agreeing(on subprotocol: String?) -> WebSocketConnection {
        var copy = self
        copy.subprotocol = subprotocol
        return copy
    }

    /// Sends one frame, returning once the transport has taken it.
    ///
    /// On the NIO transport this waits while the socket cannot take more, so
    /// a peer that stops reading slows the sender down instead of growing a
    /// server-side buffer. Safe to call from several tasks at once — each
    /// frame goes out whole — but frames from concurrent senders go out in
    /// no guaranteed order. Sending `.close` is the same as ``close(code:reason:)``
    /// except that it can throw.
    ///
    /// Once the connection is closed — by the peer, the transport, or the
    /// handler's own ``close(code:reason:)`` — or the handler's task is
    /// cancelled, this throws ``WebSocketError/connectionClosed``: nothing is
    /// dropped silently. The
    /// in-memory pair `AlulaWebTesting` provides is the exception: it drops
    /// frames sent after close without throwing, so a test cannot observe
    /// this.
    public func send(_ frame: WebSocketFrame) async throws {
        try await sendFrame(frame)
    }

    /// Sends one text frame. See the `WebSocketFrame` overload for
    /// backpressure and what happens after close.
    public func send(_ text: String) async throws {
        try await sendFrame(.text(text))
    }

    /// Sends one binary frame. See the `WebSocketFrame` overload for
    /// backpressure and what happens after close.
    public func send(_ binary: Data) async throws {
        try await sendFrame(.binary(binary))
    }

    /// Initiates the closing handshake. Idempotent: closing an already
    /// closed connection is a no-op, not an error.
    ///
    /// Returns once the close frame is sent, without waiting for the peer's
    /// reply; the transport finishes the handshake after the handler
    /// returns. On the NIO transport it never actually throws — a failure to
    /// send the close frame is ignored, since the peer may already be gone.
    /// Sending more frames afterwards throws (see `send(_:)`).
    public func close(
        code: WebSocketCloseCode = .normalClosure,
        reason: String = ""
    ) async throws {
        try await closeConnection(code, reason)
    }
}

/// What a ``WebSocketConnection`` throws.
public enum WebSocketError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The connection is gone — closed by the peer or the transport, or the
    /// handler's task was cancelled. A send that throws this was not
    /// delivered; there is no reconnect, so stop sending.
    case connectionClosed
    /// A peer's text frame was not valid UTF-8. For transports that report it
    /// this way; the built-in NIO transport never throws it — it ends the
    /// inbound stream with a ``WebSocketFrame/close(code:reason:)`` carrying
    /// ``WebSocketCloseCode/protocolError`` instead.
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
/// was the only upgraded-connection type Alula had.
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
