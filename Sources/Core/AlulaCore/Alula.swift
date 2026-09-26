import AlulaDiagnostics
import Logging
import ServiceLifecycle

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// The namespace for Alula's top-level entry points.
///
/// These were free functions once. `bootstrap` and `assemble` are useful
/// names, and a foundation package that every other module imports has no
/// business claiming them in every adopter's global scope — an application
/// with its own `bootstrap()` would collide with one it never asked for.
///
/// ```swift
/// await Alula.run(
///     configuration: try Configuration.load(),
///     modules: [WebModule.self, DataModule.self],
///     composedBy: alulaComposeModules
/// )
/// ```
public enum Alula {

    /// Assembles the application from module instances — already built by the
    /// composition root, in dependency order, each declaring what it needs in
    /// its initializer and holding what it provides (COMPOSITION-MIGRATION.md
    /// D11) — and returns the services its modules contribute, without running
    /// anything. There is no container, and no type-based overload: a value
    /// module cannot be built from its type.
    ///
    /// The seam for tests and for embedders that drive the lifecycle
    /// themselves. Use ``bootstrap(configuration:modules:logger:)`` to run.
    ///
    /// ```swift
    /// let app = try Alula.assemble(configuration: config, modules: [appModule])
    /// for service in app.services { /* drive each service's lifecycle */ }
    /// ```
    ///
    /// - Throws: nothing, today. Assembly is bookkeeping — it tracks module
    ///   health, collects each module's service and orders them by shutdown
    ///   phase — because composition already happened in the generated root
    ///   before this is called. `throws` is kept so that a future failure
    ///   here is not a source break for every caller.
    public static func assemble(
        configuration: Configuration,
        modules: [any AlulaModule]
    ) throws -> AssembledApplication {
        try _alulaAssemble(configuration: configuration, moduleInstances: modules)
    }

    /// Assembles the application and runs it under a `ServiceGroup` until
    /// shutdown.
    ///
    /// This is the whole of `main`. It installs signal handling, runs every
    /// registered service, and returns when the group shuts down.
    ///
    /// ```swift
    /// @main
    /// struct App {
    ///     static func main() async throws {
    ///         let configuration = try Configuration.load()
    ///         try await Alula.bootstrap(
    ///             configuration: configuration,
    ///             modules: try alulaComposeModules(configuration, ModuleHealthRegistry())
    ///         )
    ///     }
    /// }
    /// ```
    /// Bootstrap from modules already built by the composition root, in
    /// dependency order — what a generated composer supplies.
    public static func bootstrap(
        configuration: Configuration,
        modules: [any AlulaModule],
        logger: Logger = Logger(label: "alula.bootstrap")
    ) async throws {
        try await _alulaBootstrap(
            configuration: configuration, moduleInstances: modules, logger: logger)
    }

