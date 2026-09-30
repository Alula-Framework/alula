import AlulaCore

/// Channels' runtime settings, read once at bootstrap from the app
/// `Configuration` (the same source `AlulaTransport` reads its port from).
public struct ChannelsConfiguration: Sendable, Equatable {
    /// A socket silent for longer than this is closed. "Silent" means
    /// no frames at all — any inbound frame, heartbeat or otherwise, counts
    /// as liveness. Clients heartbeat well inside this window (the
    /// reference clients default to 25s against this 60s).
    public var heartbeatTimeout: Duration

    /// How often the liveness watchdog checks. Defaults to a quarter of the
    /// timeout: a socket is detected dead at most timeout + interval after
    /// its last frame, and the check itself is two atomic reads.
    public var heartbeatCheckInterval: Duration

    /// How many outbound envelopes one socket may have queued. What happens
    /// past it is ``outboundOverflow``'s: by default the socket is closed
    /// with `ChannelCloseCode.outboundOverflow`, or with `.dropOldest` the
    /// oldest queued envelopes are dropped.
    ///
    /// The queue used to be unbounded. A client that stopped reading — a
    /// backgrounded tab, a wedged connection, a phone that walked into a
    /// tunnel — accumulated every message published to its topics with no
    /// ceiling, so one stalled subscriber could exhaust the server's memory
    /// while the watchdog waited out its heartbeat timeout.
    ///
    /// When dropping, the *oldest* go: a client that falls behind on a
    /// realtime feed wants the recent state, not a backlog it can never catch
    /// up on. Drops are counted and logged.
    public var outboundBufferSize: Int

    /// How long one outbound frame may take to reach the peer before the
    /// socket is closed. `nil` waits forever, which is what this used to do.
    ///
    /// The bound the heartbeat watchdog cannot supply. A client that keeps
    /// *sending* heartbeats while never *reading* is live by the watchdog's
    /// definition — inbound frames are what it counts — so the watchdog never
    /// fires, and the writer sits in `connection.send` against a TCP window
    /// that never opens, indefinitely. Memory stays bounded by
    /// ``outboundBufferSize``; what leaks is a task and a connection each
    /// time, which is the shape of a slow resource exhaustion rather than a
    /// fast one.
    ///
    /// Per frame, not per socket: a healthy socket that has been open for
    /// days is not close to this bound, and a socket that cannot absorb one
    /// frame in this long is not going to absorb the next.
    public var writeTimeout: Duration?

    /// How a socket's envelopes are ordered against each other — and how many
    /// of them may be in flight at once. See ``EnvelopeDispatch``.
    public var dispatch: EnvelopeDispatch

    /// What happens when ``outboundBufferSize`` is reached. Defaults to
    /// closing the socket, because a dropped frame is invisible to the
    /// client. See ``OutboundOverflow``.
    public var outboundOverflow: OutboundOverflow

    /// How many topics one socket may hold at once.
    ///
    /// Every joined topic costs a channel instance, a PubSub subscription, a
    /// fan-in task and an entry in the session's per-topic ordering — five
    /// allocations, all driven by client input, and until this existed
    /// nothing bounded how many a single connection could ask for.
    ///
    /// Sixty-four is generous for anything legitimate: a chat client holds a
    /// handful, a dashboard a few dozen. There is deliberately no "unlimited"
    /// spelling — unlimited is the bug this replaced. An application that
    /// genuinely needs more writes the larger number down.
    public var maxTopicsPerSocket: Int

    /// Settings built in code. `outboundBufferSize` and
    /// `maxTopicsPerSocket` below 1 are raised to 1; a nil
    /// `heartbeatCheckInterval` is a quarter of the timeout.
    public init(
        heartbeatTimeout: Duration = .seconds(60),
        heartbeatCheckInterval: Duration? = nil,
        outboundBufferSize: Int = 256,
        writeTimeout: Duration? = .seconds(30),
        dispatch: EnvelopeDispatch = .default,
        outboundOverflow: OutboundOverflow = .closeSocket,
        maxTopicsPerSocket: Int = 64
    ) {
        self.heartbeatTimeout = heartbeatTimeout
        self.heartbeatCheckInterval = heartbeatCheckInterval ?? (heartbeatTimeout / 4)
        self.outboundBufferSize = max(1, outboundBufferSize)
        self.writeTimeout = writeTimeout
        self.dispatch = dispatch
        self.outboundOverflow = outboundOverflow
        self.maxTopicsPerSocket = max(1, maxTopicsPerSocket)
    }

