import AlulaActuator
import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Synchronization
import Testing

/// The composed path: an `ActuatorModule` built the way the composition root
/// builds it — explicit environment, components handed over, health from the
/// shared registry — assembled and served through the full dispatch pipeline.
///
/// Serialized because the default `ActuatorModule.init()` reads `ALULA_ENV`
/// from the process environment, which these tests pin to a known value.
@Suite("Full bootstrap integration", .serialized)
struct IntegrationTests {

    init() {
        setenv("ALULA_ENV", "dev", 1)
    }

    @Test("compose → dispatch → dashboard, end to end")
    func endToEnd() async throws {
        // The composition root threads one health registry into the actuator;
        // here we report the assembled modules' health onto it directly.
        let health = ModuleHealthRegistry()
        health.reportHealth(.running, forModule: "ActuatorModule")
        health.reportHealth(.running, forModule: "SampleAppModule")

        let actuator = ActuatorModule(
            environment: .dev, exposure: .full,
            components: SampleAppModule.components, health: health, format: .json)

        let client = try TestClient(routes: actuator.routes)
        let response = await client.get("/actuator")
        #expect(response.status == .ok)
        let wire = try response.decodeJSON(SnapshotWire.self)

        #expect(wire.environment == "dev")
        let moduleNames = wire.modules.map(\.module)
        #expect(moduleNames.contains("ActuatorModule"))
        #expect(moduleNames.contains("SampleAppModule"))
        #expect(wire.modules.allSatisfy { $0.health == "running" })

        // Every component the *build* scanned for the app module. Six ordinary
        // ones plus SampleController — routes are reported as routes, never
        // folded in as components (the distinction §2.9 wanted).
        let sampleComponents = wire.components.filter { $0.sourceModule == "SampleAppModule" }
        #expect(sampleComponents.count == 7)
        // Actuator's own controller is listed like everything else.
        #expect(wire.components.contains { $0.type == "AlulaActuator.ActuatorController" })
    }

    @Test("actuator registers no service — it is request-response only")
    func noLongRunningService() throws {
        let app = try Alula.assemble(
            configuration: Configuration(),
            modules: [ActuatorModule()]
        )
        #expect(app.services.isEmpty)
    }

    @Test("dashboard reports the gate's environment, not a re-read")
    func reportsGateEnvironment() async throws {
        // Module constructed with an explicit environment; the page must
        // report that same value even though ALULA_ENV says "dev".
        let actuator = ActuatorModule(
            environment: .staging, exposure: .full,
            components: SampleAppModule.components)
        let client = try TestClient(routes: actuator.routes)
        let body = await client.get("/actuator").bodyText
        #expect(body.contains("Environment: <strong>staging</strong>"))
    }
}

/// Liveness and readiness are different questions, and one endpoint answering
/// both got one of them wrong whichever way it was wired.
@Suite("Liveness and readiness")
struct ProbeTests {

    @Test("a module still starting is not ready, but is alive")
    func notStartedSplitsTheProbes() async throws {
        // The distinction that matters operationally: `notStarted` counted
        // toward DOWN on the single endpoint, so used as a liveness probe it
        // restart-looped a slow-starting pod into the same slow start,
        // forever.
        let health = ModuleHealthRegistry()
        let actuator = ActuatorModule(environment: .dev, health: health)
        health.reportHealth(.notStarted, forModule: "Slow")
        let client = try TestClient(routes: actuator.routes)

        #expect(await client.get("/actuator/health/live").status == .ok)
        #expect(await client.get("/actuator/health/ready").status == .serviceUnavailable)
        #expect(await client.get("/actuator/health").status == .serviceUnavailable)
    }

    @Test("a failed module is neither alive nor ready")
    func failedIsDownForBoth() async throws {
        struct Boom: Error {}
        let health = ModuleHealthRegistry()
        let actuator = ActuatorModule(environment: .dev, health: health)
        health.reportHealth(.failed(Boom()), forModule: "Broken")
        let client = try TestClient(routes: actuator.routes)

        #expect(await client.get("/actuator/health/live").status == .serviceUnavailable)
        #expect(await client.get("/actuator/health/ready").status == .serviceUnavailable)
    }

