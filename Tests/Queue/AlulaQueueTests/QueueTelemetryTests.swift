#if Telemetry
    import AlulaCore
    import AlulaTelemetryBridges
    import Foundation
    import TelemetryCore
    import TelemetryTesting
    import Testing

    @testable import AlulaQueue
    import AlulaQueueTesting

    @Suite("Queue telemetry")
    struct QueueTelemetryTests {
        @Test("enqueues and attempts are reported, by kind, queue and outcome")
        func reported() async throws {
            let harness = QueueTestHarness(handlers: [
                .handle(Greet.self) { _, _ in },
                .handle(Flaky.self) { _, _ in throw Boom() },
            ])
            let enqueued = try await TelemetryTest.capture(QueueEvents.Enqueued.self) {
                try await harness.queue.enqueue(Greet(name: "ada"))
                try await harness.queue.enqueue(Flaky(id: 1))
            }
            #expect(enqueued.map(\.metadata.kind).sorted() == ["Flaky", "Greet"])
            #expect(Set(enqueued.map(\.metadata.queue)) == ["default", "flaky"])

            let attempts = await TelemetryTest.capture(QueueEvents.Attempt.self) {
                _ = await harness.drain()
            }
            let outcomes = Dictionary(
                uniqueKeysWithValues: attempts.map { ($0.metadata.kind, $0.metadata.outcome) })
            #expect(outcomes == ["Greet": "completed", "Flaky": "retrying"])
        }

        @Test("the telemetry module reports the queue's metrics, with no name clashes")
        func registered() throws {
            let module = try AlulaTelemetryModule(configuration: Configuration())
            let names = Set(module.reportedMetrics.map(\.descriptor.name))
            for name in ["alula.queue.enqueued", "alula.queue.attempts", "alula.queue.available"] {
                #expect(names.contains(name), "\(name)")
            }
        }
    }
#endif
