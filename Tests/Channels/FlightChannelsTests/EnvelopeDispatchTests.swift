import FlightChannels
import FlightChannelsTesting
import FlightCore
import FlightPubSub
import FlightWeb
import FlightWebTesting
import Foundation
import Synchronization
import Testing

// MARK: - Probe

/// Watches handlers enter and leave, so a test can assert on overlap rather
/// than on elapsed time — which is the difference between a test that proves
/// concurrency and one that proves the machine was not busy.
final class DispatchProbe: Sendable {
    struct State {
        var inFlight = 0
        var peak = 0
        var perTopicInFlight: [String: Int] = [:]
        var perTopicPeak: [String: Int] = [:]
        var completions: [String] = []
    }
    private let state = Mutex(State())

    func enter(_ topic: String) {
        state.withLock {
            $0.inFlight += 1
            $0.peak = max($0.peak, $0.inFlight)
            let topicCount = ($0.perTopicInFlight[topic] ?? 0) + 1
            $0.perTopicInFlight[topic] = topicCount
            $0.perTopicPeak[topic] = max($0.perTopicPeak[topic] ?? 0, topicCount)
        }
    }

    func exit(_ topic: String, _ label: String) {
        state.withLock {
            $0.inFlight -= 1
            $0.perTopicInFlight[topic] = ($0.perTopicInFlight[topic] ?? 1) - 1
            $0.completions.append(label)
        }
    }

    var peak: Int { state.withLock { $0.peak } }
    var completions: [String] { state.withLock { $0.completions } }
    func peak(for topic: String) -> Int { state.withLock { $0.perTopicPeak[topic] ?? 0 } }
}

/// Sleeps for however long the event asks, recording overlap while it does.
struct PacedChannel: Channel {
    let probe: DispatchProbe

    func join(_ topic: String, socket: Socket) async -> JoinResult {
        topic == "paced:locked" ? .reject(.forbidden) : .ok(initialState: .null)
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        let label = event.payload["label"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? ""
        let millis = event.payload["millis"].flatMap { if case .number(let n) = $0 { return Int(n) } else { return nil } } ?? 0
        probe.enter(event.topic)
        if millis > 0 { try? await Task.sleep(for: .milliseconds(millis)) }
        probe.exit(event.topic, label)
        return .reply(["label": .string(label)])
    }
}

struct PacedModule: FlightModule {
    let channels: [ChannelRegistration]
    let probe = DispatchProbe()

    init() {
        let probe = self.probe
        self.channels = [
            ChannelRegistration("paced:*", source: "PacedModule") { _ in PacedChannel(probe: probe) }
        ]
    }
}

/// The stack, with the dispatch bound as the only variable.
struct DispatchHarness {
    let client: TestClient
    let probe: DispatchProbe

    init(maxConcurrent: Int) throws {
        let configuration = Configuration(values: [
            "flight.channels.max-concurrent-envelopes": "\(maxConcurrent)"
        ])
        let pubsub = try FlightPubSubModule(configuration: configuration)
        let fixture = PacedModule()
        let channels = try FlightChannelsModule(
            bus: pubsub.bus, configuration: configuration, channels: fixture.channels)
        self.client = try TestClient(routes: [channels.socketRoute("/socket") { _ in nil }])
        self.probe = fixture.probe
    }

    func wire() async throws -> ChannelWireClient {
        ChannelWireClient(socket: try await client.webSocket("/socket"))
    }
}

/// Collects `count` replies, ignoring anything else.
private func replies(_ wire: ChannelWireClient, count: Int) async throws -> [String] {
    var labels: [String] = []
    while labels.count < count {
        guard let envelope = try await wire.nextEnvelope() else { break }
        guard envelope.event == "flight:reply",
            case .string(let label)? = envelope.payload["label"]
        else { continue }
        labels.append(label)
    }
    return labels
}

// MARK: - Tests

@Suite("Envelope dispatch", .timeLimit(.minutes(1)))
struct EnvelopeDispatchTests {

    @Test("a slow topic no longer blocks a different one")
    func topicsRunConcurrently() async throws {
        // The whole point. Serially this is impossible: "slow" is sent first
        // and takes 200ms, so "fast" could not answer before it.
        let harness = try DispatchHarness(maxConcurrent: 8)
        let wire = try await harness.wire()
        try wire.send(ref: "j1", topic: "paced:a", event: "flight:join")
        try wire.send(ref: "j2", topic: "paced:b", event: "flight:join")
        _ = try await wire.nextEnvelope()
        _ = try await wire.nextEnvelope()

        try wire.send(
            ref: "1", topic: "paced:a", event: "work",
            payload: ["label": "slow", "millis": 200])
        try wire.send(
            ref: "2", topic: "paced:b", event: "work",
            payload: ["label": "fast", "millis": 0])

        #expect(try await replies(wire, count: 2) == ["fast", "slow"])
        wire.close()
    }

