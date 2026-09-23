@testable import AlulaChannels
import AlulaChannelsTesting
import AlulaPubSub
import AlulaWeb
import AlulaWebTesting
import Foundation
import Testing

extension ChannelWireClient {
    /// Reads envelopes until one matches — for flows where two outbound
    /// sources (a reply and a broadcast pump) may interleave.
    func expectEnvelope(
        timeoutEnvelopes: Int = 10,
        where predicate: (Envelope) -> Bool
    ) async throws -> Envelope? {
        for _ in 0..<timeoutEnvelopes {
            guard let envelope = try await nextEnvelope() else { return nil }
            if predicate(envelope) { return envelope }
        }
        return nil
    }
}

@Suite("Socket handler — join, replies, errors", .timeLimit(.minutes(1)))
struct SocketHandlerJoinTests {

    @Test("join ok: alula:reply echoes the ref and carries initial state")
    func joinOk() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        try wire.send(ref: "1", topic: "room:42", event: "alula:join")

        let reply = try await wire.nextEnvelope()
        #expect(reply == Envelope(
            ref: "1",
            topic: "room:42",
            event: "alula:reply",
            payload: ["room": "room:42", "history": []]
        ))
        wire.close()
    }

    @Test("join with no initial state replies null payload")
    func joinNullState() async throws {
        let harness = try Harness()
        let wire = try await harness.wire("/socket?token=alice:member")
        try wire.send(ref: "1", topic: "room:members-only", event: "alula:join")
        let reply = try await wire.nextEnvelope()
        #expect(reply?.event == "alula:reply")
        #expect(reply?.payload == ["admitted": "alice"])
        wire.close()
    }

    @Test("join rejected: alula:error with the rejection reason and the ref")
    func joinRejected() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        try wire.send(ref: "9", topic: "room:locked", event: "alula:join")

        let error = try await wire.nextEnvelope()
        #expect(error == Envelope(
            ref: "9",
            topic: "room:locked",
            event: "alula:error",
            payload: ["reason": "forbidden"]
        ))
        wire.close()
    }

    @Test("authorization composes with upgrade-time identity")
    func principalGate() async throws {
        let harness = try Harness()

        // Anonymous socket: unauthenticated.
        let anon = try await harness.wire()
        try anon.send(ref: "1", topic: "room:members-only", event: "alula:join")
        #expect(try await anon.nextEnvelope()?.payload == ["reason": "unauthenticated"])
        anon.close()

        // Authenticated but roleless: forbidden.
        let outsider = try await harness.wire("/socket?token=bob")
        try outsider.send(ref: "1", topic: "room:members-only", event: "alula:join")
        #expect(try await outsider.nextEnvelope()?.payload == ["reason": "forbidden"])
        outsider.close()

        // Member: admitted.
        let member = try await harness.wire("/socket?token=carol:member")
        try member.send(ref: "1", topic: "room:members-only", event: "alula:join")
        #expect(try await member.nextEnvelope()?.event == "alula:reply")
        member.close()
    }

    @Test("a throwing authenticate refuses the upgrade itself (401, no socket)")
    func upgradeRefused() async throws {
        let harness = try Harness()
        await #expect(throws: TestClient.TestClientError.self) {
            _ = try await harness.client.webSocket("/authed")
        }
        // With a token the same mount upgrades fine.
        let wire = try await harness.wire("/authed?token=dana")
        try wire.send(ref: "1", topic: "room:1", event: "alula:join")
        #expect(try await wire.nextEnvelope()?.event == "alula:reply")
        wire.close()
    }

    @Test("unmatched topic, reserved topic, double join — each a named error")
    func joinErrors() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()

        // The fixture registers a catch-all, so unmatched needs a router
        // without one — covered in RouterTests. Here: reserved + double.
        try wire.send(ref: "1", topic: "alula", event: "alula:join")
        #expect(try await wire.nextEnvelope()?.payload == ["reason": "reserved_topic"])

        try wire.send(ref: "2", topic: "room:1", event: "alula:join")
        #expect(try await wire.nextEnvelope()?.event == "alula:reply")
        try wire.send(ref: "3", topic: "room:1", event: "alula:join")
        #expect(try await wire.nextEnvelope()?.payload == ["reason": "already_joined"])
        wire.close()
    }

    @Test("routing precedence end to end: exact lobby beats wildcard and catch-all")
    func routingPrecedence() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        try wire.send(ref: "1", topic: "lobby", event: "alula:join")
        #expect(try await wire.nextEnvelope()?.payload == ["which": "lobby-exact"])
        try wire.send(ref: "2", topic: "somewhere:else", event: "alula:join")
        #expect(try await wire.nextEnvelope()?.payload == ["which": "catch-all"])
        wire.close()
    }
}

