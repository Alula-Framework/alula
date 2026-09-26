import Logging
import ServiceLifecycle

/// Everything `bootstrap` builds before handing off to ServiceLifecycle.
/// Exposed so tests (and embedders like a CLI harness) can run the assembly
/// steps without entering a never-returning `ServiceGroup.run()`.
public struct AssembledApplication: Sendable {
    public let services: [AssembledService]
    public let moduleOrder: [String]
    /// Per-module health. Actuator reads it.
    public let health: ModuleHealthRegistry
    /// Every module's ``LifecycleHook/Moment/beforeStart`` hooks, in
    /// dependency order.
    public var beforeStart: [(module: String, hook: LifecycleHook)] = []
}

/// One module's service, health-wrapped, with the module's declared
/// completion policy — bootstrap maps the policy onto ServiceLifecycle's
/// `successTerminationBehavior`.
public struct AssembledService: Sendable {
    public let moduleName: String
    public let service: any Service
    public let completion: ServiceCompletionPolicy
    /// Where this service sits in the start/shutdown order — see
    /// ``ServiceShutdownPhase``.
    public let shutdownPhase: ServiceShutdownPhase

    public init(
        moduleName: String,
        service: any Service,
        completion: ServiceCompletionPolicy,
        shutdownPhase: ServiceShutdownPhase = .standard
    ) {
        self.moduleName = moduleName
        self.service = service
        self.completion = completion
        self.shutdownPhase = shutdownPhase
    }
}

/// Steps 4–8 of the bootstrap sequence: modules composed eagerly in dependency
/// order, health seeding, service collection. Steps 1–3 (environment, YAML,
/// Configuration assembly) belong to Alula Config; this function receives
/// their output. Config must be fully resolved before modules configure —
/// that ordering is enforced here by the signature itself.
///
/// Internal: `Alula.assemble` is the public spelling. This was public with
/// no caller anywhere outside AlulaCore, duplicating that surface under a
/// name nothing was meant to type.
/// Assembly from modules the composition root already built, in dependency
/// order. No container: a module holds what it provides and is constructed by
/// the composer, so assembly only seeds health, collects services, and orders
/// them by shutdown phase. Configuration is fully resolved before this runs —
/// enforced by the signature.
func _alulaAssemble(
    configuration: Configuration,
    moduleInstances instances: [any AlulaModule],
    health: ModuleHealthRegistry = ModuleHealthRegistry()
) throws -> AssembledApplication {
    let names = instances.map { type(of: $0).moduleName }
    // Checked when serving too, not only when a command runs: a duplicate
    // should fail the first start, not the first time someone needs it.
    _ = try CommandCatalog.commands(of: instances)
    health.beginTracking(moduleNames: names)

    var services:
        [(
            moduleName: String, service: any Service, completion: ServiceCompletionPolicy,
            phase: ServiceShutdownPhase, hooks: [LifecycleHook]
        )] = []
    var beforeStart: [(module: String, hook: LifecycleHook)] = []
    for (name, module) in zip(names, instances) {
        let all = module.lifecycleHooks
        beforeStart += all.filter { $0.moment == .beforeStart }.map { (name, $0) }
        let hooks = all.filter { $0.moment != .beforeStart }
        if module.service == nil, !hooks.isEmpty {
            // Hooks without a service: a stand-in holds the module's place so
            // its startup hooks gate readiness and its shutdown hooks run in
            // phase order.
            services.append(
                (name, AwaitShutdownService(), .failsApp, module.serviceShutdownPhase, hooks))
            continue
        }
        // A module with no long-running service is "running" the moment it is
        // part of the assembly. A service-owning one stays `notStarted` until
        // its service is actually entered (see HealthTrackingService) — marking
        // it here made readiness answer yes before anything had started.
        if let service = module.service {
            services.append(
                (name, service, module.serviceCompletion, module.serviceShutdownPhase, hooks))
        } else {
            health.set(name, .running)
        }
    }

    // Sorted by phase, stably, so the DAG's order still decides within a
    // phase. `ServiceGroup` starts in this order and shuts down in reverse,
    // which is what puts infrastructure up first and down last, and the
    // inbound transport up last and down first. Without this the order was
    // whatever order the application listed its modules in, and the shape
    // every example uses shut the database down underneath a server that was
    // still serving — see `ServiceShutdownPhase`.
    let wrapped =
        services
        .enumerated()
        .sorted { left, right in
            left.element.phase == right.element.phase
                ? left.offset < right.offset
                : left.element.phase < right.element.phase
        }
        .map { entry in
            AssembledService(
                moduleName: entry.element.moduleName,
                service: HealthTrackingService(
                    moduleName: entry.element.moduleName, inner: entry.element.service,
                    health: health, hooks: entry.element.hooks,
                    completion: entry.element.completion),
                completion: entry.element.completion,
                shutdownPhase: entry.element.phase
            )
        }
    return AssembledApplication(
        services: wrapped,
        moduleOrder: names,
        health: health,
        beforeStart: beforeStart
    )
}

