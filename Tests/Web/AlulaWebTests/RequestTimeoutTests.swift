import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Foundation
import Synchronization
import Testing

final class TimeoutProbe: Sendable {
    let cancelled = Atomic(false)
    let deadline = Mutex<ContinuousClock.Instant?>(nil)
}

let timeoutProbe = TimeoutProbe()

@Controller("/t")
struct TimeoutController {
    @GetRoute("/slow", timeout: .milliseconds(100))
    func slow(_ context: RequestContext) async throws -> String {
        timeoutProbe.deadline.withLock { $0 = Deadline.current }
        do {
            try await Task.sleep(for: .seconds(5))
        } catch {
            timeoutProbe.cancelled.store(true, ordering: .relaxed)
            throw error
        }
        return "late"
    }

    @GetRoute("/stubborn", timeout: .milliseconds(100))
    func stubborn(_ context: RequestContext) async -> String {
        // Ignores cancellation entirely: resumed only by the clock.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.resume() }
        }
        return "finally"
    }

    @GetRoute("/inherits")
    func inherits(_ context: RequestContext) async throws -> String {
        try await Task.sleep(for: .milliseconds(400))
        return "done"
    }

    @GetRoute("/unlimited", timeout: .none)
    func unlimited(_ context: RequestContext) async throws -> String {
        try await Task.sleep(for: .milliseconds(400))
        return "done"
    }

    @GetRoute("/fast", timeout: .seconds(5))
    func fast(_ context: RequestContext) -> String { "quick" }
}

@Suite("Request timeouts", .serialized)
struct RequestTimeoutTests {
    private func client(default limit: Duration? = nil) throws -> TestClient {
        try TestClient(
            routes: TimeoutController.alulaRoutes { _ in TimeoutController() },
            web: WebRuntime(requestTimeout: limit))
    }

    @Test("past its timeout a route answers 503, and the handler is cancelled")
    func timesOut() async throws {
        let started = ContinuousClock.now
        let response = await (try client()).get("/t/slow")
        #expect(response.status == .serviceUnavailable)
        #expect(ContinuousClock.now - started < .seconds(2))
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = timeoutProbe.cancelled.load(ordering: .relaxed)
        #expect(cancelled)
    }

    @Test("the handler sees its deadline")
    func deadlineVisible() async throws {
        let before = ContinuousClock.now
        _ = await (try client()).get("/t/slow")
        let deadline = try #require(timeoutProbe.deadline.withLock { $0 })
        #expect(deadline > before)
        #expect(deadline <= before.advanced(by: .milliseconds(500)))
    }

    @Test("a handler ignoring cancellation does not hold the answer")
    func stubbornHandler() async throws {
        let started = ContinuousClock.now
        let response = await (try client()).get("/t/stubborn")
        #expect(response.status == .serviceUnavailable)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("routes inherit web.request-timeout-seconds; .none opts out")
    func inheritance() async throws {
        let limited = try client(default: .milliseconds(100))
        #expect(await limited.get("/t/inherits").status == .serviceUnavailable)
        #expect(await limited.get("/t/unlimited").bodyText == "done")
        // Without a default, nothing is limited.
        #expect(await (try client()).get("/t/inherits").bodyText == "done")
    }

    @Test("a fast handler is untouched, and nothing waits for the timer")
    func fastPath() async throws {
        let started = ContinuousClock.now
        #expect(await (try client()).get("/t/fast").bodyText == "quick")
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("upgrades never, streaming bodies only when the route names a limit")
    func effectiveRules() {
        let upgrade = RouteRegistration.Kind.upgrade(.webSocket)
        #expect(RequestTimeout.seconds(5).effective(kind: upgrade, bodyMode: .buffered(maxBytes: nil), fallback: nil) == nil)
        #expect(RequestTimeout.default.effective(kind: .http, bodyMode: .streaming(maxBytes: nil), fallback: .seconds(30)) == nil)
        #expect(RequestTimeout.seconds(60).effective(kind: .http, bodyMode: .streaming(maxBytes: nil), fallback: .seconds(30)) == .seconds(60))
        #expect(RequestTimeout.default.effective(kind: .http, bodyMode: .buffered(maxBytes: nil), fallback: .seconds(30)) == .seconds(30))
    }

    @Test("a non-positive web.request-timeout-seconds is refused")
    func configuration() {
        #expect(throws: (any Error).self) {
            try AlulaWebModule<InMemoryTransport>(
                configuration: Configuration(values: ["web.request-timeout-seconds": "0"]))
        }
    }
}