@Suite("Socket handler — application events", .timeLimit(.minutes(1)))
struct SocketHandlerEventTests {

    @Test("handler reply rides alula:reply with the inbound ref")
    func echo() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        try wire.send(ref: "5", topic: "room:1", event: "echo", payload: ["body": "hi"])
        let reply = try await wire.nextEnvelope()
        #expect(reply == Envelope(ref: "5", topic: "room:1", event: "alula:reply", payload: ["body": "hi"]))
        wire.close()
    }

    @Test("handler error rides alula:error with the handler's reason")
    func handlerError() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        try wire.send(ref: "5", topic: "room:1", event: "fail")
        #expect(try await wire.nextEnvelope() == Envelope(
            ref: "5", topic: "room:1", event: "alula:error", payload: ["reason": "boom"]
        ))
        wire.close()
    }

    @Test(".none sends nothing, even for a ref-carrying message")
    func silentHandler() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        try wire.send(ref: "5", topic: "room:1", event: "silent")
        try wire.send(ref: "6", topic: "room:1", event: "echo", payload: ["after": true])
        // The next envelope is the echo's reply — nothing arrived for "silent".
        let reply = try await wire.nextEnvelope()
        #expect(reply?.ref == "6")
        wire.close()
    }

    @Test("events on unjoined topics are refused")
    func notJoined() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        try wire.send(ref: "1", topic: "room:1", event: "echo")
        #expect(try await wire.nextEnvelope()?.payload == ["reason": "not_joined"])
        wire.close()
    }

    @Test("client-sent reserved events it may not send are invalid_event")
    func invalidReserved() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        for event in ["alula:reply", "alula:error", "alula:launch"] {
            try wire.send(ref: "1", topic: "room:1", event: event)
            #expect(try await wire.nextEnvelope()?.payload == ["reason": "invalid_event"])
        }
        wire.close()
    }

    @Test("direct socket push: server-initiated, ref null")
    func socketPush() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        try wire.send(ref: nil, topic: "room:1", event: "dm_me")
        let push = try await wire.nextEnvelope()
        #expect(push?.ref == nil)
        #expect(push?.event == "dm")
        wire.close()
    }

    @Test("heartbeat: alula:reply on the control topic, ref echoed")
    func heartbeat() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        try wire.send(ref: "hb1", topic: "alula", event: "alula:heartbeat")
        #expect(try await wire.nextEnvelope() == Envelope(
            ref: "hb1", topic: "alula", event: "alula:reply", payload: .object([:])
        ))
        wire.close()
    }
}

@Suite("Socket handler — broadcast via PubSub", .timeLimit(.minutes(1)))
struct SocketHandlerBroadcastTests {

    @Test("one shout reaches every joined socket, including the sender")
    func fanOut() async throws {
        let harness = try Harness()
        let alice = try await harness.wire("/socket?token=alice")
        let bob = try await harness.wire("/socket?token=bob")
        _ = try await alice.join("room:42")
        _ = try await bob.join("room:42")

        try alice.send(ref: "2", topic: "room:42", event: "shout", payload: ["body": "hello"])

        let toBob = try await bob.expectEnvelope { $0.event == "shouted" }
        #expect(toBob?.payload == ["body": "hello"])
        #expect(toBob?.ref == nil)

        let toAlice = try await alice.expectEnvelope { $0.event == "shouted" }
        #expect(toAlice?.payload == ["body": "hello"])
        // …and Alice also got her reply (order relative to the broadcast
        // is not part of the contract).
        alice.close()
        bob.close()
    }