    /// The whole of `main`: run the application, and if it cannot start, say
    /// why and exit non-zero.
    ///
    /// ```swift
    /// @main
    /// struct App {
    ///     static func main() async {
    ///         await Alula.run(
    ///             configuration: try Configuration.load(),
    ///             modules: [AlulaWebModule<AlulaTransport>.self, AppModule.self],
    ///             composedBy: alulaComposeModules
    ///         )
    ///     }
    /// }
    /// ```
    ///
    /// Same work as ``bootstrap(configuration:modules:logger:)``, and one
    /// difference: it does not throw. A `main` that does is the difference
    /// between
    ///
    /// ```
    /// alula: could not start.
    /// Configuration key 'datasource.primary.url' is not set in any source
    /// (active environment: prod). Add it to alula.yaml or alula-prod.yaml,
    /// or set the ALULA_DATASOURCE_PRIMARY_URL environment variable.
    /// ```
    ///
    /// and the same message under `Swift/ErrorType.swift:254: Fatal error:
    /// Error raised at top level:` followed by thirty lines of backtrace and
    /// a `Signal 4` — which is what a thrown error out of `main` produces,
    /// and what every deployment that mistypes a key currently sees. The
    /// message was always good; the frame around it said "this program
    /// crashed" about a configuration typo.
    ///
    /// The configuration is an autoclosure so that a *load* failure — a
    /// missing file, a `${VAR}` with nothing behind it — is reported the same
    /// way as a bootstrap failure rather than trapping at the call site.
    ///
    /// Exits `0` after a graceful shutdown, `1` on a startup failure. An
    /// embedder that wants the error rather than the exit uses `bootstrap`.
    /// `composedBy` is how a module gets to take what it needs.
    ///
    /// `composedBy` is **required**, and there is no path without it. Every
    /// entry point here — `run`, `bootstrap`, `assemble` — takes modules the
    /// composition root already built, because a module that declares its
    /// inputs as initializer parameters cannot be constructed from its type
    /// alone. The type-based path left with the container in 0.17.0.
    ///
    /// The build plugin generates that composer, constructing modules in
    /// dependency order, and `alula new` writes the argument; a module that
    /// still declares `init()` is constructed that way by the composer itself.
    /// `modules:` stays the declaration of which subsystems this application
    /// includes, and is what the plugin reads to know.
    public static func run(
        configuration: @autoclosure @Sendable () throws -> Configuration,
        modules: [any AlulaModule.Type],
        composedBy compose: @Sendable (Configuration, ModuleHealthRegistry) throws -> [any AlulaModule],
        logger: Logger = Logger(label: "alula.bootstrap")
    ) async -> Never {
        do {
            let configuration = try configuration()
            // Before anything composes, so every module's logger gets the
            // configured handler. The `logger` argument was made before this
            // ran, so it is re-made under its own label.
            var logger = logger
            if let logging = try LoggingSettings(configuration: configuration) {
                logging.bootstrap()
                logger = Logger(label: logger.label)
            }
            // The composition root owns the health registry: Actuator reads it,
            // assemble writes module state into it. One shared reference,
            // created here and threaded to both.
            let health = ModuleHealthRegistry()
            switch Invocation(arguments: Array(CommandLine.arguments.dropFirst())) {
            case .serve:
                break
            case .listCommands:
                let modules = try compose(configuration, health)
                print(CommandListing.text(try CommandCatalog.commands(of: modules)))
                exit(0)
            case .command(let name, let arguments):
                try await runCommand(
                    name, arguments: arguments, configuration: configuration,
                    modules: try compose(configuration, health), health: health, logger: logger)
                exit(0)
            }
            try await _alulaBootstrap(
                configuration: configuration,
                moduleInstances: try compose(configuration, health),
                health: health,
                logger: logger)
            exit(0)
        } catch {
            // Written straight to file descriptor 2 rather than through
            // Foundation: this file is in the module every other one imports,
            // and a startup message is not worth a dependency. (`stderr`
            // itself is a `var` in Glibc, which strict concurrency refuses.)
            // The error's own description, never `String(reflecting:)` of it:
            // this catch receives errors from configuration, every module,
            // third-party code and application commands, and a reflected
            // error can carry a connection URL with its password, a token, or
            // a secret configuration value. An error that has something safe
            // and more useful to say conforms to `StartupDiagnostic`.
            // `ALULA_STARTUP_ERROR_DETAIL=reflect` prints the reflected form
            // for a local session that needs it, and only when asked.
            let message = failureReport(for: error)
            let bytes = Array(message.utf8)
            bytes.withUnsafeBufferPointer { buffer in
                var written = 0
                while written < buffer.count {
                    let result = write(2, buffer.baseAddress! + written, buffer.count - written)
                    if result <= 0 { break }
                    written += result
                }
            }
            exit(1)
        }
    }

}

/// An error that knows what about itself is safe and useful to print when the
/// application cannot start: the host and port it could not reach, the errno,
/// the configuration key that was wrong. Never credentials, tokens or values
/// a key holds.
///
/// ```swift
/// struct PoolStartFailed: Error, StartupDiagnostic {
///     let host: String, port: Int, reason: String
///     var startupDiagnostic: String { "could not connect to \(host):\(port): \(reason)" }
/// }
/// ```
///
/// `Alula.run` prints this in place of the error's description. Anything that
/// does not conform is printed with `String(describing:)`, which respects the
/// redaction an error's author chose.
public protocol StartupDiagnostic: Error {
    var startupDiagnostic: String { get }
    /// The Alula diagnostic code, for a failure the framework owns — printed
    /// with a link to its page. Applications leave it `nil`.
    var diagnosticCode: DiagnosticCode? { get }
}

