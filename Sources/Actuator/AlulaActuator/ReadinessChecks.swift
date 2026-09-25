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
/// response carries neither, because dependency names are topology. The
/// dashboard, which exists only at `full` exposure, shows both.
final class ReadinessChecks: Sendable {
    private let checks: [HealthCheck]
    private let reuseWindow: Duration
    private let logger: Logger
    private let clock = ContinuousClock()

    private struct State {
        var inFlight: Task<[CheckResult], Never>?
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

    /// One check's outcome from the latest run.
    struct CheckResult: Sendable {
        let name: String
        let result: HealthCheckResult
    }

    /// How many checks failed, from a run no older than `reuseWindow`.
    func failedCount() async -> Int {
        await results().filter { !$0.result.passed }.count
    }

    /// Every check's outcome, by name, from a run no older than `reuseWindow`
    /// — the same run the probe counts, so the dashboard and the probe
    /// cannot disagree about one moment.
    func results() async -> [CheckResult] {
        guard !checks.isEmpty else { return [] }
        let now = clock.now
        let task = state.withLock { state -> Task<[CheckResult], Never> in
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

    private func runAll() async -> [CheckResult] {
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
        return results.map { CheckResult(name: $0.0, result: $0.1) }.sorted { $0.name < $1.name }
    }
}