    /// Keys, under Alula's usual dotted namespace:
    /// - `channels.heartbeat-timeout-seconds` (Double, default 60)
    /// - `channels.heartbeat-check-interval-seconds` (Double,
    ///   default: a quarter of the timeout)
    /// - `channels.outbound-buffer-size` (Int, default 256)
    /// - `channels.write-timeout-seconds` (Double, default 30; 0
    ///   disables)
    /// - `channels.max-concurrent-envelopes` (Int, default 16; 1
    ///   means one envelope at a time socket-wide)
    /// - `channels.outbound-overflow` (`"close"` or `"drop-oldest"`,
    ///   default `"close"`)
    /// - `channels.max-topics-per-socket` (Int, default 64)
    ///
    /// The pre-0.60 spellings under `alula.channels.*` (and
    /// `ALULA_ALULA_CHANNELS_*`) are refused at startup with ALU-CONFIG-5014,
    /// which names the new key.
    ///
    /// - Throws: ``ChannelsConfigurationError/invalidInterval(key:)`` for a
    ///   duration that is not a positive, finite number of seconds.
    public init(configuration: Configuration) throws {
        // Never `get(_:default:)`, which traps on a malformed value, and
        // never an unchecked `.seconds(_:)`, which traps on `inf` — a
        // deployment typo stopped the process at boot instead of naming the
        // key.
        let invalid = { (value: NonPositiveConfigValue) in
            ChannelsConfigurationError.invalidInterval(key: value.key)
        }
        func seconds(_ name: String) throws -> Duration? {
            try configuration.positiveSeconds(
                "channels.\(name)", formerly: ["alula.channels.\(name)"], orThrow: invalid)
        }
        self.init(
            heartbeatTimeout: try seconds("heartbeat-timeout-seconds") ?? .seconds(60),
            heartbeatCheckInterval: try seconds("heartbeat-check-interval-seconds"),
            outboundBufferSize: try configuration.getIfPresent(
                "channels.outbound-buffer-size", formerly: ["alula.channels.outbound-buffer-size"], as: Int.self) ?? 256,
            // 0 disables it explicitly — an operator who wants no bound
            // should write that down rather than delete a line.
            writeTimeout: try configuration.secondsOrDisabled(
                "channels.write-timeout-seconds", formerly: ["alula.channels.write-timeout-seconds"],
                orThrow: invalid) ?? .seconds(30),
            // 1 is the old socket-wide serialization, spelled as a bound
            // rather than as a separate mode — an operator who wants it back
            // writes the number down.
            dispatch: try configuration.getIfPresent(
                "channels.max-concurrent-envelopes", formerly: ["alula.channels.max-concurrent-envelopes"], as: Int.self)
                .map { $0 <= 1 ? .serialPerSocket : .serialPerTopic(maxConcurrent: $0) }
                ?? .default,
            // Anything other than the two spellings is a typo, and a typo
            // here would silently choose lossy delivery. Unknown values keep
            // the safe default rather than being guessed at.
            outboundOverflow: try configuration.getIfPresent(
                "channels.outbound-overflow", formerly: ["alula.channels.outbound-overflow"], as: String.self)
                .map { $0.lowercased() == "drop-oldest" ? .dropOldest : .closeSocket }
                ?? .closeSocket,
            maxTopicsPerSocket: try configuration.getIfPresent(
                "channels.max-topics-per-socket", formerly: ["alula.channels.max-topics-per-socket"], as: Int.self) ?? 64
        )
    }
}

/// A channels setting that cannot be used. `Alula.run` reports it as
/// ALU-CONFIG-5013, naming the key.
public enum ChannelsConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Not a finite number of seconds, or not positive where it must be.
    case invalidInterval(key: String)

    /// Names the key and the rule.
    public var description: String {
        switch self {
        case .invalidInterval(let key):
            return "\(key) must be a positive, finite number of seconds."
        }
    }
}

extension ChannelsConfigurationError: ModuleConfigurationError {}
