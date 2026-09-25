import AlulaCore

/// Everything the dashboard serves, assembled per request: data Core
/// already tracks as a natural consequence of bootstrap — no new
/// instrumentation, no caching or polling layer. Both underlying calls are
/// cheap reads against fixed (or externally-tracked, for module health)
/// state.
public struct ActuatorSnapshot: Sendable {
    public let environment: AlulaEnvironment
    public let modules: [ModuleStatus]
    public let components: [ComponentDescriptor]
    /// The readiness checks by name, as the latest run found them. Which
    /// dependency is down is the first question an operator asks when
    /// readiness fails, and the probe deliberately cannot answer it.
    public let checks: [CheckStatus]

    /// One readiness check's outcome.
    public struct CheckStatus: Sendable, Equatable {
        public let name: String
        public let result: HealthCheckResult

        public init(name: String, result: HealthCheckResult) {
            self.name = name
            self.result = result
        }
    }

    public init(
        environment: AlulaEnvironment,
        modules: [ModuleStatus],
        components: [ComponentDescriptor],
        checks: [CheckStatus] = []
    ) {
        self.environment = environment
        self.modules = modules
        self.components = components
        self.checks = checks
    }

    /// The per-request assembly the controller performs, as a public
    /// convenience for anyone building their own surface over the same data.
    /// Health comes from the shared registry, components from what the build
    /// scanned — the two sources the container used to conflate.
    public init(
        health: ModuleHealthRegistry,
        components: [ComponentDescriptor],
        environment: AlulaEnvironment
    ) {
        self.init(
            environment: environment,
            modules: health.statuses(),
            components: components
        )
    }
}

// MARK: - JSON rendering

/// Hand-written encoding rather than retroactive `Codable` conformances on
/// Core's types: the JSON shape is Actuator's public contract for external
/// front-ends, so it is pinned here — Core remains free to evolve its
/// introspection structs without silently changing this wire format.
///
/// Shape:
/// ```json
/// {
///   "environment": "dev",
///   "modules": [{"module": "WebModule", "health": "running", "error": null}],
///   "components": [{"type": "App.UserService", "stereotype": "service",
///              "sourceModule": "AppModule"}],
///   "checks": [{"name": "datasource.primary", "status": "DOWN",
///               "reason": "connection refused"}]
/// }
/// ```
extension ActuatorSnapshot: Encodable {
    private enum CodingKeys: String, CodingKey {
        case environment, modules, components, checks
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(environment.rawValue, forKey: .environment)
        try container.encode(modules.map(ModuleStatusRepresentation.init), forKey: .modules)
        try container.encode(components.map(ComponentRepresentation.init), forKey: .components)
        try container.encode(checks.map(CheckRepresentation.init), forKey: .checks)
    }
}

/// One readiness check on the wire: `status` is `UP` or `DOWN`, the probe's
/// own words; `reason` is present only when it is `DOWN`.
struct CheckRepresentation: Encodable {
    let name: String
    let status: String
    let reason: String?

    init(_ check: ActuatorSnapshot.CheckStatus) {
        self.name = check.name
        switch check.result {
        case .passed:
            self.status = "UP"
            self.reason = nil
        case .failed(let reason):
            self.status = "DOWN"
            self.reason = reason
        }
    }
}

/// One module row on the wire. `error` is present (non-null) only when
/// `health` is "failed".
struct ModuleStatusRepresentation: Encodable {
    let module: String
    let health: String
    let error: String?

    init(_ status: ModuleStatus) {
        self.module = status.moduleName
        self.health = status.health.actuatorLabel
        self.error = status.health.failureDescription
    }
}

/// One component row on the wire — `ComponentDescriptor`, field for field, with
/// enums rendered as their stable labels.
struct ComponentRepresentation: Encodable {
    let type: String
    let stereotype: String
    let sourceModule: String

    init(_ descriptor: ComponentDescriptor) {
        self.type = descriptor.typeName
        self.stereotype = descriptor.stereotype.actuatorLabel
        self.sourceModule = descriptor.sourceModule
    }
}
