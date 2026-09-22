import FlightCore
import FlightWeb

/// Who may reach the `/actuator` dashboard, when ``ActuatorExposure/full``
/// publishes it at all.
///
/// The dashboard discloses the module list, every component's type name and
/// failure messages, so running it anywhere but a laptop wants a credential
/// in front of it. That used to be left to the deployment — a proxy rule
/// nobody wrote. It is two settings now:
///
/// ```yaml
/// actuator:
///   dashboard-pipelines: authenticated   # lanes the dashboard runs through
///   dashboard-roles: operator            # any one of these, comma-separated
/// ```
///
/// `dashboard-pipelines` names lanes exactly as a route's `pipelines:` does;
/// `authenticated` is the one `FlightSecurityModule` declares, so a signed-in
/// principal is required before the handler runs. `dashboard-roles` is the
/// same check a `roles:` route runs — 401 with no credential, 403 with the
/// wrong one. Roles need a lane that establishes identity: `authenticated`,
/// `authentication`, or `default` when `FlightSecurityModule` is listed.
/// Without one, every request is anonymous and the dashboard answers 401 to
/// everybody — locked, not open, which is the right direction to fail.
///
/// **Health is never gated.** `/actuator/health`, `/live` and `/ready` stay
/// on the default lane whatever this says: an orchestrator's probe has no
/// credential to present, and a probe that 401s restarts a healthy pod.
public struct ActuatorDashboardAccess: Sendable, Equatable {
    /// The lanes the dashboard runs through, in order.
    public var pipelines: [PipelineLane]
    /// Role names, any one of which admits a caller. Empty admits anyone the
    /// lanes let through.
    public var roles: [String]

    public init(pipelines: [PipelineLane] = [.default], roles: [String] = []) {
        self.pipelines = pipelines
        self.roles = roles
    }

    /// The dashboard on the default lane, no roles — what it always was.
    public static let open = ActuatorDashboardAccess()

    /// Reads `actuator.dashboard-pipelines` and `actuator.dashboard-roles`,
    /// both comma-separated. Absent means ``open``.
    public init(configuration: Configuration) throws {
        func list(_ key: String) throws -> [String]? {
            guard let raw: String = try configuration.getIfPresent(key) else { return nil }
            let entries = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Present but empty would otherwise mean "no lanes at all" or "no
            // roles" — the most permissive reading of a setting someone wrote
            // to restrict access.
            guard !entries.isEmpty else {
                throw ActuatorDashboardAccessError.emptyList(key: key)
            }
            return entries
        }
        self.init(
            pipelines: try list(ActuatorConfigKey.dashboardPipelines)?.map { PipelineLane($0) }
                ?? [.default],
            roles: try list(ActuatorConfigKey.dashboardRoles) ?? [])
    }

    /// Whether a caller has to be someone to see the dashboard: a role is
    /// required, or the `authenticated` lane is in the chain. Decides whether
    /// startup warns about a dashboard published outside development.
    var requiresIdentity: Bool {
        !roles.isEmpty || pipelines.contains(.authenticated)
    }
}

public enum ActuatorConfigKey {
    /// Comma-separated lane names for the `/actuator` dashboard route.
    public static let dashboardPipelines = "actuator.dashboard-pipelines"
    /// Comma-separated role names; any one admits a caller.
    public static let dashboardRoles = "actuator.dashboard-roles"
}

public enum ActuatorDashboardAccessError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyList(key: String)

    public var description: String {
        switch self {
        case .emptyList(let key):
            return "\(key) is set but names nothing. Remove it, or name at least one entry."
        }
    }
}

/// A role name read from configuration. `RouteRole` exists so a typo is a
/// compile error; a configured role cannot have that, so this is the one
/// place a string stands in for the type.
struct ConfiguredRole: RouteRole {
    let roleName: String
}