    @Test("a healthy app is up on every probe")
    func runningIsUpEverywhere() async throws {
        let health = ModuleHealthRegistry()
        let actuator = ActuatorModule(environment: .dev, health: health)
        health.reportHealth(.running, forModule: "Fine")
        let client = try TestClient(routes: actuator.routes)

        for path in ["/actuator/health", "/actuator/health/live", "/actuator/health/ready"] {
            let response = await client.get(path)
            #expect(response.status == .ok, "\(path) answered \(response.status)")
            #expect(response.bodyText.contains("\"status\":\"UP\""))
        }
    }

    @Test("a failing dependency check fails readiness only, and names nothing")
    func failingCheckFailsReadinessOnly() async throws {
        struct DatabaseGone: Error {}
        let health = ModuleHealthRegistry()
        health.reportHealth(.running, forModule: "Fine")
        let actuator = ActuatorModule(
            environment: .dev, health: health,
            healthChecks: [HealthCheck(name: "primary-postgres") { throw DatabaseGone() }])
        let client = try TestClient(routes: actuator.routes)

        // A restart does not bring a database back.
        #expect(await client.get("/actuator/health/live").status == .ok)
        let ready = await client.get("/actuator/health/ready")
        #expect(ready.status == .serviceUnavailable)
        #expect(ready.bodyText.contains("\"checksFailed\":1"))
        // Dependency names are topology; the probe is unauthenticated.
        #expect(!ready.bodyText.contains("primary-postgres"))
    }

    @Test("the dashboard names each readiness check and why it fails")
    func dashboardNamesChecks() async throws {
        // The probe names nothing; the dashboard, only there at full exposure,
        // is where an operator finds out which dependency is down.
        struct DatabaseGone: Error, CustomStringConvertible {
            var description: String { "connection refused" }
        }
        let health = ModuleHealthRegistry()
        health.reportHealth(.running, forModule: "Fine")
        let actuator = ActuatorModule(
            environment: .dev, health: health,
            healthChecks: [
                HealthCheck(name: "primary-postgres") { throw DatabaseGone() },
                HealthCheck(name: "sessions-valkey") {},
            ])
        let client = try TestClient(routes: actuator.routes)

        let dashboard = await client.get("/actuator")
        #expect(dashboard.status == .ok)
        let body = dashboard.bodyText
        #expect(body.contains("primary-postgres") && body.contains("sessions-valkey"))
        #expect(body.contains("DOWN") && body.contains("connection refused"))
        #expect(body.contains("UP"))
    }

    @Test("a check that hangs counts as failed once its timeout passes")
    func hangingCheckTimesOut() async throws {
        let health = ModuleHealthRegistry()
        health.reportHealth(.running, forModule: "Fine")
        let actuator = ActuatorModule(
            environment: .dev, health: health,
            healthChecks: [
                HealthCheck(name: "stuck", timeout: .milliseconds(50)) {
                    try await Task.sleep(for: .seconds(60))
                }
            ])
        let client = try TestClient(routes: actuator.routes)
        let started = ContinuousClock.now
        #expect(await client.get("/actuator/health/ready").status == .serviceUnavailable)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("passing checks leave readiness up, and runs are reused inside the window")
    func passingChecksAreReused() async throws {
        let health = ModuleHealthRegistry()
        health.reportHealth(.running, forModule: "Fine")
        let calls = Counter()
        let actuator = ActuatorModule(
            environment: .dev, health: health,
            healthChecks: [HealthCheck(name: "db") { calls.increment() }])
        let client = try TestClient(routes: actuator.routes)

        for _ in 0..<5 {
            #expect(await client.get("/actuator/health/ready").status == .ok)
        }
        // How many runs that took depends on the machine's speed against the
        // one-second window; `ReadinessChecksTests` pins the reuse itself.
        #expect(calls.value >= 1)
    }

    @Test("draining fails readiness and leaves liveness alone")
    func drainingFailsReadiness() async throws {
        let health = ModuleHealthRegistry()
        health.reportHealth(.running, forModule: "Fine")
        let actuator = ActuatorModule(environment: .dev, health: health)
        let client = try TestClient(routes: actuator.routes)
        #expect(await client.get("/actuator/health/ready").status == .ok)

        health.beginDraining()
        let ready = await client.get("/actuator/health/ready")
        #expect(ready.status == .serviceUnavailable)
        #expect(ready.bodyText.contains("\"draining\":true"))
        #expect(await client.get("/actuator/health/live").status == .ok)
    }
}

final class Counter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
