import AlulaCore
import AlulaSessions
import AlulaSessionsTesting
import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Testing

/// Stands in for `Authentication`: a layer that reads the session.
private struct Reader: SessionReading {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        try await next(context)
    }
}

@Suite("Sessions ordering and idempotence")
struct SessionOrderTests {
    private let store = RecordingSessionStore()

    private var sessions: Sessions {
        Sessions(
            runtime: SessionRuntime(store: store, settings: try! SessionSettings(ttl: .seconds(60)))
        )
    }

    private let route = RouteRegistration(method: .get, path: "/", source: "test") { _ in
        .text("ok")
    }

    @Test("a reader listed ahead of Sessions fails composition, naming the route and both layers")
    func readerBeforeSessions() {
        #expect(throws: DispatchBuilder.SessionOrderError.self) {
            try TestClient(
                routes: [route],
                middleware: MiddlewareRegistration.lane(.default, [Reader(), sessions]))
        }
        do {
            _ = try TestClient(
                routes: [route],
                middleware: MiddlewareRegistration.lane(.default, [Reader(), sessions]))
        } catch let error as DispatchBuilder.SessionOrderError {
            #expect(error.route.hasPrefix("GET /"))
            #expect(error.reader.hasSuffix(".Reader"))
            #expect(error.sessions.hasSuffix(".Sessions"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("a reader after Sessions, or with no Sessions at all, composes")
    func acceptableOrders() throws {
        _ = try TestClient(
            routes: [route],
            middleware: MiddlewareRegistration.lane(.default, [sessions, Reader()]))
        _ = try TestClient(
            routes: [route],
            middleware: MiddlewareRegistration.lane(.default, [Reader()]))
    }

    @Test("the check sees the chain as the route runs it, across concatenated lanes")
    func acrossLanes() {
        // Reader in the default lane, Sessions in a second lane the route
        // adds after it: per-lane inspection would pass this, and the reader
        // would run first.
        let combined = RouteRegistration(
            method: .get, path: "/", source: "test", pipelines: [.default, "with-session"]
        ) { _ in .text("ok") }
        #expect(throws: DispatchBuilder.SessionOrderError.self) {
            try TestClient(
                routes: [combined],
                middleware: MiddlewareRegistration.lane(.default, [Reader()])
                    + MiddlewareRegistration.lane("with-session", [sessions]))
        }
    }

    @Test("Sessions listed twice in one chain loads once")
    func idempotent() async throws {
        let client = try TestClient(
            routes: [route],
            middleware: MiddlewareRegistration.lane(.default, [sessions, sessions]))
        let id = SessionID.generate()
        try store.seed(
            id, record: SessionRecord(createdAt: Date(), expiresAt: Date().addingTimeInterval(60)))
        let response = await client.get("/", headers: [.cookie: "session=\(id.cookieValue)"])
        #expect(response.status == .ok)
        #expect(
            store.operations.filter { if case .load = $0 { return true } else { return false } }
                .count == 1)
    }
}
