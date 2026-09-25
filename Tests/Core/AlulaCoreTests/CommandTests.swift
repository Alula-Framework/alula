import Logging
import ServiceLifecycle
import Synchronization
import Testing

@testable import AlulaCore

@Suite("Application commands")
struct CommandTests {
    final class Journal: Sendable {
        let entries = Mutex<[String]>([])
        func note(_ entry: String) { entries.withLock { $0.append(entry) } }
        var all: [String] { entries.withLock { $0 } }
    }

    /// Stands in for a pool: infrastructure, runs until shut down. It comes
    /// up slowly, in a startup hook, which a command must wait for.
    struct PoolModule: AlulaModule {
        let journal: Journal
        struct Pool: Service {
            let journal: Journal
            func run() async throws {
                try? await gracefulShutdown()
                journal.note("pool down")
            }
        }
        var service: (any Service)? { Pool(journal: journal) }
        var serviceShutdownPhase: ServiceShutdownPhase { .infrastructure }
        var lifecycleHooks: [LifecycleHook] {
            [
                .onStartup("connect") { _ in
                    try await Task.sleep(for: .milliseconds(50))
                    journal.note("pool up")
                }
            ]
        }
    }

    /// Stands in for the HTTP server or a worker: must not start for a command.
    struct ServerModule: AlulaModule {
        let journal: Journal
        struct Server: Service {
            let journal: Journal
            func run() async throws {
                journal.note("server up")
                try? await gracefulShutdown()
            }
        }
        var service: (any Service)? { Server(journal: journal) }
        var serviceShutdownPhase: ServiceShutdownPhase { .inbound }
    }

    struct Failure: Error {}

    struct AppModule: AlulaModule {
        let journal: Journal
        var commands: [CommandRegistration] {
            [
                CommandRegistration("greet", abstract: "Say hello") { context in
                    journal.note("greet \(context.arguments.joined(separator: " "))")
                },
                CommandRegistration("fail", abstract: "Always fails") { _ in throw Failure() },
            ]
        }
    }

    private func modules(_ journal: Journal) -> [any AlulaModule] {
        [PoolModule(journal: journal), ServerModule(journal: journal), AppModule(journal: journal)]
    }

    @Test("arguments choose serve, the listing, or a command")
    func invocation() {
        #expect(Invocation(arguments: []) == .serve)
        #expect(Invocation(arguments: ["serve"]) == .serve)
        #expect(Invocation(arguments: ["--verbose"]) == .serve)
        #expect(Invocation(arguments: ["commands"]) == .listCommands)
        #expect(Invocation(arguments: ["greet", "a", "b"]) == .command(name: "greet", arguments: ["a", "b"]))
    }

    @Test("a command runs with infrastructure up, and nothing else started")
    func runsWithInfrastructureOnly() async throws {
        let journal = Journal()
        try await Alula.runCommand(
            "greet", arguments: ["world"], configuration: Configuration(),
            modules: modules(journal), health: ModuleHealthRegistry(), logger: Logger(label: "test"))
        let entries = journal.all
        #expect(entries.contains("greet world"))
        #expect(!entries.contains("server up"))
        // Up before the command, down after it.
        #expect(entries.first == "pool up")
        #expect(entries.last == "pool down")
    }

    @Test("a failing command's error reaches the caller, after the infrastructure shut down")
    func failurePropagates() async throws {
        let journal = Journal()
        await #expect(throws: (any Error).self) {
            try await Alula.runCommand(
                "fail", arguments: [], configuration: Configuration(),
                modules: modules(journal), health: ModuleHealthRegistry(), logger: Logger(label: "test"))
        }
        #expect(journal.all.last == "pool down")
    }

    /// Relay #20: a command that ran and threw was reported as the
    /// application failing to start.
    @Test("a failing command is reported as the command failing, not as a failed start")
    func failureIsTheCommands() async throws {
        do {
            try await Alula.runCommand(
                "fail", arguments: [], configuration: Configuration(),
                modules: modules(Journal()), health: ModuleHealthRegistry(), logger: Logger(label: "test"))
            Issue.record("the failing command succeeded")
        } catch {
            let report = failureReport(for: error, detail: nil)
            #expect(report.hasPrefix("alula: command 'fail' failed.\n"), "\(report)")
            #expect(!report.contains("could not start"))
        }
    }

    @Test("an unknown command lists the ones there are")
    func unknown() async throws {
        do {
            try await Alula.runCommand(
                "nope", arguments: [], configuration: Configuration(),
                modules: modules(Journal()), health: ModuleHealthRegistry(), logger: Logger(label: "test"))
            Issue.record("ran an unknown command")
        } catch let error as CommandNotFound {
            #expect(error.description.contains("greet"))
            #expect(error.description.contains("Say hello"))
            let report = failureReport(for: error, detail: nil)
            #expect(report.hasPrefix("alula: error: [ALU-CMD-7002] no command named 'nope'\n"), "\(report)")
            #expect(report.contains("greet") && !report.contains("could not start"))
        }
    }
}

@Suite("Command names")
struct CommandNameTests {
    struct First: AlulaModule {
        var commands: [CommandRegistration] { [CommandRegistration("migrate-users", abstract: "a") { _ in }] }
    }
    struct Second: AlulaModule {
        var commands: [CommandRegistration] { [CommandRegistration("migrate-users", abstract: "b") { _ in }] }
    }

    @Test("a name two modules declare is refused, naming both, in either order")
    func duplicate() throws {
        for modules in [[First(), Second()] as [any AlulaModule], [Second(), First()]] {
            do {
                _ = try Alula.assemble(configuration: Configuration(), modules: modules)
                Issue.record("assembled with a duplicate command")
            } catch let error as DuplicateCommand {
                #expect(error.name == "migrate-users")
                #expect(Set(error.modules) == ["First", "Second"])
                #expect(failureReport(for: error, detail: nil).contains("error: [ALU-CMD-7001] command 'migrate-users'"))
            }
        }
    }
}
