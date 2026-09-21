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

/// Vestigial: **nothing throws any of these cases.**
///
/// They describe failures the runtime container used to have — a duplicate
/// registration, an eager singleton whose initializer threw — and
/// composition moved into generated code before `assemble` runs, so the
/// failures they name now happen at *build* time, as diagnostics from the
/// registration generator, or not at all.
///
/// Kept because removing a public error type is a source break for anything
/// that catches it, and because two of the cases describe composition
/// failures a future change could plausibly reintroduce. A `catch` for this
/// type today is dead code.
public enum BootstrapError: Error, CustomStringConvertible {
    case moduleConfigurationFailed(module: String, underlying: any Error)
    case singletonConstructionFailed(underlying: any Error)

    /// Two registrations claimed the same type.
    ///
    /// Usually a generated existential bridge colliding with a hand-written
    /// registration, in which case the hand-written one is now redundant and
    /// should go. Qualifying one of them was the other answer until 0.20.0
    /// removed qualifiers; registrations are keyed by type alone.
    case duplicateRegistration(String)

    /// A module named only by its type takes what it provides as initializer
    /// parameters, so it cannot be built from its type — the composition root
    /// must construct it.
    case moduleRequiresConstruction(module: String)

    public var description: String {
        switch self {
        case .moduleConfigurationFailed(let module, let underlying):
            return "Module \(module) failed to build during composition: \(underlying)"
        case .singletonConstructionFailed(let underlying):
            return "Eager singleton construction failed at composition: \(underlying)"
        case .duplicateRegistration(let key):
            return """
                Duplicate registration for \(key). Two registrations claim the same type — \
                often a generated existential bridge colliding with a hand-written \
                registration, in which case the hand-written one is redundant and should \
                go. Registrations are keyed by type alone; qualifiers were removed in 0.20.0.
                """
        case .moduleRequiresConstruction(let module):
            return """
                \(module) takes what it provides as initializer parameters, so it cannot be \
                built from its type. It was reached by name or through the module dependency \
                graph.

                Build it and pass the instance instead of the type. An application gets this \
                for free from the generated composition root — pass \
                `composedBy: flightComposeModules` to Flight.run, which is what `flight new` \
                writes. A test that names its own modules passes the built instance in the \
                same list.
                """
        }
    }
}

/// Steps 4–8 of the bootstrap sequence: modules composed eagerly in dependency
/// order, health seeding, service collection. Steps 1–3 (environment, YAML,
/// Configuration assembly) belong to Flight Config; this function receives
/// their output. Config must be fully resolved before modules configure —
/// that ordering is enforced here by the signature itself.
///
/// Internal: `Flight.assemble` is the public spelling. This was public with
/// no caller anywhere outside FlightCore, duplicating that surface under a
/// name nothing was meant to type.
/// Assembly from modules the composition root already built, in dependency
/// order. No container: a module holds what it provides and is constructed by
/// the composer, so assembly only seeds health, collects services, and orders
/// them by shutdown phase. Configuration is fully resolved before this runs —
/// enforced by the signature.
func _flightAssemble(
    configuration: Configuration,
    moduleInstances instances: [any FlightModule],
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
        // part of the assembly; a service-owning one stays running unless its
        // Service later throws (see HealthTrackingService).
        health.set(name, .running)
        if let service = module.service {
            services.append((name, service, module.serviceCompletion, module.serviceShutdownPhase))
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
/// ServiceLifecycle's problem from here — not Flight's to reinvent.
///
/// Returns only when the ServiceGroup finishes (shutdown or failure). Apps
/// with no long-running services return immediately after assembly — a valid
/// shape for one-shot CLI-style Flight apps.
/// Bootstrap from modules a caller already built, in dependency order — what
/// a generated composer supplies.
func _flightBootstrap(
    configuration: Configuration,
    moduleInstances instances: [any FlightModule],
    health: ModuleHealthRegistry = ModuleHealthRegistry(),
    logger: Logger = Logger(label: "flight.bootstrap")
) async throws {
    try await _flightBootstrap(
        configuration: configuration,
        assembled: _flightAssemble(
            configuration: configuration, moduleInstances: instances, health: health),
        logger: logger)
}

private func _flightBootstrap(
    configuration: Configuration,
    assembled app: AssembledApplication,
    logger: Logger
) async throws {
    logger.info(
        "flight assembled",
        metadata: [
            "modules": .array(app.moduleOrder.map { .string($0) }),
            "services": .stringConvertible(app.services.count),
        ])

    guard !app.services.isEmpty else {
        logger.info("no long-running services; bootstrap complete")
        return
    }

    let group = ServiceGroup(  // step 9
        configuration: .init(
            services: app.services.map { entry in
                ServiceGroupConfiguration.ServiceConfiguration(
                    service: entry.service,
                    // .failsApp → .cancelGroup: a server returning early is a
                    // failure. .endsApp → graceful shutdown: bounded work done.
                    successTerminationBehavior: entry.completion == .endsApp
                        ? .gracefullyShutdownGroup
                        : .cancelGroup
                )
            },
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        )
    )
    try await group.run()
}

/// Maps a Service's termination onto ModuleHealth with zero
/// instrumentation required from module authors — bootstrap observes it from
/// the outside, which is the whole point of tracking health externally.
struct HealthTrackingService: Service {
    let moduleName: String
    let inner: any Service
    let health: ModuleHealthRegistry

    func run() async throws {
        do {
            try await inner.run()
        } catch {
            health.set(moduleName, .failed(error))
            throw error
        }
    }
}
