import FlightChannels
import FlightChannelsProtocol
import FlightChannelsTesting
import FlightCore
import FlightPubSub
import FlightWeb
import FlightWebTesting
import Foundation
import Synchronization
import Testing

private enum AppRole: String, RouteRole {
    case admin, auditor
}

/// Records whether it was ever built — the role check is meant to refuse
/// before a channel exists for a caller who could never be admitted.
private final class BuildCounter: Sendable {
    private let state = Mutex(0)
    func increment() { state.withLock { $0 += 1 } }
    var value: Int { state.withLock { $0 } }
}

private struct PlainChannel: Channel {
    func join(_ topic: String, socket: Socket) async -> JoinResult { .ok(initialState: .null) }
    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult { .none }
}

/// Role-gated at the pattern, and *also* data-gated in `join` — the two
/// halves the docs say are different questions.
private struct GatedRoomChannel: Channel {
    func join(_ topic: String, socket: Socket) async -> JoinResult {
        topic == "room:private" ? .reject(.forbidden) : .ok(initialState: .null)
    }
    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult { .none }
}

@Suite("Channel roles", .timeLimit(.minutes(1)))
struct ChannelRoleTests {

    private func client(_ builds: BuildCounter) throws -> TestClient {
        let configuration = Configuration(values: [:])
        let pubsub = try FlightPubSubModule(configuration: configuration)
        let channels = try FlightChannelsModule(
            bus: pubsub.bus, configuration: configuration,
            channels: [
                ChannelRegistration("admin:*", roles: [AppRole.admin], source: "test") { _ in
                    builds.increment()
                    return PlainChannel()
                },
                ChannelRegistration(
                    "reports:*", roles: [AppRole.admin, AppRole.auditor], source: "test"
                ) { _ in PlainChannel() },
                ChannelRegistration("room:*", source: "test") { _ in GatedRoomChannel() },
            ])
        return try TestClient(routes: [
            channels.socketRoute("/socket") { context in
                // `?as=admin,auditor` stands in for upgrade-time auth.
                context.request.queryParam("as").map {
                    BasicPrincipal(
                        subject: "u1", roles: Set($0.split(separator: ",").map(String.init)))
                }
            }
        ])
    }

    private func wire(_ builds: BuildCounter, as roles: String? = nil) async throws
        -> ChannelWireClient
    {
        let path = roles.map { "/socket?as=\($0)" } ?? "/socket"
        return ChannelWireClient(socket: try await (try client(builds)).webSocket(path))
    }

    @Test("a topic pattern's roles gate the join")
    func rolesGateTheJoin() async throws {
        let builds = BuildCounter()
        let wire = try await wire(builds, as: "admin")
        try wire.send(ref: "1", topic: "admin:settings", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.event == "flight:reply")
        wire.close()
    }

    @Test("a socket without the role is forbidden, and no channel is built")
    func wrongRoleIsForbidden() async throws {
        let builds = BuildCounter()
        let wire = try await wire(builds, as: "auditor")
        try wire.send(ref: "1", topic: "admin:settings", event: "flight:join")
        let refused = try await wire.nextEnvelope()
        #expect(refused?.payload["reason"] == .string("forbidden"))
        // The point of checking at the registration: a caller who could
        // never be admitted never reaches a channel's constructor.
        #expect(builds.value == 0)
        wire.close()
    }

    @Test("an anonymous socket is unauthenticated, not forbidden")
    func anonymousIsDistinct() async throws {
        let builds = BuildCounter()
        let wire = try await wire(builds)
        try wire.send(ref: "1", topic: "admin:settings", event: "flight:join")
        // "Sign in" and "you cannot do this" are different instructions;
        // collapsing them leaves a client retrying what will never work.
        #expect(try await wire.nextEnvelope()?.payload["reason"] == .string("unauthenticated"))
        wire.close()
    }

    @Test("several roles on one pattern are any-of")
    func rolesAreAnyOf() async throws {
        let builds = BuildCounter()
        let viaAuditor = try await wire(builds, as: "auditor")
        try viaAuditor.send(ref: "1", topic: "reports:q3", event: "flight:join")
        #expect(try await viaAuditor.nextEnvelope()?.event == "flight:reply")
        viaAuditor.close()

        let viaNeither = try await wire(builds, as: "guest")
        try viaNeither.send(ref: "1", topic: "reports:q3", event: "flight:join")
        #expect(try await viaNeither.nextEnvelope()?.payload["reason"] == .string("forbidden"))
        viaNeither.close()
    }

    @Test("a pattern with no roles is unchanged")
    func noRolesMeansOpen() async throws {
        let builds = BuildCounter()
        let wire = try await wire(builds)
        try wire.send(ref: "1", topic: "room:lobby", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.event == "flight:reply")
        wire.close()
    }

    @Test("the channel's own join still decides what roles cannot")
    func joinStillGatesData() async throws {
        // Roles answer "may this kind of client address this kind of topic".
        // Membership of one room is data, and stays in `join`.
        let builds = BuildCounter()
        let wire = try await wire(builds)
        try wire.send(ref: "1", topic: "room:private", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.payload["reason"] == .string("forbidden"))
        wire.close()
    }

    @Test("a refused join leaves the topic joinable again")
    func refusalReleasesTheTopic() async throws {
        let builds = BuildCounter()
        let wire = try await wire(builds, as: "auditor")
        try wire.send(ref: "1", topic: "admin:settings", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.payload["reason"] == .string("forbidden"))
        // Not already_joined: the role refusal has to give the topic back
        // like every other failing path, or one rejection poisons it.
        try wire.send(ref: "2", topic: "admin:settings", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.payload["reason"] == .string("forbidden"))
        wire.close()
    }
}
