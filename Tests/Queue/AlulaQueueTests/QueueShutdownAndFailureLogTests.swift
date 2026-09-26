import AlulaCore
import Foundation
import Logging
import ServiceLifecycle
import Synchronization
import Testing

@testable import AlulaQueue
import AlulaQueueTesting

@Suite("Queue worker: failures logged as state, jobs handed back before the deadline", .serialized)
struct QueueShutdownAndFailureLogTests {
    final class Capture: Sendable {
        let entries = Mutex<[(Logger.Level, String)]>([])
        var logger: Logger { Logger(label: "test") { _ in Handler(capture: self) } }
        var all: [(Logger.Level, String)] { entries.withLock { $0 } }

        struct Handler: LogHandler {
            let capture: Capture
            var metadata: Logger.Metadata = [:]
            var logLevel: Logger.Level = .trace
            subscript(metadataKey key: String) -> Logger.Metadata.Value? {
                get { metadata[key] }
                set { metadata[key] = newValue }
            }
            func log(
                level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
                source: String, file: String, function: String, line: UInt
            ) {
                capture.entries.withLock { $0.append((level, message.description)) }
            }
        }
    }

    struct Down: Error, CustomStringConvertible { var description: String { "postgres unreachable" } }
    struct Other: Error, CustomStringConvertible { var description: String { "something else" } }

    @Test("a repeating failure is logged when it starts, changes and ends, and reminded once a minute")
    func repeatedFailureLog() {
        // Relay #42: 68 identical error lines in 45 seconds from one node.
        let capture = Capture()
        let log = RepeatedFailureLog(
            what: "could not claim jobs", still: "still cannot claim jobs",
            recovered: "claiming jobs again", logger: capture.logger)
        let start = ContinuousClock.now
        for second in 0..<45 { log.failed(Down(), at: start + .seconds(second)) }
        #expect(capture.all.map(\.1) == ["could not claim jobs"])

        log.failed(Down(), at: start + .seconds(61))
        #expect(capture.all.last?.0 == .warning)
        #expect(capture.all.last?.1 == "still cannot claim jobs")

        log.failed(Other(), at: start + .seconds(62))
        #expect(capture.all.last?.0 == .error, "a different error is news")

        log.succeeded(at: start + .seconds(70))
        #expect(capture.all.last?.0 == .info)
        #expect(capture.all.last?.1 == "claiming jobs again")
        #expect(capture.all.count == 4)

        log.succeeded()
        #expect(capture.all.count == 4, "success while healthy says nothing")
    }

    @Test("jobs still running near the shutdown deadline go back to the queue at once")
    func handsBackBeforeDeadline() async throws {
        // Relay #36: past the deadline the pool was cancelled with the worker,
        // the job's result could not be recorded, and it waited out its lease.
        let store = InMemoryQueueStore()
        let queue = JobQueue(store: store)
        let started = AsyncStream<Void>.makeStream()
        let service = try #require(
            try AlulaQueueWorkerModule(
                configuration: Configuration(values: ["queue.lease-seconds": "600"]), queue: queue,
                handlers: [
                    .handle(Greet.self, timeout: nil) { _, _ in
                        started.continuation.yield()
                        try await Task.sleep(for: .seconds(30))
                    }
                ]
            ).service)
        let shutdown = ShutdownDeadline(timeout: .seconds(1))
        let group = ServiceGroup(
            configuration: .init(services: [service], logger: Logger(label: "test")))
        let running = Task {
            try await ShutdownDeadline.$current.withValue(shutdown) { try await group.run() }
        }
        try await queue.enqueue(Greet(name: "long"))
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()

        let began = ContinuousClock.now
        shutdown.begin(at: began)
        await group.triggerGracefulShutdown()
        try await running.value
        let took = ContinuousClock.now - began

        #expect(took < .seconds(1), "handed back before the deadline, not cancelled at it")
        #expect(took >= .milliseconds(700), "not before the margin: jobs get the time there is")
        #expect(
            try await store.counts(queue: "default") == QueueCounts(available: 1),
            "back in the queue now, not running under a ten-minute lease, and not discarded")
    }

    @Test("with no deadline, shutdown still waits for running jobs")
    func noDeadlineWaits() async throws {
        let store = InMemoryQueueStore()
        let queue = JobQueue(store: store)
        let started = AsyncStream<Void>.makeStream()
        let service = try #require(
            try AlulaQueueWorkerModule(
                configuration: Configuration(), queue: queue,
                handlers: [
                    .handle(Greet.self, timeout: nil) { _, _ in
                        started.continuation.yield()
                        try await Task.sleep(for: .milliseconds(400))
                    }
                ]
            ).service)
        let group = ServiceGroup(
            configuration: .init(services: [service], logger: Logger(label: "test")))
        let running = Task { try await group.run() }
        try await queue.enqueue(Greet(name: "short"))
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        await group.triggerGracefulShutdown()
        try await running.value
        #expect(try await store.counts(queue: "default") == QueueCounts(completed: 1))
    }
}