    @Test("one topic stays in order, and its channel is never re-entered")
    func oneTopicStaysOrdered() async throws {
        let harness = try DispatchHarness(maxConcurrent: 8)
        let wire = try await harness.wire()
        try wire.send(ref: "j", topic: "paced:a", event: "flight:join")
        _ = try await wire.nextEnvelope()

        // Descending durations: if these overlapped at all, the fast ones
        // would finish first and the order would invert.
        for (index, millis) in [60, 40, 20, 0].enumerated() {
            try wire.send(
                ref: "\(index)", topic: "paced:a", event: "work",
                payload: ["label": .string("e\(index)"), "millis": .number(Double(millis))])
        }

        #expect(try await replies(wire, count: 4) == ["e0", "e1", "e2", "e3"])
        // A `Channel` written against serial delivery must keep it.
        #expect(harness.probe.peak(for: "paced:a") == 1)
        wire.close()
    }

    @Test("envelopes in flight are bounded by the configured maximum")
    func inFlightIsBounded() async throws {
        let harness = try DispatchHarness(maxConcurrent: 2)
        let wire = try await harness.wire()
        for index in 0..<5 {
            try wire.send(ref: "j\(index)", topic: "paced:t\(index)", event: "flight:join")
        }
        for _ in 0..<5 { _ = try await wire.nextEnvelope() }

        for index in 0..<5 {
            try wire.send(
                ref: "\(index)", topic: "paced:t\(index)", event: "work",
                payload: ["label": .string("t\(index)"), "millis": 80])
        }
        _ = try await replies(wire, count: 5)

        // Five topics, all slow, all independent — and still never more than
        // two handlers running. Without the gate this would be five.
        #expect(harness.probe.peak <= 2, "peak was \(harness.probe.peak)")
        wire.close()
    }

    @Test("serialPerSocket restores total order across topics")
    func serialModeIsTotalOrder() async throws {
        let harness = try DispatchHarness(maxConcurrent: 1)
        let wire = try await harness.wire()
        try wire.send(ref: "j1", topic: "paced:a", event: "flight:join")
        try wire.send(ref: "j2", topic: "paced:b", event: "flight:join")
        _ = try await wire.nextEnvelope()
        _ = try await wire.nextEnvelope()

        try wire.send(
            ref: "1", topic: "paced:a", event: "work",
            payload: ["label": "slow", "millis": 150])
        try wire.send(
            ref: "2", topic: "paced:b", event: "work",
            payload: ["label": "fast", "millis": 0])

        #expect(try await replies(wire, count: 2) == ["slow", "fast"])
        #expect(harness.probe.peak == 1)
        wire.close()
    }

    @Test("a push sent before the join has been answered still lands")
    func pushRacesItsOwnJoin() async throws {
        // The race the routable set exists for: the join's work is now
        // asynchronous, so keying "may this socket address the topic" off
        // the populated `joined` map would answer not_joined for a topic
        // whose join is merely still running.
        let harness = try DispatchHarness(maxConcurrent: 8)
        let wire = try await harness.wire()
        try wire.send(ref: "j", topic: "paced:a", event: "flight:join")
        try wire.send(
            ref: "1", topic: "paced:a", event: "work",
            payload: ["label": "after-join", "millis": 0])

        #expect(try await replies(wire, count: 1) == ["after-join"])
        wire.close()
    }

    @Test("a rejected join gives the topic back")
    func rejectedJoinIsNotAddressable() async throws {
        let harness = try DispatchHarness(maxConcurrent: 8)
        let wire = try await harness.wire()
        try wire.send(ref: "j", topic: "paced:locked", event: "flight:join")
        let rejection = try await wire.nextEnvelope()
        #expect(rejection?.event == "flight:error")

        // Reserved at schedule time, so it has to be released on every
        // failing path or the topic stays addressable — and a retry would
        // come back already_joined instead of being allowed.
        try wire.send(ref: "1", topic: "paced:locked", event: "work", payload: ["label": "x"])
        let refused = try await wire.nextEnvelope()
        #expect(refused?.event == "flight:error")
        #expect(refused?.payload["reason"] == .string("not_joined"))

        try wire.send(ref: "j2", topic: "paced:locked", event: "flight:join")
        let retry = try await wire.nextEnvelope()
        #expect(retry?.payload["reason"] == .string("forbidden"))
        wire.close()
    }
}

// MARK: - Topic bound

/// Joins anything, and reports what the socket says it holds.
private struct CountingChannel: Channel {
    func join(_ topic: String, socket: Socket) async -> JoinResult {
        .ok(initialState: .number(Double(socket.activeTopicCount)))
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        // Both spellings: the count, and the set it counts. `activeTopics`
        // is what an application writes a real policy against, so it should
        // agree with the number beside it.
        guard socket.activeTopics.count == socket.activeTopicCount else {
            return .error(reason: "activeTopics disagrees with activeTopicCount")
        }
        return .reply([
            "count": .number(Double(socket.activeTopicCount)),
            "topics": .array(socket.activeTopics.sorted().map { .string($0) }),
        ])
    }
}

private struct CountingModule: FlightModule {
    let channels: [ChannelRegistration] = [
        ChannelRegistration("many:*", source: "CountingModule") { _ in CountingChannel() }
    ]
}

@Suite("Topics per socket", .timeLimit(.minutes(1)))
struct TopicBoundTests {