/// Full bootstrap: assemble, then hand off to ServiceLifecycle. Signal
/// handling, graceful shutdown, and cascading shutdown-on-failure are
/// ServiceLifecycle's problem from here — not Alula's to reinvent.
///
/// Returns only when the ServiceGroup finishes (shutdown or failure). Apps
/// with no long-running services return immediately after assembly — a valid
/// shape for one-shot CLI-style Alula apps.
/// Bootstrap from modules a caller already built, in dependency order — what
/// a generated composer supplies.
func _alulaBootstrap(
    configuration: Configuration,
    moduleInstances instances: [any AlulaModule],
    health: ModuleHealthRegistry = ModuleHealthRegistry(),
    logger: Logger = Logger(label: "alula.bootstrap")
) async throws {
    try await _alulaBootstrap(
        configuration: configuration,
        assembled: _alulaAssemble(
            configuration: configuration, moduleInstances: instances, health: health),
        logger: logger)
}

private func _alulaBootstrap(
    configuration: Configuration,
    assembled app: AssembledApplication,
    logger: Logger
) async throws {
    logger.info(
        "alula assembled",
        metadata: [
            "modules": .array(app.moduleOrder.map { .string($0) }),
            "services": .stringConvertible(app.services.count),
        ])

    guard !app.services.isEmpty else {
        logger.info("no long-running services; bootstrap complete")
        return
    }

    let lifecycle = try LifecycleSettings(configuration: configuration)
    try await runBeforeStartHooks(app.beforeStart)
    let shutdown = ShutdownDeadline(timeout: lifecycle.shutdownTimeout)
    var serviceConfigurations = app.services.map { entry in
        ServiceGroupConfiguration.ServiceConfiguration(
            service: entry.service,
            // .failsApp → .cancelGroup: a server returning early is a
            // failure. .endsApp → graceful shutdown: bounded work done.
            successTerminationBehavior: entry.completion == .endsApp
                ? .gracefullyShutdownGroup
                : .cancelGroup
        )
    }
    // Last to start, so first to be told to shut down: `ServiceGroup` shuts
    // services down one at a time in reverse, waiting for each. The inbound
    // transport is therefore still serving while this flips readiness and
    // waits out `lifecycle.drain-seconds`.
    serviceConfigurations.append(
        .init(
            service: DrainService(
                health: app.health, delay: lifecycle.drainDelay, shutdown: shutdown, logger: logger),
            successTerminationBehavior: .ignore))

    var groupConfiguration = ServiceGroupConfiguration(
        services: serviceConfigurations,
        gracefulShutdownSignals: [.sigterm, .sigint],
        logger: logger)
    groupConfiguration.maximumGracefulShutdownDuration = lifecycle.shutdownTimeout
    let run = ApplicationRun(expected: app.services.count)
    do {
        try await ShutdownDeadline.$current.withValue(shutdown) {
            try await ApplicationRun.$current.withValue(run) {
                try await ServiceGroup(configuration: groupConfiguration).run()  // step 9
            }
        }
    } catch {
        // Said "could not start" about everything, including a module that
        // failed after days of serving.
        throw run.explain(error)
    }
    // ServiceLifecycle cancels what is left at the timeout and says so only at
    // debug level; the process then exited 0, like a clean stop (Relay #36).
    let cancelled = shutdown.cancelledModules
    if !cancelled.isEmpty, let timeout = shutdown.timeout {
        throw ShutdownTimedOut(timeout: timeout, modules: cancelled)
    }
}

/// Runs every module's before-start hooks, in dependency order, before any
/// service exists to log about what they are checking.
func runBeforeStartHooks(_ hooks: [(module: String, hook: LifecycleHook)]) async throws {
    for (module, hook) in hooks {
        var logger = Logger(label: "alula.lifecycle")
        logger[metadataKey: "hook"] = "\(hook.name)"
        logger[metadataKey: "module"] = "\(module)"
        try await hook.run(logger)
    }
}

/// `lifecycle.*`: how the process leaves.
///
/// ```yaml
/// lifecycle:
///   drain-seconds: 5              # readiness says no, transport keeps serving
///   shutdown-timeout-seconds: 25  # then cancel whatever has not finished
/// ```
///
/// `drain-seconds` exists for orchestrators that remove an endpoint some time
/// after they send `SIGTERM` — Kubernetes among them. Without it the listener
/// closes while traffic is still being routed here, and those requests fail.
/// It defaults to zero, so a development `Ctrl-C` stays immediate.
///
/// `shutdown-timeout-seconds` bounds the whole graceful shutdown, drain
/// included; past it, remaining services are cancelled. Unset means no bound —
/// set it below the orchestrator's own grace period, so the process ends on
/// its own terms rather than by `SIGKILL`.
public struct LifecycleSettings: Sendable, Equatable {
    public var drainDelay: Duration
    public var shutdownTimeout: Duration?

