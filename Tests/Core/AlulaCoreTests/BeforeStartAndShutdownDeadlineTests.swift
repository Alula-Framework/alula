import Logging
import ServiceLifecycle
import Synchronization
import Testing

@testable import AlulaCore

@Suite("Before-start hooks and the shutdown deadline")
struct BeforeStartAndShutdownDeadlineTests {
    final class Journal: Sendable {
        let entries = Mutex<[String]>([])
        func note(_ entry: String) { entries.withLock { $0.append(entry) } }
        var all: [String] { entries.withLock { $0 } }
    }

    struct Unreachable: Error, CustomStringConvertible {
        var description: String { "could not connect to postgres: password authentication failed" }
    }

    /// A pool that proves itself before anything starts.
    struct PoolModule: AlulaModule {
        let journal: Journal
        var refuse = false
        var serviceShutdownPhase: ServiceShutdownPhase { .infrastructure }
        var service: (any Service)? { Noting(journal: journal, name: "pool service") }
        var lifecycleHooks: [LifecycleHook] {
            [
                .beforeStart("dial") { [refuse] _ in
                    journal.note("pool dial")
                    if refuse { throw Unreachable() }
                }
            ]
        }
    }

    /// A worker that would log about the pool if it ever started.
    struct WorkerModule: AlulaModule {
        let journal: Journal
        var service: (any Service)? { Noting(journal: journal, name: "worker service") }
        var serviceCompletion: ServiceCompletionPolicy { .endsApp }
    }

    struct Noting: Service {
        let journal: Journal
        let name: String
        func run() async throws {
            journal.note(name)
            try? await gracefulShutdown()
        }
    }

    @Test("before-start hooks run before any service starts")
    func beforeStartRunsFirst() async throws {
        let journal = Journal()
        let app = try _alulaAssemble(
            configuration: Configuration(),
            moduleInstances: [PoolModule(journal: journal), WorkerModule(journal: journal)])
        #expect(app.beforeStart.map(\.module) == ["PoolModule"])
        try await runBeforeStartHooks(app.beforeStart)
        #expect(journal.all == ["pool dial"])
    }

    @Test("a failing before-start hook stops the start with its own error, and nothing else runs")
    func beforeStartFailureIsTheCause() async throws {
        // Relay #44: the pool's failure used to arrive last, after the
        // listener announced itself and ten errors about a closed pool.
        let journal = Journal()
        await #expect(throws: Unreachable.self) {
            try await _alulaBootstrap(
                configuration: Configuration(),
                moduleInstances: [
                    PoolModule(journal: journal, refuse: true), WorkerModule(journal: journal),
                ])
        }
        #expect(journal.all == ["pool dial"], "no service started after the pool refused")
        #expect(
            failureReport(for: Unreachable(), detail: nil).contains(
                "password authentication failed"))
    }

    @Test("a module with only a before-start hook has no stand-in service")
    func beforeStartOnlyModuleHasNoService() throws {
        struct CheckOnly: AlulaModule {
            var lifecycleHooks: [LifecycleHook] { [.beforeStart("check") { _ in }] }
        }
        let app = try _alulaAssemble(configuration: Configuration(), moduleInstances: [CheckOnly()])
        #expect(app.services.isEmpty)
        #expect(app.beforeStart.count == 1)
    }

    @Test("the deadline is unset until shutdown begins, then begin plus the timeout")
    func deadline() {
        let unbounded = ShutdownDeadline(timeout: nil)
        unbounded.begin()
        #expect(unbounded.deadline == nil)

        let bounded = ShutdownDeadline(timeout: .seconds(3))
        #expect(bounded.deadline == nil)
        let start = ContinuousClock.now
        bounded.begin(at: start)
        bounded.begin(at: start + .seconds(10))  // only the first counts
        #expect(bounded.deadline == start + .seconds(3))
        #expect(!bounded.overran(at: start + .seconds(2)))
        #expect(bounded.overran(at: start + .seconds(4)))
    }

    /// Ignores graceful shutdown until cancelled.
    struct StubbornModule: AlulaModule {
        struct Stubborn: Service {
            func run() async throws {
                try? await Task.sleep(for: .seconds(30))
            }
        }
        var service: (any Service)? { Stubborn() }
    }

    @Test("a shutdown past its timeout is reported, not exited like a clean stop")
    func shutdownOverrunIsReported() async throws {
        // Relay #36: ServiceLifecycle cancels what is left at the timeout and
        // says so only at debug level; the process exited 0.
        let configuration = Configuration(values: ["lifecycle.shutdown-timeout-seconds": "0.2"])
        let error = await #expect(throws: ShutdownTimedOut.self) {
            try await _alulaBootstrap(
                configuration: configuration, moduleInstances: [StubbornModule(), OneShotModule()])
        }
        let report = failureReport(for: try #require(error), detail: nil)
        #expect(report.hasPrefix("alula: shutdown timed out."))
        #expect(!report.contains("could not start"))
        #expect(report.contains("lifecycle.shutdown-timeout-seconds"))
        #expect(report.contains("StubbornModule"), "names what was still running")
    }

    final class Seen: Sendable {
        let value = Mutex<Duration?>(nil)
    }

    struct PeekModule: AlulaModule {
        struct Peek: Service {
            let seen: Seen
            func run() async throws {
                seen.value.withLock { $0 = ShutdownDeadline.current?.timeout }
            }
        }
        let seen: Seen
        var service: (any Service)? { Peek(seen: seen) }
        var serviceCompletion: ServiceCompletionPolicy { .endsApp }
    }

    @Test("services see the deadline while the application runs")
    func servicesSeeTheDeadline() async throws {
        let seen = Seen()
        try await _alulaBootstrap(
            configuration: Configuration(values: ["lifecycle.shutdown-timeout-seconds": "7"]),
            moduleInstances: [PeekModule(seen: seen)])
        #expect(seen.value.withLock { $0 } == .seconds(7))
    }
}
