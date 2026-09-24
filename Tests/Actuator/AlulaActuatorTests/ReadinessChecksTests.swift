import AlulaCore
import Logging
import Synchronization
import Testing

@testable import AlulaActuator

@Suite("Readiness check reuse")
struct ReadinessChecksTests {
    final class Calls: Sendable {
        let count = Mutex(0)
        func increment() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    @Test("probes inside the window share one run, concurrent or not")
    func reuse() async {
        let calls = Calls()
        let checks = ReadinessChecks(
            checks: [HealthCheck(name: "db") { calls.increment() }],
            reuseWindow: .seconds(3600), logger: Logger(label: "test"))
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<10 { group.addTask { await checks.failedCount() } }
        }
        for _ in 0..<5 { _ = await checks.failedCount() }
        #expect(calls.value == 1)
    }

    @Test("past the window, the check runs again")
    func expiry() async throws {
        let calls = Calls()
        let checks = ReadinessChecks(
            checks: [HealthCheck(name: "db") { calls.increment() }],
            reuseWindow: .milliseconds(1), logger: Logger(label: "test"))
        _ = await checks.failedCount()
        try await Task.sleep(for: .milliseconds(20))
        _ = await checks.failedCount()
        #expect(calls.value == 2)
    }
}
