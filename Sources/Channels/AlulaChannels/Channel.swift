import AlulaChannelsProtocol

/// Per-topic server logic: joining a topic creates one instance of the
/// registered `Channel` for that (socket, topic) pair, so implementations
/// may keep per-membership state in stored properties.
public protocol Channel: Sendable {
    /// Called when a client attempts to join this channel's topic. Return
    /// `.ok` to admit (optionally with initial state to send back), or
    /// `.reject` to deny — this is the authorization point.
    func join(_ topic: String, socket: Socket) async -> JoinResult

    /// A message arrived FROM this client on this channel.
    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult

    /// Optional: called when the client leaves or the socket closes.
    func leave(_ topic: String, socket: Socket) async
}

extension Channel {
    /// Does nothing.
    public func leave(_ topic: String, socket: Socket) async {}
}

/// A channel whose join reads what the client sent with it: a cursor ("I
/// have everything up to seq 812"), a filter, a client version.
///
/// The join frame always carried a payload, but ``Channel/join(_:socket:)``
/// was never given it, so anything a join needed took a second message and a
/// round trip — Relay's incident rooms joined, then asked to catch up
/// (Relay #21). Adopt this instead of `Channel` and implement only this
/// `join`; the other is provided.
///
/// ```swift
/// struct Room: PayloadJoinChannel {
///     func join(_ topic: String, payload: JSONValue, socket: Socket) async -> JoinResult {
///         let after = payload["after"]?.intValue ?? 0
///         return .ok(initialState: ["events": await timeline(topic, after: after)])
///     }
///     func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult { .none }
/// }
/// ```
public protocol PayloadJoinChannel: Channel {
    /// Called when a client attempts to join, with the join frame's payload
    /// (an empty object when the client sent none). The authorization
    /// point, as ``Channel/join(_:socket:)`` is for a plain channel.
    func join(_ topic: String, payload: JSONValue, socket: Socket) async -> JoinResult
}

extension PayloadJoinChannel {
    /// Calls ``join(_:payload:socket:)`` with an empty object. The server
    /// calls the payload form directly; this exists so the type is a
    /// ``Channel``.
    public func join(_ topic: String, socket: Socket) async -> JoinResult {
        await join(topic, payload: .object([:]), socket: socket)
    }
}

/// Why a join was refused. The `reason` string travels to the client in the
/// `alula:error` payload — keep it wire-safe.
public struct JoinRejection: Sendable, Equatable {
    /// The wire reason, as the client sees it.
    public let reason: String

    /// A rejection with an application-defined `reason`.
    public init(_ reason: String) {
        self.reason = reason
    }

    /// `unauthenticated`: the socket has no principal.
    public static let unauthenticated = JoinRejection(ChannelErrorReason.unauthenticated)
    /// `forbidden`: the principal may not join this topic.
    public static let forbidden = JoinRejection(ChannelErrorReason.forbidden)
}

/// The outcome of `Channel.join`.
///
///     return .ok
///     return .ok(initialState: currentRoomState())
///     return .reject(.forbidden)
public struct JoinResult: Sendable {
    internal enum Outcome: Sendable {
        case accepted(initialState: JSONValue?)
        case rejected(JoinRejection)
    }

    internal let outcome: Outcome

    /// Admit, with no initial state (the join reply's payload is `null`).
    public static let ok = JoinResult(outcome: .accepted(initialState: nil))

    /// Admit, sending `initialState` back as the join reply's payload.
    public static func ok(initialState: JSONValue) -> JoinResult {
        JoinResult(outcome: .accepted(initialState: initialState))
    }

    /// Refuse: the client gets `alula:error` with the rejection's reason,
    /// and the channel instance is discarded.
    public static func reject(_ rejection: JoinRejection) -> JoinResult {
        JoinResult(outcome: .rejected(rejection))
    }
}

/// One application event from the client, as `Channel.handle` receives it.
/// `topic` is included because one `Channel` registration may serve a
/// wildcard pattern (`"room:*"`) — the instance knows which topic it holds.
public struct InboundEvent: Sendable, Equatable {
    /// The joined topic this event arrived on.
    public let topic: String
    /// The application event name; never `alula:`-namespaced.
    public let event: String
    /// The event's payload, as the client sent it.
    public let payload: JSONValue
    /// Present when the client wants a reply.
    public let ref: String?

    /// An event; the server builds these, and a test calling `handle`
    /// directly builds its own.
    public init(topic: String, event: String, payload: JSONValue, ref: String?) {
        self.topic = topic
        self.event = event
        self.payload = payload
        self.ref = ref
    }
}

/// The outcome of `Channel.handle`: reply to a ref-carrying message,
/// report an error, or say nothing.
///
/// `.none` on a ref-carrying message sends no reply — the client's awaited
/// push times out on its side. That mirrors Phoenix's `:noreply`: whether a
/// given event replies is part of the channel's contract with its client,
/// not something the transport paper over.
public struct HandleResult: Sendable {
    internal enum Outcome: Sendable {
        case none
        case reply(JSONValue)
        case error(reason: String)
    }

    internal let outcome: Outcome

    /// No reply. Broadcast side effects have already happened in `handle`.
    public static let none = HandleResult(outcome: .none)

    /// Send a `alula:reply` echoing the inbound `ref`. Dropped if
    /// the inbound message carried no ref — there is nothing to correlate.
    public static func reply(_ payload: JSONValue) -> HandleResult {
        HandleResult(outcome: .reply(payload))
    }

    /// Send a `alula:error` (with the inbound `ref`, when present) carrying
    /// `{"reason": reason}`. Keep the reason wire-safe; detail belongs in
    /// the server log.
    public static func error(reason: String) -> HandleResult {
        HandleResult(outcome: .error(reason: reason))
    }
}
