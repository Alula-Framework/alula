import Logging
import ServiceLifecycle

/// A task the application can be asked to run instead of serving: a data fix,
/// a report, a one-off import.
///
/// ```swift
/// struct AppModule: AlulaModule {
///     let commands: [CommandRegistration]
///
///     init(graph: AlulaGraph) {
///         commands = [
///             CommandRegistration("prune-visits", abstract: "Delete visits older than 90 days") { context in
///                 let removed = try await graph.visits.prune(olderThan: .days(90))
///                 context.logger.info("pruned", metadata: ["rows": "\(removed)"])
///             },
///         ]
///     }
/// }
/// ```
///
/// ```sh
/// swift run App prune-visits          # or: alula run prune-visits
/// swift run App commands              # what there is
/// ```
///
/// A command runs in the application as composed, so it has every component
/// it would have while serving. Only **infrastructure** services are started,
/// meaning database pools and buses. The HTTP server, the scheduler and queue
/// workers stay off, so running a command beside a live deployment does not
/// add a server or run jobs twice. The process exits with 0 when the command
/// returns and 1 when it throws.
public struct CommandRegistration: Sendable {
    public let name: String
    public let abstract: String
    let run: @Sendable (CommandContext) async throws -> Void

    public init(
        _ name: String, abstract: String,
        run: @escaping @Sendable (CommandContext) async throws -> Void
    ) {
        precondition(
            !name.isEmpty && !name.hasPrefix("-") && name != "serve" && name != "commands",
            "a command name must not be empty, start with '-', or be 'serve' or 'commands'")
        self.name = name
        self.abstract = abstract
        self.run = run
    }
}

/// What a running command is handed.
public struct CommandContext: Sendable {
    /// The arguments after the command's name.
    public let arguments: [String]
    public let configuration: Configuration
    public let logger: Logger
}

/// What the process was asked to do, from its arguments.
enum Invocation: Equatable {
    case serve
    case listCommands
    case command(name: String, arguments: [String])

    /// No argument, `serve`, or a first argument that is a flag: serve, as
    /// every Alula application always has. Anything else names a command.
    init(arguments: [String]) {
        guard let first = arguments.first, !first.hasPrefix("-"), first != "serve" else {
            self = .serve
            return
        }
        self =
            first == "commands"
            ? .listCommands : .command(name: first, arguments: Array(arguments.dropFirst()))
    }
}

struct CommandNotFound: Error, CustomStringConvertible {
    let name: String
    let available: [CommandRegistration]
    var description: String {
        "no command named '\(name)'.\n" + CommandListing.text(available)
    }
}

enum CommandListing {
    static func text(_ commands: [CommandRegistration]) -> String {
        guard !commands.isEmpty else {
            return
                "This application declares no commands. A module adds them with `commands: [CommandRegistration]`."
        }
        let width = commands.map(\.name.count).max() ?? 0
        return "Commands:\n"
            + commands.sorted { $0.name < $1.name }.map {
                "  " + $0.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  "
                    + $0.abstract
            }.joined(separator: "\n")
    }
}

/// Runs one command once the infrastructure it borrows is up, then ends the group.
///
/// `ServiceGroup` starts services together, not one after another, so this
/// waits until every infrastructure module reads as running (its service
/// entered, its startup hooks done) before the command starts. It used to
/// start at once, and a command could reach a pool before the pool had.
struct CommandService: Service {
    let command: CommandRegistration
    let context: CommandContext
    var health = ModuleHealthRegistry()
    var infrastructure: [String] = []

    func run() async throws {
        while true {
            let statuses = health.statuses()
            let pending = infrastructure.filter { name in
                statuses.first { $0.moduleName == name }?.health != .running
            }
            if pending.isEmpty { break }
            if let failed = statuses.first(where: {
                pending.contains($0.moduleName) && $0.health.isFailed
            }) {
                throw InfrastructureFailed(module: failed.moduleName)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await command.run(context)
    }
}

struct InfrastructureFailed: Error, CustomStringConvertible {
    let module: String
    var description: String { "\(module) failed to start, so the command did not run" }
}

extension Alula {
    /// Composes, starts only infrastructure services, runs `name`, and returns
    /// when it has finished and the infrastructure has shut down.
    static func runCommand(
        _ name: String, arguments: [String], configuration: Configuration,
        modules instances: [any AlulaModule], health: ModuleHealthRegistry, logger: Logger
    ) async throws {
        let commands = instances.flatMap(\.commands)
        guard let command = commands.first(where: { $0.name == name }) else {
            throw CommandNotFound(name: name, available: commands)
        }
        let app = try _alulaAssemble(
            configuration: configuration, moduleInstances: instances, health: health)
        let infrastructure = app.services.filter { $0.shutdownPhase == .infrastructure }
        var services = infrastructure.map {
            ServiceGroupConfiguration.ServiceConfiguration(service: $0.service)
        }
        services.append(
            .init(
                service: CommandService(
                    command: command,
                    context: CommandContext(
                        arguments: arguments, configuration: configuration,
                        logger: Logger(label: "alula.command.\(name)")),
                    health: health, infrastructure: infrastructure.map(\.moduleName)),
                successTerminationBehavior: .gracefullyShutdownGroup,
                failureTerminationBehavior: .gracefullyShutdownGroup))
        try await ServiceGroup(
            configuration: .init(
                services: services, gracefulShutdownSignals: [.sigterm, .sigint], logger: logger)
        ).run()
    }
}
