import AlulaChannelsClient
import Foundation
import HTTPTypes
import HummingbirdWSClient
import Logging

/// A WebSocket for `ChannelClient`: swift-websocket's client, with the
/// headers the server needs to know who is connecting — a session cookie, a
/// bearer token.
///
/// `AlulaChannelsClient` is transport-free on purpose, and every Swift
/// client of a channel used to copy the 60-line adapter from Alula's own
/// end-to-end tests, then add the headers it lacked (Relay #30). This is
/// that adapter, shipped.
///
/// swift-websocket sends `Origin: ws://<host>` of its own. Alula's
/// WebSocket origin check lets a `ws://` or `wss://` origin through — no
/// browser sends one — so this connects to an Alula server with its default
/// settings.
///
/// ```swift
/// var headers = HTTPFields()
/// headers[.cookie] = "session=\(sessionID)"
/// let client = ChannelClient(
///     url: URL(string: "wss://app.example.com/socket")!,
///     transport: WebSocketChannelTransport(headers: headers))
/// ```
public struct WebSocketChannelTransport: ChannelClientTransport {
    /// Sent with the handshake.
    public var headers: HTTPFields
    /// The largest inbound message accepted, in bytes.
    public var maxMessageSize: Int
    let logger: Logger

    public init(
        headers: HTTPFields = HTTPFields(), maxMessageSize: Int = 1 << 20,
        logger: Logger = Logger(label: "alula.channels.transport")
    ) {
        self.headers = headers
        self.maxMessageSize = maxMessageSize
        self.logger = logger
    }

    public func connect(to url: URL) async throws -> ClientTransportConnection {
        let (incoming, incomingContinuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let (outgoing, outgoingContinuation) = AsyncStream<String>.makeStream()
        let (ready, readyContinuation) = AsyncStream<Result<Void, any Error>>.makeStream()
        let configuration = WebSocketClientConfiguration(additionalHeaders: headers)
        let maxMessageSize = self.maxMessageSize
        let logger = self.logger
        let session = Task {
            do {
                try await WebSocketClient.connect(
                    url: url.absoluteString, configuration: configuration, logger: logger
                ) { inbound, outbound, _ in
                    readyContinuation.yield(.success(()))
                    readyContinuation.finish()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            var iterator = inbound.makeAsyncIterator()
                            while let message = try await iterator.nextMessage(
                                maxSize: maxMessageSize)
                            {
                                if case .text(let text) = message {
                                    incomingContinuation.yield(text)
                                }
                            }
                        }
                        group.addTask {
                            for await text in outgoing { try await outbound.write(.text(text)) }
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                }
                incomingContinuation.finish()
            } catch {
                // Before the handshake completed, this is the caller's
                // answer; after, it ends the stream it is reading.
                readyContinuation.yield(.failure(error))
                incomingContinuation.finish(throwing: error)
            }
            readyContinuation.finish()
        }
        var readiness = ready.makeAsyncIterator()
        switch await readiness.next() {
        case .success?:
            break
        case .failure(let error)?:
            session.cancel()
            throw WebSocketChannelTransportError(url: url, reason: "\(error)")
        case nil:
            session.cancel()
            throw WebSocketChannelTransportError(
                url: url, reason: "the connection closed during the handshake")
        }
        return ClientTransportConnection(
            incoming: incoming,
            send: { text in outgoingContinuation.yield(text) },
            close: {
                outgoingContinuation.finish()
                session.cancel()
            })
    }
}

/// The WebSocket could not be opened.
public struct WebSocketChannelTransportError: Error, Sendable, CustomStringConvertible {
    public let url: URL
    public let reason: String

    public var description: String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        return
            "could not open a WebSocket to \(components?.string ?? url.absoluteString): \(reason)"
    }
}
