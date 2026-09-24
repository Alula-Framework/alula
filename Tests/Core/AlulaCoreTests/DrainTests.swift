import Logging
import ServiceLifecycle
import Synchronization
import Testing

@testable import AlulaCore

@Suite("Graceful shutdown drains before the transport stops")
struct DrainTests {

    /// Stands in for the HTTP transport: records what readiness said at the
    /// moment it was told to shut down, and when.
    final class InboundProbe: Service, Sendable {
        let health: ModuleHealthRegistry
        private let observed = Mutex<(draining: Bool, at: ContinuousClock.Instant)?>(nil)

        init(health: ModuleHealthRegistry) { self.health = health }

        var observation: (draining: Bool, at: ContinuousClock.Instant)? {
            observed.withLock { $0 }
        }

        func run() async throws {
            try? await gracefulShutdown()
            let draining = health.isDraining
            observed.withLock { $0 = (draining, .now) }
        }
    }

    @Test("readiness is already down while the inbound service is still serving, for the delay")
    func drainPrecedesTransportShutdown() async throws {
        let health = ModuleHealthRegistry()
        let inbound = InboundProbe(health: health)
        let drain = DrainService(
            health: health, delay: .milliseconds(300), logger: Logger(label: "test"))
        // The order bootstrap produces: the drain service last, so it is the
        // first one told to shut down.
        let group = ServiceGroup(
            configuration: .init(
                services: [
                    .init(service: inbound, successTerminationBehavior: .ignore),
                    .init(service: drain, successTerminationBehavior: .ignore),
                ],
                logger: Logger(label: "test")))

        let running = Task { try await group.run() }
        try await Task.sleep(for: .milliseconds(50))
        let signalled = ContinuousClock.now
        await group.triggerGracefulShutdown()
        try await running.value

        #expect(health.isDraining)
        let observation = try #require(inbound.observation)
        #expect(observation.draining, "the transport stopped before readiness went down")
        #expect(observation.at - signalled >= .milliseconds(300))
    }

    @Test("cancellation is not a shutdown: nothing is marked draining")
    func cancellationDoesNotDrain() async throws {
        let health = ModuleHealthRegistry()
        let drain = DrainService(health: health, delay: .seconds(60), logger: Logger(label: "test"))
        let running = Task { try await drain.run() }
        running.cancel()
        try await running.value
        #expect(!health.isDraining)
    }

    @Test("lifecycle settings default to no drain and no bound")
    func defaults() throws {
        #expect(try LifecycleSettings(configuration: Configuration()) == LifecycleSettings())
    }

    @Test("lifecycle settings read seconds, fractions included")
    func readsSeconds() throws {
        let settings = try LifecycleSettings(
            configuration: Configuration(values: [
                "lifecycle.drain-seconds": "2.5",
                "lifecycle.shutdown-timeout-seconds": "20",
            ]))
        #expect(settings.drainDelay == .milliseconds(2500))
        #expect(settings.shutdownTimeout == .seconds(20))
    }

    @Test("a negative drain or a zero timeout is refused rather than guessed at")
    func refusesNonsense() {
        #expect(throws: (any Error).self) {
            try LifecycleSettings(configuration: Configuration(values: ["lifecycle.drain-seconds": "-1"]))
        }
        #expect(throws: (any Error).self) {
            try LifecycleSettings(
                configuration: Configuration(values: ["lifecycle.shutdown-timeout-seconds": "0"]))
        }
    }
}
