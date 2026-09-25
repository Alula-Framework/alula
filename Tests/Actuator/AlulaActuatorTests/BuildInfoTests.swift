import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Foundation
import Testing

@testable import AlulaActuator

@Suite("/actuator/info")
struct BuildInfoTests {
    @Test("published beside the dashboard, and nowhere the dashboard is not")
    func gating() async throws {
        let dev = try TestClient(routes: ActuatorModule(environment: .dev).routes)
        let response = await dev.get("/actuator/info")
        #expect(response.status == .ok)
        #expect(response.bodyText.contains(#""environment":"dev""#))
        let prod = try TestClient(routes: ActuatorModule(environment: .prod).routes)
        #expect(await prod.get("/actuator/info").status == .notFound)
    }

    @Test("reads app.name, app.version and app.build.* from configuration")
    func configuration() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let info = try ActuatorBuildInfo(
            configuration: Configuration(values: [
                "app.name": "Shop", "app.version": "1.4.2",
                "app.build.commit": "3f9c2a1", "app.build.time": "2026-09-24T21:00:00Z",
            ]),
            startedAt: started)
        let document = info.document(environment: .staging, now: started.addingTimeInterval(90))
        #expect(document.name == "Shop")
        #expect(document.version == "1.4.2")
        #expect(document.commit == "3f9c2a1")
        #expect(document.buildTime == "2026-09-24T21:00:00Z")
        #expect(document.environment == "staging")
        #expect(document.uptimeSeconds == 90)
    }

    @Test("unset values are left out of the JSON")
    func omitsUnset() throws {
        let data = try JSONEncoder().encode(ActuatorBuildInfo().document(environment: .dev))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("version"))
        #expect(text.contains("uptimeSeconds"))
    }
}
