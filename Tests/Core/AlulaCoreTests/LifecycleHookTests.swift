import Logging
import ServiceLifecycle
import Synchronization
import Testing

@testable import AlulaCore

@Suite("Lifecycle hooks")
struct LifecycleHookTests {
    final class Journal: Sendable {
        let entries = Mutex<[String]>([])
        func note(_ entry: String) { entries.withLock { $0.append(entry) } }
        var all: [String] { entries.withLock { $0 } }
    }

    /// A pool: infrastructure, with hooks on both ends.
    struct PoolModule: AlulaModule {
        let journal: Journal
        struct Pool: Service {
            let journal: Journal
            func run() async throws {
                journal.note("pool up")
                try? await gracefulShutdown()
                journal.note("pool down")
            }
        }
        var service: (any Service)? { Pool(journal: journal) }
        var serviceShutdownPhase: ServiceShutdownPhase { .infrastructure }
        var lifecycleHooks: [LifecycleHook] {
            [
                .onStartup("pool: migrate check") { _ in journal.note("pool startup hook") },
                .onShutdown("pool: last flush") { _ in journal.note("pool shutdown hook") },
            ]
        }
    }

    /// Opened by the test; a startup hook waits on it.
    final class Gate: Sendable {
        let open = Mutex(false)
        func wait() async throws {
            while !open.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        }
    }

    /// Hooks and no service.
    struct CacheModule: AlulaModule {
        let journal: Journal
        var gate: Gate? = nil
        var lifecycleHooks: [LifecycleHook] {
            [
                .onStartup("warm") { _ in
                    journal.note("cache warm")
                    try await gate?.wait()
                },
                .onShutdown("flush") { _ in journal.note("cache flush") },
            ]
        }
    }

    struct FailingModule: AlulaModule {
        struct Refused: Error {}
        var lifecycleHooks: [LifecycleHook] {
            [.onStartup("check licence") { _ in throw Refused() }]
        }
    }

    private func run(
        _ modules: [any AlulaModule], health: ModuleHealthRegistry = ModuleHealthRegistry(),
        whileRunning: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(100))
        }
    ) async throws {
        let app = try _alulaAssemble(
            configuration: Configuration(), moduleInstances: modules, health: health)
        let group = ServiceGroup(
            configuration: .init(
                services: app.services.map {
                    .init(service: $0.service, successTerminationBehavior: .ignore)
                },
                logger: Logger(label: "test")))
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }
            try await whileRunning()
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }
    }

    @Test("startup hooks run before their service; shutdown hooks after it, in phase order")
    func ordering() async throws {
        let journal = Journal()
        try await run([PoolModule(journal: journal), CacheModule(journal: journal)])
        let entries = journal.all
        func index(_ entry: String) throws -> Int { try #require(entries.firstIndex(of: entry)) }
        #expect(try index("pool startup hook") < index("pool up"))
        #expect(try index("pool down") < index("pool shutdown hook"))
        // Standard-phase hooks run before infrastructure stops.
        #expect(try index("cache flush") < index("pool down"))
    }

    @Test("a module reads as not started until its startup hooks finish")
    func readinessWaits() async throws {
        let journal = Journal()
        let health = ModuleHealthRegistry()
        let gate = Gate()
        try await run([CacheModule(journal: journal, gate: gate)], health: health) {
            func cache() -> ModuleHealth? {
                health.statuses().first { $0.moduleName == "CacheModule" }?.health
            }
            // The hook has started and is held.
            while !journal.all.contains("cache warm") {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(cache() == .notStarted)
            gate.open.withLock { $0 = true }
            let deadline = ContinuousClock.now + .seconds(10)
            while cache() != .running, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(cache() == .running)
        }
    }

    @Test("a failing startup hook fails the start, naming the hook")
    func failureStopsStart() async throws {
        let health = ModuleHealthRegistry()
        let app = try _alulaAssemble(
            configuration: Configuration(), moduleInstances: [FailingModule()], health: health)
        let group = ServiceGroup(
            configuration: .init(
                services: app.services.map { .init(service: $0.service) },
                logger: Logger(label: "test")))
        do {
            try await group.run()
            Issue.record("the group started")
        } catch {
            #expect("\(error)".contains("check licence"))
        }
        #expect(health.statuses().first?.health.isFailed == true)
    }
}
