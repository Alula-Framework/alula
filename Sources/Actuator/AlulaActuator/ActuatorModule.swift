import AlulaCore
import AlulaWeb
import Logging
import Synchronization

import class Foundation.ProcessInfo

/// Alula Actuator's one entry point — a `AlulaModule`, nothing more.
/// Registered like everything else:
///
///     await Alula.run(
///         configuration: try Configuration.load(),
///         modules: [AlulaWebModule<AlulaTransport>.self, ActuatorModule.self],
///         composedBy: alulaComposeModules
///     )
///
/// ## Access gating
///
/// What gets registered is decided by ``ActuatorExposure``, resolved at
/// configuration time and never re-checked per request:
///
/// - ``ActuatorExposure/disabled`` — the module produces no routes, so
///   nothing exists in the route table to probe.
/// - ``ActuatorExposure/healthOnly`` — the default anywhere that has not
///   declared itself a development environment, including a deployment that
///   set nothing at all. The health routes are registered and the dashboard
///   is not.
/// - ``ActuatorExposure/full`` — health plus the `/actuator` dashboard,
///   which discloses the module list, every registered component's
///   fully-qualified type name, and failure messages. Open by default, the
///   same as every other route; ``ActuatorDashboardAccess`` puts it behind
///   authentication and roles (`actuator.dashboard-pipelines`,
///   `actuator.dashboard-roles`). The health routes are never gated — an
///   orchestrator's probe has no credential to present.
public struct ActuatorModule: AlulaModule {
    public static var dependencies: [any AlulaModule.Type] { [] }

    /// Holds the controller the routes serve from.
    ///
    /// The routes are values, built when the module is; the controller they
    /// serve from is built a step later in the same init, once the components
    /// and health it reports are in hand. So the routes close over this box
    /// and `installController` fills it — which is what replaced
    /// `context.resolve(ActuatorController.self)` in every handler.
    final class ControllerBox: @unchecked Sendable {
        private let storage = Mutex<ActuatorController?>(nil)
        func set(_ controller: ActuatorController) { storage.withLock { $0 = controller } }
        func get() throws -> ActuatorController {
            guard let controller = storage.withLock({ $0 }) else {
                throw ActuatorNotConfigured()
            }
            return controller
        }
    }

    /// Thrown only if a route somehow serves before the module configured,
    /// which bootstrap's ordering makes unreachable — stated rather than
    /// force-unwrapped.
    struct ActuatorNotConfigured: Error, CustomStringConvertible {
        var description: String {
            "the actuator served a request before its module was configured"
        }
    }

    private let controller = ControllerBox()

    /// Where module health comes from — the shared registry the composition
    /// root threads in. Read at request time, so it reflects state as of the
    /// request, exactly as reading the container did.
    let health: ModuleHealthRegistry

    /// What readiness asks beyond module health — every module's
    /// `[HealthCheck]` contribution, collected by the composition root.
    /// Private so the composer does not read it back as a contribution.
    private let healthChecks: [HealthCheck]

    let environment: AlulaEnvironment

    /// The shape the composition root uses, and the one to reach for by hand:
    /// the environment the configuration states (`ALULA_ENV`, or one named in
    /// code), every `actuator.*` setting — `actuator.format`,
    /// `actuator.dashboard-pipelines`, `actuator.dashboard-roles`, the build
    /// info — scanned components from the generated
    /// `alulaComponentDescriptors()`, and health from the shared registry.
    /// Throws on a malformed `actuator.*` value.
    ///
    /// Outside a composition, `try ActuatorModule(configuration: configuration)`
    /// is the whole call.
    public init(
        configuration: Configuration,
        components: [ComponentDescriptor] = [],
        health: ModuleHealthRegistry = ModuleHealthRegistry(),
        healthChecks: [HealthCheck] = [],
        logger: Logger = Logger(label: "alula.actuator")
    ) throws {
        try self.init(
            configuration: configuration,
            processEnvironment: ProcessInfo.processInfo.environment,
            components: components, health: health, healthChecks: healthChecks, logger: logger)
    }

    /// The composition path with the process environment injected — how a
    /// test asks "what would an unset `ALULA_ENV` do" without mutating the
    /// real one.
    init(
        configuration: Configuration,
        processEnvironment: [String: String],
        components: [ComponentDescriptor] = [],
        health: ModuleHealthRegistry = ModuleHealthRegistry(),
        healthChecks: [HealthCheck] = [],
        logger: Logger = Logger(label: "alula.actuator")
    ) throws {
        // The shared rule (`Configuration.isExplicitlyDevelopment`), which
        // OpenAPI uses too: an unset ALULA_ENV resolves to `dev` for the
        // overlay, but it is not a declaration, and the dashboard needs one.
        let declared = configuration.declaredEnvironment(processEnvironment: processEnvironment)
        let dashboardAccess = try ActuatorDashboardAccess(configuration: configuration)
        let format = try configuration.getIfPresent("actuator.format", as: ActuatorFormat.self) ?? .ssr
        let buildInfo = try ActuatorBuildInfo(configuration: configuration)
        self.init(
            environment: declared ?? configuration.environment ?? .dev,
            isEnvironmentDeclared: declared != nil,
            exposure: nil,
            processEnvironment: processEnvironment,
            components: components, health: health, healthChecks: healthChecks,
            format: format, buildInfo: buildInfo, dashboardAccess: dashboardAccess,
            logger: logger)
    }