    public init(drainDelay: Duration = .zero, shutdownTimeout: Duration? = nil) {
        self.drainDelay = drainDelay
        self.shutdownTimeout = shutdownTimeout
    }

    /// Reads `lifecycle.*`. Throws on a negative or malformed value.
    public init(configuration: Configuration) throws {
        let drain = try configuration.getIfPresent("lifecycle.drain-seconds", as: Double.self) ?? 0
        let timeout = try configuration.getIfPresent(
            "lifecycle.shutdown-timeout-seconds", as: Double.self)
        guard drain >= 0, (timeout ?? 1) > 0, drain.isFinite, (timeout ?? 1).isFinite else {
            throw LifecycleSettingsError(drainSeconds: drain, shutdownTimeoutSeconds: timeout)
        }
        self.init(
            drainDelay: .milliseconds(Int64(drain * 1000)),
            shutdownTimeout: timeout.map { .milliseconds(Int64($0 * 1000)) })
    }
}

struct LifecycleSettingsError: Error, CustomStringConvertible {
    let drainSeconds: Double
    let shutdownTimeoutSeconds: Double?

    var description: String {
        "lifecycle.drain-seconds must be zero or more and lifecycle.shutdown-timeout-seconds "
            + "greater than zero (got \(drainSeconds) and "
            + "\(shutdownTimeoutSeconds.map { "\($0)" } ?? "unset"))"
    }
}

/// Waits for graceful shutdown, then marks the process draining and holds the
/// shutdown sequence for the configured delay — see ``LifecycleSettings``.
struct DrainService: Service {
    let health: ModuleHealthRegistry
    let delay: Duration
    var shutdown: ShutdownDeadline? = nil
    let logger: Logger

    func run() async throws {
        do {
            try await gracefulShutdown()
        } catch {
            return  // cancelled rather than shut down: nothing to drain for
        }
        // Last to start, so the first service told: this is when the
        // shutdown clock started.
        shutdown?.begin()
        health.beginDraining()
        guard delay > .zero else { return }
        logger.info("draining before shutdown", metadata: ["delay": "\(delay)"])
        try? await Task.sleep(for: delay)
    }
}

/// Maps a Service's termination onto ModuleHealth with zero
/// instrumentation required from module authors — bootstrap observes it from
/// the outside, which is the whole point of tracking health externally.
///
/// Also runs the module's ``LifecycleHook``s: startup hooks before `inner`,
/// with the module still `notStarted`, and shutdown hooks once `inner` has
/// returned.
struct HealthTrackingService: Service {
    let moduleName: String
    let inner: any Service
    let health: ModuleHealthRegistry
    var hooks: [LifecycleHook] = []
    var completion: ServiceCompletionPolicy = .failsApp

    func run() async throws {
        for hook in hooks where hook.moment == .startup {
            do {
                try await hook.run(Self.logger(for: hook))
            } catch {
                let failure = LifecycleHookFailure(
                    module: moduleName, hook: hook.name, underlying: error)
                health.set(moduleName, .failed(failure))
                throw failure
            }
        }
        health.set(moduleName, .running)
        ApplicationRun.current?.moduleStarted()
        do {
            try await inner.run()
        } catch {
            if !Task.isCancelled, !(error is CancellationError) {
                ApplicationRun.current?.moduleFailed(moduleName, error)
            }
            noteIfCutOff()
            health.set(moduleName, .failed(error))
            await runShutdownHooks()
            throw error
        }
        noteIfCutOff()
        if completion == .failsApp, !Task.isCancelled,
            !(ShutdownDeadline.current?.hasBegun ?? false)
        {
            ApplicationRun.current?.moduleEndedOnItsOwn(moduleName)
        }
        await runShutdownHooks()
    }

    /// A service that ends cancelled after graceful shutdown began was cut
    /// off at the timeout, not finished: ServiceLifecycle cancels only then.
    private func noteIfCutOff() {
        guard Task.isCancelled, let shutdown = ShutdownDeadline.current, shutdown.hasBegun else { return }
        shutdown.noteCancelled(moduleName)
    }

    private func runShutdownHooks() async {
        for hook in hooks where hook.moment == .shutdown {
            let logger = Self.logger(for: hook)
            do {
                try await hook.run(logger)
            } catch {
                logger.error(
                    "shutdown hook failed", metadata: ["module": "\(moduleName)", "error": "\(error)"])
            }
        }
    }

    private static func logger(for hook: LifecycleHook) -> Logger {
        var logger = Logger(label: "alula.lifecycle")
        logger[metadataKey: "hook"] = "\(hook.name)"
        return logger
    }
}

extension LifecycleSettingsError: ModuleConfigurationError {}