    private func harness(maxTopics: Int) throws -> TestClient {
        let configuration = Configuration(values: [
            "flight.channels.max-topics-per-socket": "\(maxTopics)"
        ])
        let pubsub = try FlightPubSubModule(configuration: configuration)
        let channels = try FlightChannelsModule(
            bus: pubsub.bus, configuration: configuration,
            channels: CountingModule().channels)
        return try TestClient(routes: [channels.socketRoute("/socket") { _ in nil }])
    }

    @Test("a socket cannot hold more topics than the bound allows")
    func boundIsEnforced() async throws {
        let client = try harness(maxTopics: 3)
        let wire = ChannelWireClient(socket: try await client.webSocket("/socket"))

        for index in 0..<3 {
            try wire.send(ref: "\(index)", topic: "many:\(index)", event: "flight:join")
            #expect(try await wire.nextEnvelope()?.event == "flight:reply")
        }

        // Every join costs a channel, a subscription and a task. Nothing
        // used to stop a connection asking for them without limit.
        try wire.send(ref: "over", topic: "many:4", event: "flight:join")
        let refused = try await wire.nextEnvelope()
        #expect(refused?.event == "flight:error")
        #expect(refused?.payload["reason"] == .string("too_many_topics"))
        wire.close()
    }

    @Test("leaving a topic frees its slot")
    func leavingFreesASlot() async throws {
        let client = try harness(maxTopics: 1)
        let wire = ChannelWireClient(socket: try await client.webSocket("/socket"))

        try wire.send(ref: "1", topic: "many:a", event: "flight:join")
        _ = try await wire.nextEnvelope()
        try wire.send(ref: "2", topic: "many:b", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.payload["reason"] == .string("too_many_topics"))

        try wire.send(ref: "3", topic: "many:a", event: "flight:leave")
        _ = try await wire.nextEnvelope()
        try wire.send(ref: "4", topic: "many:b", event: "flight:join")
        // A bound that counted admissions but never released them would be a
        // one-way ratchet: a long-lived socket would run itself out.
        #expect(try await wire.nextEnvelope()?.event == "flight:reply")
        wire.close()
    }

    @Test("a burst of joins is bounded, not merely the settled count")
    func burstsAreBounded() async throws {
        let client = try harness(maxTopics: 2)
        let wire = ChannelWireClient(socket: try await client.webSocket("/socket"))

        // Sent without waiting for any reply: the bound has to hold against
        // admissions in flight, not against joins that have finished.
        for index in 0..<10 {
            try wire.send(ref: "\(index)", topic: "many:\(index)", event: "flight:join")
        }
        var accepted = 0
        var refused = 0
        for _ in 0..<10 {
            guard let envelope = try await wire.nextEnvelope() else { break }
            if envelope.event == "flight:reply" { accepted += 1 }
            if envelope.payload["reason"] == .string("too_many_topics") { refused += 1 }
        }
        #expect(accepted == 2)
        #expect(refused == 8)
        wire.close()
    }

    @Test("a socket can count its own topics, for policy a channel owns")
    func socketReportsItsTopics() async throws {
        let client = try harness(maxTopics: 10)
        let wire = ChannelWireClient(socket: try await client.webSocket("/socket"))
        try wire.send(ref: "1", topic: "many:a", event: "flight:join")
        _ = try await wire.nextEnvelope()
        try wire.send(ref: "2", topic: "many:b", event: "flight:join")
        _ = try await wire.nextEnvelope()

        try wire.send(ref: "3", topic: "many:a", event: "ping")
        // Both joins are established by now, and a handler can see it — which
        // is what an application needs to write a quota of its own.
        let reply = try await wire.nextEnvelope()
        #expect(reply?.payload["count"] == .number(2))
        #expect(reply?.payload["topics"] == .array([.string("many:a"), .string("many:b")]))
        wire.close()
    }
}
