import AlulaCore
import Foundation
import Logging
import Synchronization

/// Runs the contributed ``HealthCheck``s for the readiness probe.
///
/// The probe is unauthenticated and polled, so a run is reused for
/// `reuseWindow`: a burst of probes — or someone hammering the route — costs
/// one database round trip per window, not one per request. Concurrent callers
/// inside a window share the run already in flight.
///
/// A check changing state is logged with its name and reason; the probe
/// response carries neither, because dependency names are topology.
final class ReadinessChecks: Sendable {
    private let checks: [HealthCheck]
    private let reuseWindow: Duration
    private let logger: Logger
    private let clock = ContinuousClock()

    private struct State {
        var inFlight: Task<Int, Never>?
        var startedAt: ContinuousClock.Instant?
        var lastPassed: [String: Bool] = [:]
    }
    private let state = Mutex(State())

    init(checks: [HealthCheck], reuseWindow: Duration = .seconds(1), logger: Logger) {
        self.checks = checks
        self.reuseWindow = reuseWindow
        self.logger = logger
    }

    var isEmpty: Bool { checks.isEmpty }

    /// How many checks failed, from a run no older than `reuseWindow`.
    func failedCount() async -> Int {
        guard !checks.isEmpty else { return 0 }
        let now = clock.now
        let task = state.withLock { state -> Task<Int, Never> in
            if let inFlight = state.inFlight, let startedAt = state.startedAt,
                startedAt.duration(to: now) < reuseWindow
            {
                return inFlight
            }
            let task = Task { await self.runAll() }
            state.inFlight = task
            state.startedAt = now
            return task
        }
        return await task.value
    }

    private func runAll() async -> Int {
        let results = await withTaskGroup(of: (String, HealthCheckResult).self) { group in
            for check in checks {
                group.addTask { (check.name, await check.run()) }
            }
            var results: [(String, HealthCheckResult)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (name, result) in results {
            let changed = state.withLock { state in
                defer { state.lastPassed[name] = result.passed }
                return state.lastPassed[name] != result.passed
            }
            guard changed else { continue }
            switch result {
            case .passed:
                logger.info("health check passing", metadata: ["check": "\(name)"])
            case .failed(let reason):
                logger.warning(
                    "health check failing", metadata: ["check": "\(name)", "reason": "\(reason)"])
            }
        }
        return results.filter { !$0.1.passed }.count
    }
}
