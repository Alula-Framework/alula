// Doc examples that capture telemetry, compiled. They live here rather than
// in Snippets/ because capture is swift-telemetry's TelemetryTesting, which
// only a test target links. `Docs/sessions.md`, `Docs/testing.md`.

import FlightWeb
import FlightWebTesting
import TelemetryTesting

func sessionEventShapes(client: TestClient) async {
    let failures = await TelemetryTest.capture(SessionEvents.StoreFailed.self) {
        _ = await client.get("/")
    }
    precondition(failures.map(\.metadata.operation) == ["load"])
}
