// Every shape Docs/web.md's "Security headers" section and Docs/actuator.md's
// dashboard-access section claim, compiled. A rename that invalidates the
// prose breaks the build.

import FlightActuator
import FlightCore
import FlightWeb
import FlightWebTesting

func securityHeaderShapes(configuration: Configuration) throws {
    // The policy in code, the same as `web.security-headers.*` in YAML.
    let headers = try SecurityHeaders(
        frameOptions: .sameOrigin,
        referrerPolicy: "no-referrer",
        strictTransportSecurity: .init(
            maxAge: .seconds(63_072_000), includeSubdomains: true, preload: true),
        contentSecurityPolicy: "default-src 'self'")
    _ = try FlightWebModule<InMemoryTransport>(
        configuration: configuration, securityHeaders: headers)

    // Read from configuration, as the web module does by default.
    _ = try SecurityHeaders(configuration: configuration)
    _ = SecurityHeadersConfigKey.hstsMaxAge

    // The actuator dashboard behind the `authenticated` lane and a role.
    let access = ActuatorDashboardAccess(pipelines: [.authenticated], roles: ["operator"])
    _ = ActuatorModule(environment: .staging, exposure: .full, dashboardAccess: access)
    _ = try ActuatorDashboardAccess(configuration: configuration)
    _ = ActuatorConfigKey.dashboardRoles
}