    /// Everything stated in code, nothing read from configuration — for tests,
    /// and for embedders that resolve these some other way.
    ///
    /// Naming the environment is a declaration, the same as setting
    /// `ALULA_ENV`. With `exposure` nil it is resolved from `environment` and
    /// `ALULA_ACTUATOR_EXPOSURE`, as the configuration path resolves it; given,
    /// it bypasses both. `format` and `dashboardAccess` are what
    /// `actuator.format` and `actuator.dashboard-*` would have said.
    public init(
        environment: AlulaEnvironment,
        exposure: ActuatorExposure? = nil,
        components: [ComponentDescriptor] = [],
        health: ModuleHealthRegistry = ModuleHealthRegistry(),
        healthChecks: [HealthCheck] = [],
        format: ActuatorFormat = .ssr,
        dashboardAccess: ActuatorDashboardAccess = .open,
        logger: Logger = Logger(label: "alula.actuator")
    ) {
        self.init(
            environment: environment, isEnvironmentDeclared: true, exposure: exposure,
            processEnvironment: exposure == nil ? ProcessInfo.processInfo.environment : [:],
            components: components, health: health, healthChecks: healthChecks,
            format: format, buildInfo: ActuatorBuildInfo(),
            dashboardAccess: dashboardAccess, logger: logger)
    }

    /// Both public initializers end here.
    private init(
        environment: AlulaEnvironment,
        isEnvironmentDeclared: Bool,
        exposure: ActuatorExposure?,
        processEnvironment: [String: String],
        components: [ComponentDescriptor],
        health: ModuleHealthRegistry,
        healthChecks: [HealthCheck],
        format: ActuatorFormat,
        buildInfo: ActuatorBuildInfo,
        dashboardAccess: ActuatorDashboardAccess,
        logger: Logger
    ) {
        self.logger = logger
        self.components = components
        self.health = health
        self.healthChecks = healthChecks
        self.dashboardAccess = dashboardAccess
        self.environment = environment
        let resolved = Result<ActuatorExposure, any Error> {
            try exposure
                ?? ActuatorExposure.resolve(
                    environment: environment, isEnvironmentDeclared: isEnvironmentDeclared,
                    processEnvironment: processEnvironment)
        }
        self.resolvedExposure = resolved
        self.routes = Self.makeRoutes(
            exposure: try? resolved.get(),
            controller: controller, dashboardAccess: dashboardAccess)
        installController(format: format, buildInfo: buildInfo)
        announceExposure()
    }

    private let dashboardAccess: ActuatorDashboardAccess
    private let logger: Logger

    /// Says, once, which exposure this process resolved to.
    ///
    /// The decision is security-relevant and was previously silent: nothing
    /// anywhere recorded that a deployment had begun publishing an
    /// unauthenticated description of its topology. Presence announces its
    /// failure-detection mode at startup for the same reason — so nobody
    /// discovers the distinction from a bug report.
    ///
    /// Called once, from the initializer every other one delegates to.
    private func announceExposure() {
        guard let exposure = try? resolvedExposure.get() else {
            // A malformed ALULA_ACTUATOR_EXPOSURE. Composition surfaces it
            // and nothing serves, so this is a breadcrumb rather than the
            // report.
            logger.error(
                "actuator exposure could not be resolved; composition will fail",
                metadata: ["environment": "\(environment.rawValue)"])
            return
        }
        let metadata: Logger.Metadata = [
            "exposure": "\(exposure.rawValue)",
            "environment": "\(environment.rawValue)",
        ]
        switch exposure {
        case .disabled:
            logger.info("actuator disabled; no routes published", metadata: metadata)
        case .healthOnly:
            logger.info(
                "actuator publishing health probes only; no topology is disclosed",
                metadata: metadata)
        case .full:
            if environment.isDevelopment {
                logger.info(
                    "actuator dashboard published; environment is a development one",
                    metadata: metadata)
            } else if dashboardAccess.requiresIdentity {
                var gated = metadata
                gated["dashboard-pipelines"] =
                    "\(dashboardAccess.pipelines.map(\.name).joined(separator: ","))"
                gated["dashboard-roles"] = "\(dashboardAccess.roles.joined(separator: ","))"
                logger.info(
                    "actuator dashboard published outside a development environment, behind authentication",
                    metadata: gated)
            } else {
                // The line this whole method exists for: `full` outside the
                // allowlist can only come from an explicit
                // ALULA_ACTUATOR_EXPOSURE, and nothing configured puts the
                // dashboard behind a credential.
                logger.warning(
                    """
                    actuator dashboard published OUTSIDE a development environment — it is \
                    unauthenticated and discloses the module list, every component's type \
                    name, and failure messages. Set actuator.dashboard-pipelines: authenticated \
                    (and actuator.dashboard-roles), or unset ALULA_ACTUATOR_EXPOSURE to fall back \
                    to health probes only.
                    """,
                    metadata: metadata)
            }
        }
    }

