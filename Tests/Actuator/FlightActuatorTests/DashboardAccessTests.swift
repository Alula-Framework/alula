import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

@testable import FlightActuator

/// Stands in for `FlightSecurityModule`'s `authenticated` lane without
/// depending on it: `X-Test-User: name[:role,role]` becomes the principal,
/// its absence stays anonymous — which `requireRoles` answers 401.
private struct HeaderIdentity: Middleware {
    struct User: RequestPrincipal {
        let subject: String
        let roles: Set<String>
        func hasRole(_ role: String) -> Bool { roles.contains(role) }
    }

    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        guard let raw = context.request.headers[HTTPField.Name("x-test-user")!] else {
            return try await next(context)
        }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let roles = parts.count > 1 ? Set(parts[1].split(separator: ",").map(String.init)) : []
        var authenticated = context
        authenticated.identity = .authenticated(User(subject: parts[0], roles: roles))
        return try await next(authenticated)
    }
}

@Suite("Dashboard access")
struct DashboardAccessTests {

    private func client(_ access: ActuatorDashboardAccess) throws -> TestClient {
        let actuator = ActuatorModule(
            environment: .staging, exposure: .full, dashboardAccess: access)
        return try TestClient(
            routes: actuator.routes,
            middleware: MiddlewareRegistration.lane(.authenticated, [HeaderIdentity()]))
    }

    private func user(_ value: String) -> HTTPFields {
        [HTTPField.Name("x-test-user")!: value]
    }

    @Test("open by default: the dashboard answers anyone, as it always did")
    func openByDefault() async throws {
        #expect(await try client(.open).get("/actuator").status == .ok)
    }

    @Test("with roles, no credential is 401, the wrong role 403, the right one 200")
    func rolesAreEnforced() async throws {
        let client = try client(
            ActuatorDashboardAccess(pipelines: [.authenticated], roles: ["operator"]))
        #expect(await client.get("/actuator").status == .unauthorized)
        #expect(await client.get("/actuator", headers: user("ada:author")).status == .forbidden)
        #expect(await client.get("/actuator", headers: user("ada:operator")).status == .ok)
    }

    @Test("health is never gated, whatever the dashboard requires")
    func healthStaysOpen() async throws {
        let client = try client(
            ActuatorDashboardAccess(pipelines: [.authenticated], roles: ["operator"]))
        #expect(await client.get("/actuator/health").status == .ok)
        #expect(await client.get("/actuator/health/live").status == .ok)
    }

    @Test("configuration is read, comma-separated, whitespace-tolerant")
    func readsConfiguration() throws {
        let access = try ActuatorDashboardAccess(
            configuration: Configuration(values: [
                ActuatorConfigKey.dashboardPipelines: "authenticated",
                ActuatorConfigKey.dashboardRoles: "operator, sre",
            ]))
        #expect(access.pipelines == [.authenticated])
        #expect(access.roles == ["operator", "sre"])
        #expect(try ActuatorDashboardAccess(configuration: Configuration()) == .open)
    }

    @Test("a setting present but naming nothing is refused, not read as unrestricted")
    func emptyListRefused() {
        #expect(
            throws: ActuatorDashboardAccessError.emptyList(key: ActuatorConfigKey.dashboardRoles)
        ) {
            try ActuatorDashboardAccess(
                configuration: Configuration(values: [ActuatorConfigKey.dashboardRoles: " , "]))
        }
    }

    @Test("the composer's initializer reads the access from configuration")
    func composerInitReadsIt() async throws {
        setenv("FLIGHT_ENV", "dev", 1)
        let actuator = try ActuatorModule(
            configuration: Configuration(values: [
                ActuatorConfigKey.dashboardPipelines: "authenticated",
                ActuatorConfigKey.dashboardRoles: "operator",
            ]))
        let client = try TestClient(
            routes: actuator.routes,
            middleware: MiddlewareRegistration.lane(.authenticated, [HeaderIdentity()]))
        #expect(await client.get("/actuator").status == .unauthorized)
    }
}
