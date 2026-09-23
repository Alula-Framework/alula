import AlulaWeb
import AlulaWebTesting
import TelemetryCore
import TelemetryTesting
import Testing

@Suite("HTTP request event")
struct HTTPEventTests {
    @Test(
        "one event per request: the route's pattern — never the path — its method, status and duration"
    )
    func requestEvent() async throws {
        let client = try TestClient(routes: [
            RouteRegistration(method: .get, path: "/users/:id", source: "t") { _ in .text("ok") },
            RouteRegistration(method: .post, path: "/fail", source: "t") { _ in
                throw HTTPError(.badRequest)
            },
        ])
        let events = try await TelemetryTest.capture(HTTPEvents.RequestHandled.self) {
            #expect(await client.get("/users/42").status == .ok)
            #expect(await client.get("/users/43").status == .ok)
            #expect(await client.post("/fail").status == .badRequest)
            #expect(await client.get("/wp-admin/setup.php").status == .notFound)
        }
        #expect(events.map(\.metadata.route) == ["/users/:id", "/users/:id", "/fail", "unmatched"])
        #expect(events.map(\.metadata.method) == ["GET", "GET", "POST", "GET"])
        #expect(events.map(\.metadata.status) == [200, 200, 400, 404])
        #expect(events.allSatisfy { $0.measurements.duration > .zero })
    }

    @Test("the default metrics are named as documented")
    func metricNames() {
        #expect(
            HTTPMetrics.definitions.map {
                $0.descriptor.name.replacingOccurrences(of: ".", with: "_")
            } == [
                HTTPMetrics.requests, HTTPMetrics.duration,
            ])
    }
}