    /// Resolved once, when the module is built, so `routes` can be a stored
    /// value — and kept as a `Result` so the non-throwing initializers can
    /// hold it. A malformed `ALULA_ACTUATOR_EXPOSURE` still fails bootstrap:
    /// composition surfaces it, and nothing serves before every module is
    /// built.
    private let resolvedExposure: Result<ActuatorExposure, any Error>

    /// The actuator's endpoints, as values.
    ///
    /// §2.9a's case: whether these exist at all is decided by `ALULA_ENV` at
    /// bootstrap, so no build-time scan can answer it — which is why they
    /// once needed a marker comment when they were imperative
    /// `registerRoute` calls. As values the gate is an ordinary `if`, and the
    /// composition root collects them like any other contribution.
    ///
    /// Each handler reads the controller from the box the routes close over: a
    /// lock-free singleton lookup, not reconstruction.
    public let routes: [RouteRegistration]

    /// Every component the build scanned, handed over by the composition
    /// root. Empty is legal — an application with no components has nothing
    /// for the dashboard to list.
    public let components: [ComponentDescriptor]

    /// Actuator's own controller, which no application's build scans because
    /// this module registers it. A module knows what it provides, so it says
    /// so rather than relying on the dashboard to notice a registration.
    static let ownComponents: [ComponentDescriptor] = [
        ComponentDescriptor(
            typeName: "AlulaActuator.ActuatorController",
            sourceModule: "ActuatorModule", stereotype: .controller)
    ]

    /// Stored rather than computed, because the composition root reads what a
    /// module *holds*: a computed property is excluded from that scan, which
    /// is what keeps `var service` from being taken as a contribution.
    private static func makeRoutes(
        exposure: ActuatorExposure?, controller: ControllerBox,
        dashboardAccess: ActuatorDashboardAccess
    ) -> [RouteRegistration] {
        guard let exposure, exposure.publishesHealth else { return [] }
        // Health is published wherever the actuator is enabled at all: an
        // orchestrator needs a probe in production, and the old
        // all-or-nothing gate is why production had none.
        var routes: [RouteRegistration] = [
            RouteRegistration(method: "GET", path: "/actuator/health", source: "AlulaActuator") {
                context in try await controller.get().health(context)
            },
            // Liveness and readiness are different questions, and one endpoint
            // answering both got one of them wrong whichever way it was wired:
            // a module that has not started yet must not count against
            // liveness (a slow pod restarts into the same slow start, forever)
            // and must count against readiness.
            RouteRegistration(
                method: "GET", path: "/actuator/health/live", source: "AlulaActuator"
            ) { context in
                try await controller.get().liveness(context)
            },
            RouteRegistration(
                method: "GET", path: "/actuator/health/ready", source: "AlulaActuator"
            ) { context in
                try await controller.get().readiness(context)
            },
        ]
        // The dashboard discloses the module list, every registered
        // component's fully-qualified type name, and failure messages. It is
        // published only where the exposure says so — an unrecognized
        // environment does not get it.
        if exposure.publishesDashboard {
            let roles = dashboardAccess.roles.map(ConfiguredRole.init(roleName:))
            routes.append(
                RouteRegistration(
                    method: "GET", path: "/actuator", source: "AlulaActuator",
                    pipelines: dashboardAccess.pipelines
                ) { context in
                    // The same check a `roles:` route runs: 401 for no
                    // credential, 403 for the wrong one.
                    try requireRoles(roles, in: context)
                    return try await controller.get().dashboard(context)
                })
            // Which build is running. Beside the dashboard and behind the same
            // roles: a precise version tells an attacker which advisories apply.
            routes.append(
                RouteRegistration(
                    method: "GET", path: "/actuator/info", source: "AlulaActuator",
                    pipelines: dashboardAccess.pipelines
                ) { context in
                    try requireRoles(roles, in: context)
                    return try await controller.get().info(context)
                })
        }
        return routes
    }

    /// Builds the controller into the box the routes serve from, when the
    /// exposure publishes anything. Called from `init` — there is no container
    /// and no `configure`; the module holds what it needs.
    ///
    /// `format` is read once here (the "read at bootstrap" semantics the
    /// freeze()-time factory used to give it). A malformed `actuator.format`
    /// throws, failing composition.
    private func installController(format: ActuatorFormat, buildInfo: ActuatorBuildInfo) {
        guard let exposure = try? resolvedExposure.get(), exposure.publishesHealth else { return }
        var controller = ActuatorController(
            components: components + Self.ownComponents,
            health: { [health] in health.statuses() },
            isDraining: { [health] in health.isDraining },
            readinessChecks: ReadinessChecks(checks: healthChecks, logger: logger),
            environment: environment,
            format: format)
        controller.buildInfo = buildInfo
        self.controller.set(controller)
    }
}
