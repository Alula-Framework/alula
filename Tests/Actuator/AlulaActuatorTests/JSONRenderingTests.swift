import AlulaActuator
import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Testing

/// The Decodable mirror of Actuator's public JSON contract — decoded
/// with plain JSONDecoder to pin the wire shape, not just round-trip it.
struct SnapshotWire: Decodable {
    struct Module: Decodable {
        let module: String
        let health: String
        let error: String?
    }
    struct Component: Decodable {
        let type: String
        let stereotype: String
        let sourceModule: String
    }
    let environment: String
    let modules: [Module]
    let components: [Component]
}

@Suite("JSON rendering")
struct JSONRenderingTests {

    /// The actuator's declared routes — a module's routes are values now, so
    /// a client that serves them is given them. The controller is built with
    /// the JSON format, the way the composer's `actuator.format` would.
    private func jsonClient(environment: AlulaEnvironment = .staging) throws -> TestClient {
        let actuator = ActuatorModule(
            environment: environment, exposure: .full,
            components: SampleAppModule.components, format: .json)
        return try TestClient(routes: actuator.routes)
    }

    @Test("dashboard serves application/json when configured")
    func servesJSONContentType() async throws {
        let client = try jsonClient()
        let response = await client.get("/actuator")
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json; charset=utf-8")
    }

    @Test("the wire shape carries environment, modules, and components")
    func wireShape() async throws {
        let client = try jsonClient(environment: .staging)
        let response = await client.get("/actuator")
        let wire = try response.decodeJSON(SnapshotWire.self)

        #expect(wire.environment == "staging")

        let service = try #require(wire.components.first {
            $0.type == "AlulaActuatorTests.SampleService"
        })
        #expect(service.stereotype == "service")
        #expect(service.sourceModule == "SampleAppModule")

        // Two registrations of one type are two entries on the wire — the
        // encoding reports what the build scanned rather than deduplicating
        // it. `scope` and `qualifier` left the contract in 0.20.0.
        let duplicated = wire.components.filter {
            $0.type == "AlulaActuatorTests.SampleDuplicated"
        }
        #expect(duplicated.count == 2)

        // Actuator's own machinery is visible through the same introspection
        // as everything else — no side channel, no special casing.
        #expect(wire.components.contains { $0.type == "AlulaActuator.ActuatorController" })
        // Routes are not asserted here: they are values a module declares, and
        // they reach the container through `AlulaWebModule`, which this
        // container does not include. `GatingTests` covers that path.
    }

    @Test("a failed module encodes health 'failed' with its error")
    func failedModuleOnTheWire() async throws {
        let app = try Alula.assemble(
            configuration: Configuration(),
            modules: [FailingServiceModule()]
        )
        let failing = try #require(app.services.first)
        _ = try? await failing.service.run()

        let snapshot = ActuatorSnapshot(
            health: app.health, components: [], environment: .test)
        let data = try JSONEncoder().encode(snapshot)
        let wire = try JSONDecoder().decode(SnapshotWire.self, from: data)

        let module = try #require(wire.modules.first { $0.module == "FailingServiceModule" })
        #expect(module.health == "failed")
        #expect(module.error?.contains("flux capacitor") == true)
    }

    @Test("a healthy module omits 'error' entirely — it is not null-encoded")
    func healthyModuleOnTheWire() throws {
        let health = ModuleHealthRegistry()
        health.beginTracking(moduleNames: ["FailingServiceModule"])
        health.reportHealth(.running, forModule: "FailingServiceModule")
        let snapshot = ActuatorSnapshot(health: health, components: [], environment: .dev)
        let data = try JSONEncoder().encode(snapshot)
        let wire = try JSONDecoder().decode(SnapshotWire.self, from: data)

        #expect(wire.environment == "dev")
        let module = try #require(wire.modules.first)
        #expect(module.health == "running")
        #expect(module.error == nil)

        // `error == nil` after decoding is true whether the key was absent
        // or explicitly null, so it cannot pin the documented contract:
        // "absent optionals are *omitted*, not null-encoded". A front-end
        // testing `'error' in module` depends on which one it is.
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"error\""), "expected the key to be absent: \(text)")
    }

    @Test("JSON output is deterministic across requests")
    func deterministicOutput() async throws {
        let client = try jsonClient()
        let first = await client.get("/actuator")
        let second = await client.get("/actuator")
        #expect(first.bodyData == second.bodyData)
    }
}