extension StartupDiagnostic {
    public var diagnosticCode: DiagnosticCode? { nil }
}

/// A module's settings are invalid — the error a module's configuration
/// check throws while the application starts, such as a TLS certificate path
/// with no key, or a rate limit of zero.
///
/// `Alula.run` prints it as ALU-CONFIG-5013, with the module's own message:
/// the message says what is wrong, the code says what kind of problem it is
/// and where the page is. A marker rather than a `StartupDiagnostic`
/// conformance, so a module declares the kind of error it throws without
/// depending on the diagnostics.
public protocol ModuleConfigurationError: Error {}

/// The code for a framework-owned startup failure, if it has one.
///
/// Configuration errors are mapped here rather than conforming where they
/// are declared: `AlulaConfigCore` sits below the diagnostics and is
/// shared with the build tool, and a key missing at startup is the same
/// problem, with the same page, as one the build found missing.
func diagnosticCode(for error: any Error) -> DiagnosticCode? {
    switch error {
    case let config as ConfigError:
        switch config {
        case .missingKey: return .missingConfigKey
        case .decodingFailed: return .invalidConfigValue
        case .providerFailed, .unrepresentableValue: return .configSourceFailed
        }
    case let load as ConfigLoadError:
        switch load {
        case .missingBaseFile: return .missingBaseConfigFile
        case .unreadableFile, .parseFailed: return .unreadableConfigFile
        case .unresolvedSubstitution: return .unsetConfigVariable
        case .preRenameConfiguration: return .preRenameConfiguration
        }
    case let diagnostic as any StartupDiagnostic:
        return diagnostic.diagnosticCode
    case is any ModuleConfigurationError:
        return .invalidModuleSettings
    default:
        return nil
    }
}

/// What `Alula.run` prints for an error that stopped the start.
func startupReport(
    for error: any Error,
    detail: String? = getenv("ALULA_STARTUP_ERROR_DETAIL").map { String(cString: $0) }
) -> String {
    if detail == "reflect" {
        return String(reflecting: error)
    }
    if let diagnostic = error as? any StartupDiagnostic {
        return diagnostic.startupDiagnostic
    }
    return String(describing: error)
}

/// Everything `Alula.run` prints when it exits with 1.
///
/// Three different things end the process that way, and saying "could not
/// start" about all of them was wrong twice: a command that ran and threw
/// had started, and a mistyped command name had nothing to do with starting.
/// Framework-owned failures carry their code, in the same shape as the
/// build's diagnostics.
func failureReport(
    for error: any Error,
    detail: String? = getenv("ALULA_STARTUP_ERROR_DETAIL").map { String(cString: $0) }
) -> String {
    switch error {
    case let timedOut as ShutdownTimedOut:
        // It started and served; saying "could not start" about it would be
        // the Relay #20 mistake again.
        return "alula: shutdown timed out.\n\(timedOut.description)\n"
    case let failed as CommandFailed:
        return "alula: command '\(failed.name)' failed.\n\(startupReport(for: failed.underlying, detail: detail))\n"
    case let notFound as CommandNotFound:
        let listing = CommandListing.text(notFound.available)
        return "alula: "
            + AlulaDiagnostics.Diagnostic(
                .unknownCommand, "no command named '\(notFound.name)'", at: nil,
                context: listing.split(separator: "\n").map(String.init),
                help: ["`commands` lists them; with no argument the application serves."]
            ).rendered + "\n"
    case let duplicate as DuplicateCommand:
        return "alula: could not start.\n"
            + AlulaDiagnostics.Diagnostic(
                .duplicateCommand,
                "command '\(duplicate.name)' is declared by \(duplicate.modules.joined(separator: " and "))", at: nil,
                explanation: ["Command names are one namespace across the application."],
                help: ["rename one of them."]
            ).rendered + "\n"
    default:
        let report = startupReport(for: error, detail: detail)
        guard let code = diagnosticCode(for: error) else {
            return "alula: could not start.\n\(report)\n"
        }
        return "alula: could not start.\n"
            + AlulaDiagnostics.Diagnostic(code, report, at: nil).rendered + "\n"
    }
}
