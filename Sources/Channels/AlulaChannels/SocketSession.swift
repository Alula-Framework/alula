import AlulaChannelsProtocol
import AlulaPubSub
import AlulaWeb
import Logging
import Synchronization

/// Per-socket protocol state: which topics are joined, which `Channel`
/// instance and PubSub pump each holds, and liveness. An actor because
/// joins, leaves, inbound events, the watchdog, and teardown all touch this
/// state from different tasks; envelope *processing* is serialized per
/// socket by the frame loop itself (one message fully handled before the
/// next is read — the ordering a stateful protocol wants).
internal actor SocketSession {

    /// What the frame loop should do after one envelope is handled.
    internal enum Directive: Sendable, Equatable {
        case proceed
        /// Stop the session and close the transport with this code. Replies
        /// already enqueued are flushed first (the writer drains the
        /// outbound queue before the close frame goes out).
        case close(code: WebSocketCloseCode, reason: String)
    }

    private struct JoinedChannel {
        let channel: any Channel
        let pump: Task<Void, Never>
    }

    private let router: ChannelRouter
    private let pubsub: any PubSub
    private let socket: Socket
    private let outbound: AsyncStream<String>.Continuation
    private let logger: Logger

    private var joined: [String: JoinedChannel] = [:]
    private var lastActivity = ContinuousClock.now
    private var isTornDown = false

    /// How envelopes are ordered against each other on this socket.
    private let dispatch: EnvelopeDispatch
    /// How many topics this socket may hold at once.
    private let maxTopics: Int
    /// Bounds envelopes in flight for this socket.
    private let gate: EnvelopeGate
    /// The tail of each topic's serial chain. A topic's next envelope awaits
    /// this one, which is what keeps a topic ordered while topics run
    /// concurrently — and what guarantees a `Channel` is never re-entered.
    private var topicTails: [String: Task<Void, Never>] = [:]
    /// Topics this socket may address: a join has been *accepted for
    /// scheduling*, which is earlier than `joined` being populated.
    ///
    /// Two sets rather than one because the join work is now asynchronous. A
    /// client that sends `alula:join` and a push back to back is entitled to
    /// have the push routed — it will run after the join on the same chain —
    /// and keying the decision off `joined` would answer `not_joined` for a
    /// topic whose join is merely still running.
    private var routable: Set<String> = []

    /// The broadcast seam, handed to a channel factory at join time as part
    /// of its ``ChannelContext``.
    private let broadcaster: ChannelBroadcaster

    internal init(
        router: ChannelRouter,
        pubsub: any PubSub,
        socket: Socket,
        outbound: AsyncStream<String>.Continuation,
        logger: Logger,
        broadcaster: ChannelBroadcaster,
        dispatch: EnvelopeDispatch = .default,
        maxTopics: Int = 64
    ) {
        self.router = router
        self.pubsub = pubsub
        self.socket = socket
        self.outbound = outbound
        self.logger = logger
        self.broadcaster = broadcaster
        self.dispatch = dispatch
        self.maxTopics = max(1, maxTopics)
        self.gate = EnvelopeGate(capacity: dispatch.maxConcurrent)
    }

    // MARK: - Liveness

    internal func touch() {
        lastActivity = .now
    }

    internal var idleDuration: Duration {
        ContinuousClock.now - lastActivity
    }

    // MARK: - Inbound routing

    internal func handle(_ envelope: Envelope) async -> Directive {
        guard !isTornDown else { return .proceed }

        switch ReservedEvent(rawValue: envelope.event) {
        case .join:
            await scheduleJoin(envelope)
        case .leave:
            await scheduleTopicWork(envelope) { await $0.leave(envelope) }
        case .heartbeat:
            heartbeat(envelope)
        case .close:
            // Graceful client-initiated teardown. The ack must be
            // enqueued BEFORE teardown — teardown finishes the outbound
            // queue, and the writer flushes only what was queued first.
            if let ref = envelope.ref {
                socket.sendReply(ref: ref, topic: envelope.topic, payload: .object([:]))
            }
            await teardown()
            return .close(code: .normalClosure, reason: "client close")
        case .reply, .error:
            // Server-to-client events; a client never sends them.
            socket.sendError(ref: envelope.ref, topic: envelope.topic, reason: ChannelErrorReason.invalidEvent)
        case nil where envelope.event.hasPrefix(ReservedEvent.prefix):
            // alula:-namespaced but not a reserved event we know. Because
            // Alula versions protocol and clients together, this is a
            // client bug — named as such, connection kept.
            socket.sendError(ref: envelope.ref, topic: envelope.topic, reason: ChannelErrorReason.invalidEvent)
        case nil:
            await scheduleTopicWork(envelope) { await $0.dispatchApplicationEvent(envelope) }
        }
        return .proceed
    }

    // MARK: - Scheduling

    /// Admits a join and puts its work on the topic's chain.
    ///
    /// The refusals stay synchronous — a reserved topic and a double join are
    /// both decidable from state this actor already holds, and answering them
    /// here keeps them ordered ahead of anything the client sends next.
    private func scheduleJoin(_ envelope: Envelope) async {
        let topic = envelope.topic
        guard topic != ChannelProtocol.controlTopic else {
            socket.sendError(
                ref: envelope.ref, topic: topic, reason: ChannelErrorReason.reservedTopic)
            return
        }
        guard !routable.contains(topic) else {
            socket.sendError(
                ref: envelope.ref, topic: topic, reason: ChannelErrorReason.alreadyJoined)
            return
        }
        // Counted against admissions rather than completed joins: a client
        // that sends a thousand joins in a burst has a thousand of them
        // pending long before any has finished, and a bound that only sees
        // finished joins would not be a bound at all.
        guard routable.count < maxTopics else {
            socket.sendError(
                ref: envelope.ref, topic: topic, reason: ChannelErrorReason.tooManyTopics)
            return
        }
        routable.insert(topic)
        await run(topic: topic) { await $0.join(envelope) }
    }

    /// Puts work on a topic's chain, refusing a topic this socket never
    /// joined.
    private func scheduleTopicWork(
        _ envelope: Envelope,
        _ work: @escaping @Sendable (isolated SocketSession) async -> Void
    ) async {
        guard routable.contains(envelope.topic) else {
            socket.sendError(
                ref: envelope.ref, topic: envelope.topic,
                reason: ChannelErrorReason.notJoined)
            return
        }
        await run(topic: envelope.topic, work)
    }

    /// Runs `work` after everything already queued for `topic`.
    ///
    /// Serial mode awaits it here, which is precisely the old behaviour: the
    /// frame loop does not read the next frame until this returns.
    /// Concurrent mode chains it behind the topic's tail and returns, holding
    /// one slot of the socket's in-flight budget until it finishes — so the
    /// frame loop stalls on a full budget rather than on a slow handler.
    private func run(
        topic: String,
        _ work: @escaping @Sendable (isolated SocketSession) async -> Void
    ) async {
        guard dispatch.isConcurrent else {
            await work(self)
            return
        }
        await gate.acquire()
        let previous = topicTails[topic]
        let gate = self.gate
        topicTails[topic] = Task { [weak self] in
            await previous?.value
            if let self { await work(self) }
            await gate.release()
        }
    }

    // MARK: - Join (the join is the gate)

    /// The reserved-topic and double-join refusals live in ``scheduleJoin``,
    /// which answers them before this is ever queued. What remains here is
    /// everything that needs the router or the channel itself — and every
    /// failing path has to give the topic back, or a rejected join would
    /// leave it addressable forever.
    private func join(_ envelope: Envelope) async {
        let topic = envelope.topic
        guard !isTornDown else { return }
        guard let registration = router.match(topic) else {
            routable.remove(topic)
            socket.sendError(ref: envelope.ref, topic: topic, reason: ChannelErrorReason.unmatchedTopic)
            return
        }
        if let refusal = Self.roleRefusal(registration.roles, for: socket.principal) {
            routable.remove(topic)
            socket.sendError(ref: envelope.ref, topic: topic, reason: refusal)
            return
        }

        let channel: any Channel
        do {
            channel = try registration.makeChannel(
                ChannelContext(
                    topic: topic, broadcaster: broadcaster, principal: socket.principal))
        } catch {
            logger.error("channel factory failed", metadata: [
                "topic": "\(topic)", "source": "\(registration.source)", "error": "\(error)",
            ])
            routable.remove(topic)
            socket.sendError(ref: envelope.ref, topic: topic, reason: ChannelErrorReason.handlerError)
            return
        }

        switch (await channel.join(topic, socket: socket)).outcome {
        case .rejected(let rejection):
            routable.remove(topic)
            socket.sendError(ref: envelope.ref, topic: topic, reason: rejection.reason)

        case .accepted(let initialState):
            // Order is load-bearing (PubSub's "effective when
            // subscribe returns"): subscribe first so no broadcast between
            // admission and pump start is lost; enqueue the join reply
            // second; start the pump last. Everything funnels through one
            // outbound queue, so the client always sees the join reply
            // before any broadcast.
            let subscription = pubsub.subscribe(ChannelProtocol.busTopic(topic))
            if let ref = envelope.ref {
                socket.sendReply(ref: ref, topic: topic, payload: initialState ?? .null)
            }
            let pump = Task {
                await Self.pump(
                    subscription: subscription,
                    topic: topic,
                    socket: self.socket,
                    logger: self.logger
                )
            }
            joined[topic] = JoinedChannel(channel: channel, pump: pump)
            // Membership is fully established (pump subscribed): let
            // framework observers (Presence's state push) run, ordered
            // after the join reply and never ahead of the subscription.
            socket.notifyTopicActivated(topic)
        }
    }

    /// One channel's fan-in: iterate the PubSub stream and enqueue each
    /// broadcast for this socket. `nonisolated` so per-message delivery
    /// never hops through the session actor.
    ///
    /// The common case (a `ChannelBroadcaster` publish) carries its final
    /// wire text precomputed in metadata — every subscriber's `Envelope` for
    /// one broadcast is byte-identical, so `publish` builds it once and
    /// every pump here just forwards the same `String` by reference: no
    /// decode, no per-subscriber re-encode. A message with no such key (a
    /// hand-built `BroadcastFrame`, e.g. Presence) falls back to decoding
    /// and encoding it directly — slower, but correct, and unchanged from
    /// before this fast path existed.
    private nonisolated static func pump(
        subscription: AsyncStream<Message>,
        topic: String,
        socket: Socket,
        logger: Logger
    ) async {
        for await message in subscription {
            if message.metadata[ChannelBroadcaster.originMetadataKey] == socket.id {
                continue // broadcast(..., excluding:) — this socket is the origin
            }
            // Only a frame this process's own broadcaster built is
            // forwarded unvalidated. The key alone was enough before, so any
            // in-process publisher that stamped it had its string sent
            // verbatim to every joined socket — around the reserved-event
            // guard and around valid-envelope framing both.
            if let precomputed = message.metadata[ChannelBroadcaster.precomputedFrameMetadataKey],
                let token = message.metadata[ChannelBroadcaster.frameTokenMetadataKey],
                token == ChannelBroadcaster.frameToken
            {
                socket.enqueueEncoded(precomputed, topic: topic, event: "<broadcast>")
                continue
            }
            guard let frame = BroadcastFrame(message: message) else {
                // Rate-limited for the same reason the outbound queue's own
                // drop log is: this fires once per *socket* per message, so
                // an application that publishes its own messages to a topic
                // its channels also use — the topic namespace is shared,
                // nothing reserves it — turned one publish into one warning
                // per connected socket, forever.
                let total = foreignPayloads.wrappingAdd(1, ordering: .relaxed).oldValue + 1
                if total == 1 || total % 100 == 0 {
                    logger.warning(
                        "dropping non-broadcast payload on channel topic",
                        metadata: [
                            "topic": "\(topic)",
                            "dropped-total": "\(total)",
                        ])
                }
                continue
            }
            guard
                let text = try? Envelope(ref: nil, topic: topic, event: frame.event, payload: frame.payload)
                    .encodedText()
            else {
                logger.warning("broadcast envelope failed to encode", metadata: ["topic": "\(topic)"])
                continue
            }
            socket.enqueueEncoded(text, topic: topic, event: frame.event)
        }
    }

    /// How many messages this process has seen on a channel topic that were
    /// not channel broadcasts — the counter behind the rate-limited log
    /// above.
    private nonisolated static let foreignPayloads = Atomic<Int64>(0)

    // MARK: - Leave

    private func leave(_ envelope: Envelope) async {
        routable.remove(envelope.topic)
        guard let entry = joined.removeValue(forKey: envelope.topic) else {
            // Reachable when a join was refused by its channel and the client
            // leaves anyway: the topic was routable, so this queued, and
            // there is nothing to leave.
            socket.sendError(ref: envelope.ref, topic: envelope.topic, reason: ChannelErrorReason.notJoined)
            return
        }
        entry.pump.cancel()
        await entry.channel.leave(envelope.topic, socket: socket)
        socket.notifyTopicTerminated(envelope.topic)
        if let ref = envelope.ref {
            socket.sendReply(ref: ref, topic: envelope.topic, payload: .object([:]))
        }
    }

    /// The reason a socket may not address a topic, or nil to let it
    /// through.
    ///
    /// Anonymous and under-privileged stay distinct for the same reason the
    /// web layer keeps 401 and 403 apart: "sign in" and "you cannot do this"
    /// are different instructions, and collapsing them leaves a client
    /// retrying something that will never work.
    private static func roleRefusal(
        _ roles: [any RouteRole], for principal: (any ChannelPrincipal)?
    ) -> String? {
        guard !roles.isEmpty else { return nil }
        guard let principal else { return ChannelErrorReason.unauthenticated }
        let permitted = roles.contains { principal.hasRole($0.roleName) }
        return permitted ? nil : ChannelErrorReason.forbidden
    }

    // MARK: - Heartbeat

    private func heartbeat(_ envelope: Envelope) {
        // touch() already ran in the frame loop; just ack.
        if let ref = envelope.ref {
            socket.sendReply(ref: ref, topic: ChannelProtocol.controlTopic, payload: .object([:]))
        }
    }

    // MARK: - Application events

    private func dispatchApplicationEvent(_ envelope: Envelope) async {
        guard let entry = joined[envelope.topic] else {
            socket.sendError(ref: envelope.ref, topic: envelope.topic, reason: ChannelErrorReason.notJoined)
            return
        }
        let event = InboundEvent(
            topic: envelope.topic,
            event: envelope.event,
            payload: envelope.payload,
            ref: envelope.ref
        )
        switch (await entry.channel.handle(event, socket: socket)).outcome {
        case .none:
            break
        case .reply(let payload):
            if let ref = envelope.ref {
                socket.sendReply(ref: ref, topic: envelope.topic, payload: payload)
            }
        case .error(let reason):
            socket.sendError(ref: envelope.ref, topic: envelope.topic, reason: reason)
        }
    }

    // MARK: - Teardown (structured, no manual cleanup)

    /// Leaves every channel (handler `leave` runs, PubSub pumps end) and
    /// finishes the outbound queue so the writer drains and exits.
    /// Idempotent — every exit path (peer close, `alula:close`, protocol
    /// violation, heartbeat timeout, server shutdown) funnels here once.
    internal func teardown() async {
        guard !isTornDown else { return }
        isTornDown = true
        // Cancelled, not awaited. Awaiting would make a hung application
        // handler able to block teardown — and teardown is what the
        // heartbeat watchdog and the protocol-violation path call to get rid
        // of exactly that socket. In-flight envelopes are dropped; a client
        // that needs its push acknowledged before closing has the reply's
        // `ref` to wait on.
        for tail in topicTails.values { tail.cancel() }
        topicTails = [:]
        routable = []
        await gate.drain()
        let entries = joined
        joined = [:]
        for (topic, entry) in entries {
            entry.pump.cancel()
            await entry.channel.leave(topic, socket: socket)
            socket.notifyTopicTerminated(topic)
        }
        socket.notifyClosed()
        outbound.finish()
    }

    // MARK: - Introspection (tests, diagnostics)

    internal var joinedTopics: Set<String> {
        Set(joined.keys)
    }
}
