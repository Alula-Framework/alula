import Foundation
import Testing

@testable import AlulaPresence

// Gossip frames come from other nodes, and two one-frame crashes have been
// found in how they merge: a frame claiming this node's own dots (fixed with
// `dropClaims`) and a counter of UInt64.max (overflow in compaction). This
// merges thousands of arbitrary peer states — counters at the edges, claims
// about the receiver, dots with and without context — through the same
// decode-and-join path a frame takes, and keeps tracking locally between
// merges, which is where the first crash surfaced.

private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The wire shape of a state, so a frame can be built freely and decoded
/// through the real `Codable` path.
private struct WireState: Encodable {
    let context: DotContext
    let entries: [PresenceDot: PresenceRecord]
}

@Suite("Presence gossip survives arbitrary peer frames")
struct GossipFuzzTests {
    private let me = PresenceReplicaID(name: "me", boot: "b0")
    private let peers = [
        PresenceReplicaID(name: "p1", boot: "b1"), PresenceReplicaID(name: "p2", boot: "b2"),
    ]

    private func counter(_ rng: inout Seeded) -> UInt64 {
        let edges: [UInt64] = [0, 1, 2, 3, 5, .max - 1, .max, UInt64(Int64.max), UInt64(Int64.max) + 1]
        return Bool.random(using: &rng)
            ? edges.randomElement(using: &rng)! : UInt64.random(in: 0...50, using: &rng)
    }

    @Test("joining arbitrary peer states never traps, and local tracking keeps working")
    func arbitraryFrames() throws {
        var rng = Seeded(state: 42)
        var local = PresenceCRDTState()
        var clock: UInt64 = 0
        let replicas = [me] + peers
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for round in 0..<3_000 {
            var context = DotContext()
            var entries: [PresenceDot: PresenceRecord] = [:]
            for replica in replicas where Bool.random(using: &rng) {
                context.extend(replica, through: counter(&rng))
                for _ in 0..<Int.random(in: 0...3, using: &rng) {
                    let dot = PresenceDot(replica: replica, counter: counter(&rng))
                    context.insert(dot)
                    if Bool.random(using: &rng) {
                        entries[dot] = PresenceRecord(
                            topic: "room:\(round % 3)", key: "u\(round % 7)", ref: "r\(round)", payload: [:])
                    }
                }
            }
            let frame = try encoder.encode(WireState(context: context, entries: entries))
            let incoming = try decoder.decode(PresenceCRDTState.self, from: frame)
            local.join(incoming, ownReplica: me)

            // Track locally, as the tracker does between frames: a frame that
            // raised this node's version past its clock would trap here.
            clock += 1
            local.add(
                PresenceRecord(topic: "room:0", key: "me", ref: "\(clock)", payload: [:]),
                at: PresenceDot(replica: me, counter: clock))

            if round % 500 == 499 {
                _ = local.evict(peers[round / 500 % peers.count])
            }
        }
        #expect(!local.dots(of: me).isEmpty, "this node's own presences survive every frame")
    }
}
