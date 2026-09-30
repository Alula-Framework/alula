/// When (and whether) the client re-dials after a dropped connection (
/// reconnection is client-driven).
public struct ReconnectPolicy: Sendable {
    /// Delay before reconnect attempt `attempt` (1-based); nil gives up,
    /// moving the client to `.closed`.
    public let delay: @Sendable (_ attempt: Int) -> Duration?

    /// A policy from a closure: attempt number (1-based) in, delay or nil
    /// (give up) out.
    public init(delay: @escaping @Sendable (_ attempt: Int) -> Duration?) {
        self.delay = delay
    }

    /// Doubling backoff from `initial`, capped at `max`, forever by default.
    /// Deterministic — jitter, when a deployment wants it, is one custom
    /// closure away.
    public static func exponentialBackoff(
        initial: Duration = .milliseconds(100),
        max maximum: Duration = .seconds(10),
        maxAttempts: Int? = nil
    ) -> ReconnectPolicy {
        ReconnectPolicy { attempt in
            if let maxAttempts, attempt > maxAttempts { return nil }
            var delay = initial
            for _ in 1..<attempt {
                delay *= 2
                if delay >= maximum { return maximum }
            }
            return min(delay, maximum)
        }
    }

    /// No automatic reconnection: a dropped connection is terminal.
    public static let never = ReconnectPolicy { _ in nil }
}

/// How a ``ChannelClient`` paces heartbeats, waits for replies, reconnects
/// and buffers for slow subscribers.
public struct ChannelClientConfiguration: Sendable {
    /// How often the client sends `alula:heartbeat`. Must be well
    /// inside the server's timeout (default 60s server-side). A heartbeat
    /// whose reply doesn't arrive within one interval is treated as a dead
    /// connection: close and re-dial.
    public var heartbeatInterval: Duration

    /// Default deadline for `join`/`push` replies. Per-call
    /// overridable.
    public var pushTimeout: Duration

    /// When to re-dial after a dropped connection. Default: exponential
    /// backoff from 100 ms to 10 s, forever.
    public var reconnect: ReconnectPolicy

    /// How many messages one `messages()` or `states()` stream may hold for a
    /// subscriber that has stopped consuming, before the oldest are dropped.
    ///
    /// These streams were unbounded, which is the same defect the server side
    /// bounded in `ChannelsConfiguration.outboundBufferSize` — a subscriber
    /// that stops reading grows without ceiling — pointing the other way. The
    /// oldest go first for the same reason: an app that falls behind on a
    /// realtime feed wants the current state, not a backlog it can never
    /// catch up on.
    public var subscriberBufferSize: Int

    /// A configuration; each parameter sets the property of the same name.
    public init(
        heartbeatInterval: Duration = .seconds(25),
        pushTimeout: Duration = .seconds(10),
        reconnect: ReconnectPolicy = .exponentialBackoff(),
        subscriberBufferSize: Int = 256
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.pushTimeout = pushTimeout
        self.reconnect = reconnect
        self.subscriberBufferSize = subscriberBufferSize
    }
}

/// The client's connection lifecycle, observable via
/// `ChannelClient.states()`.
public enum ConnectionState: Sendable, Equatable {
    /// Dialing (first connect or a reconnect attempt).
    case connecting
    /// Open. Channels joined before a drop are re-joined just after this
    /// state is entered, so a join may still be in flight.
    case connected
    /// Dropped; reconnection pending per policy.
    case disconnected
    /// Terminal: `disconnect()` was called, or the reconnect policy gave up.
    /// (An inbound `alula:close` would also end here, but the Alula server
    /// never sends one.) `connect()` starts fresh from here.
    case closed
}

/// Why a ``ChannelClient`` call failed.
public enum ChannelClientError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The client is not connected (call `connect()`, or the connection
    /// dropped and reconnection hasn't succeeded yet).
    case notConnected
    /// No reply within the deadline. The channel may still have
    /// processed the message — at-most-once semantics, inherited end to end.
    case timedOut
    /// The connection dropped while this message awaited its reply.
    case disconnected
    /// The server answered with `alula:error` — join rejected, handler
    /// error, protocol misuse. `reason` is the wire reason
    /// (`ChannelErrorReason` names the server-produced set).
    case channelError(reason: String)

    /// A sentence naming the failure, and the reason for a channel error.
    public var description: String {
        switch self {
        case .notConnected: return "Not connected — call connect() first."
        case .timedOut: return "No reply before the deadline."
        case .disconnected: return "The connection dropped while awaiting a reply."
        case .channelError(let reason): return "Channel error: \(reason)."
        }
    }
}
