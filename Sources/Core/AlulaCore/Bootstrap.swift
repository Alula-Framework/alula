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
    health.beginTracking(moduleNames: names)

    var services:
        [(
            moduleName: String, service: any Service, completion: ServiceCompletionPolicy,
            phase: ServiceShutdownPhase
        )] = []
    for (name, module) in zip(names, instances) {
        // A module with no long-running service is "running" the moment it is
        // part of the assembly. A service-owning one stays `notStarted` until
        // its service is actually entered (see HealthTrackingService) — marking
        // it here made readiness answer yes before anything had started.
        if let service = module.service {
            services.append((name, service, module.serviceCompletion, module.serviceShutdownPhase))
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
                    health: health),
                completion: entry.element.completion,
                shutdownPhase: entry.element.phase
            )
        }
    return AssembledApplication(
        services: wrapped,
        moduleOrder: names,
        health: health
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
            service: DrainService(health: app.health, delay: lifecycle.drainDelay, logger: logger),
            successTerminationBehavior: .ignore))

    var groupConfiguration = ServiceGroupConfiguration(
        services: serviceConfigurations,
        gracefulShutdownSignals: [.sigterm, .sigint],
        logger: logger)
    groupConfiguration.maximumGracefulShutdownDuration = lifecycle.shutdownTimeout
    try await ServiceGroup(configuration: groupConfiguration).run()  // step 9
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
    let logger: Logger

    func run() async throws {
        do {
            try await gracefulShutdown()
        } catch {
            return  // cancelled rather than shut down: nothing to drain for
        }
        health.beginDraining()
        guard delay > .zero else { return }
        logger.info("draining before shutdown", metadata: ["delay": "\(delay)"])
        try? await Task.sleep(for: delay)
    }
}

/// Maps a Service's termination onto ModuleHealth with zero
/// instrumentation required from module authors — bootstrap observes it from
/// the outside, which is the whole point of tracking health externally.
struct HealthTrackingService: Service {
    let moduleName: String
    let inner: any Service
    let health: ModuleHealthRegistry

    func run() async throws {
        health.set(moduleName, .running)
        do {
            try await inner.run()
        } catch {
            health.set(moduleName, .failed(error))
            throw error
        }
    }
}