    @Test("a forged precomputed frame is not forwarded to sockets")
    func forgedPrecomputedFrameIsRefused() async throws {
        // The 0.9.0 encode-once fast path carries the wire frame in message
        // metadata, and the pump forwarded whatever was under that key
        // verbatim — around the reserved-event guard and around
        // valid-envelope framing both. Any in-process publisher that stamped
        // it could push a `alula:join` to every joined socket. Only a frame
        // this process's own broadcaster built is trusted now.
        let harness = try Harness()
        let alice = try await harness.wire()
        _ = try await alice.join("room:42")

        let pubsub = harness.bus
        await pubsub.publish(
            Message(
                topic: "room:42",
                payload: Data(),
                metadata: [
                    // The constants, not their spellings. Written out, a
                    // rename moves the key the broadcaster reads while this
                    // test keeps stamping the old one — and then it passes
                    // because nothing recognises the key, not because the
                    // forged token was refused.
                    ChannelBroadcaster.precomputedFrameMetadataKey:
                        #"{"event":"alula:join","payload":{"forged":true},"topic":"room:42"}"#,
                    ChannelBroadcaster.frameTokenMetadataKey: "guessed",
                ]))

        // Nothing forged arrives. Prove it with a marker that must come after.
        try alice.send(ref: "9", topic: "room:42", event: "echo", payload: ["marker": true])
        let next = try await alice.nextEnvelope()
        #expect(next?.ref == "9", "a forged frame reached the socket: \(String(describing: next))")
        alice.close()
    }

    @Test("broadcast excluding the origin socket skips only the origin")
    func broadcastFrom() async throws {
        let harness = try Harness()
        let alice = try await harness.wire()
        let bob = try await harness.wire()
        _ = try await alice.join("room:42")
        _ = try await bob.join("room:42")

        try alice.send(ref: "2", topic: "room:42", event: "whisper_others", payload: ["psst": true])
        #expect(try await bob.expectEnvelope { $0.event == "whispered" } != nil)

        // Alice must NOT see the whisper. Prove it by a marker that arrives
        // strictly after: her own echoed message.
        _ = try await alice.expectEnvelope { $0.ref == "2" } // the whisper reply
        try alice.send(ref: "3", topic: "room:42", event: "echo", payload: ["marker": true])
        let next = try await alice.nextEnvelope()
        #expect(next?.ref == "3", "alice saw \(String(describing: next)) before her marker")
        alice.close()
        bob.close()
    }

    @Test("fan-out is scoped to the topic")
    func topicScoping() async throws {
        let harness = try Harness()
        let alice = try await harness.wire()
        let bob = try await harness.wire()
        _ = try await alice.join("room:1")
        _ = try await bob.join("room:2")

        try alice.send(ref: "2", topic: "room:1", event: "shout", payload: ["n": 1])
        _ = try await alice.expectEnvelope { $0.event == "shouted" }

        try bob.send(ref: "2", topic: "room:2", event: "echo", payload: ["marker": true])
        let next = try await bob.expectEnvelope { _ in true }
        #expect(next?.ref == "2", "bob saw a foreign broadcast: \(String(describing: next))")
        alice.close()
        bob.close()
    }

    @Test("a non-broadcast payload published to a joined topic is dropped, not delivered")
    func foreignPayloadDropped() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        // Publish raw junk onto the *bus* topic the pump subscribes to,
        // bypassing the broadcaster. (An application publishing to "room:1"
        // itself no longer reaches this path at all — channel traffic has its
        // own namespace, `ChannelProtocol.busTopic(_:)` — so the drop path is
        // reached the only way it still can be.)
        await (try harness.localPubSub).publish(
            Message(topic: ChannelProtocol.busTopic("room:1"), payload: Data("junk".utf8)))

        try wire.send(ref: "2", topic: "room:1", event: "echo", payload: ["marker": true])
        let next = try await wire.nextEnvelope()
        #expect(next?.ref == "2")
        wire.close()
    }
}
