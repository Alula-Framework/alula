import AlulaCore
import Foundation
import Logging
import ServiceLifecycle
import Synchronization

/// Claims and runs jobs: one loop per queue, each holding at most that queue's
/// concurrency, plus a loop renewing the leases of whatever is running and
/// one pruning finished jobs.
///
/// On graceful shutdown it stops claiming and waits for the jobs it holds to
/// finish — bound that wait with `lifecycle.shutdown-timeout-seconds`. Shortly
/// before that deadline it hands back whatever is still running: each handler
/// is cancelled and its job returned to the queue at once, while the store is
/// still reachable. Past the deadline itself ServiceLifecycle cancels the
/// store's pool as well, and a job could not even be put back — it waited out
/// its lease instead (Relay #36). Either way it runs again, which is why
/// handlers must be safe to repeat.
struct QueueWorkerService: Service {
    let store: any QueueStore
    let handlers: [String: QueueHandler]
    let queues: [String]
    let settings: QueueSettings
    let wake: QueueWakeup
    let now: @Sendable () -> Date
    let logger: Logger

    private final class Running: Sendable {
        let jobs = Mutex<[QueuedJobID: (attempt: Int, kind: String)]>([:])
        let stopping = Atomic(false)
        let cutoff = QueueShutdownCutoff()
    }

    private final class InFlight: Sendable {
        let count = Atomic(0)
    }

    func run() async throws {
        let running = Running()
        let runner = {
            var runner = QueueRunner(store: store, now: now, logger: logger)
            runner.cutoff = running.cutoff
            return runner
        }()
        let claimFailures = RepeatedFailureLog(
            what: "could not claim jobs", still: "still cannot claim jobs",
            recovered: "claiming jobs again", logger: logger)
        logger.info(
            "queue worker started",
            metadata: ["queues": .array(queues.map { .string($0) })])

        await withGracefulShutdownHandler {
            await withDiscardingTaskGroup { group in
                group.addTask { await renewLeases(running) }
                group.addTask { await prune(running) }
                group.addTask { await sampleDepth() }
                group.addTask { await handBackBeforeDeadline(running) }
                await withDiscardingTaskGroup { loops in
                    for queue in queues {
                        loops.addTask {
                            await claimLoop(
                                queue, running: running, runner: runner, failures: claimFailures)
                        }
                    }
                }
                // Every queue loop has drained, so nothing holds a lease:
                // stop the housekeeping loops now rather than at their next tick.
                group.cancelAll()
            }
        } onGracefulShutdown: {
            running.stopping.store(true, ordering: .relaxed)
            for queue in queues { wake.signal(queue: queue) }
        }
        logger.info("queue worker stopped")
    }

    private func claimLoop(
        _ queue: String, running: Running, runner: QueueRunner, failures: RepeatedFailureLog
    ) async {
        let limit = settings.concurrency(of: queue)
        let kinds = Set(handlers.values.filter { $0.queue == queue }.map(\.kind))
        let inFlight = InFlight()

        await withDiscardingTaskGroup { group in
            while !running.stopping.load(ordering: .relaxed), !Task.isCancelled {
                let free = limit - inFlight.count.load(ordering: .relaxed)
                var claimedAll = false
                if free > 0 {
                    do {
                        let start = now()
                        let claimed = try await store.claim(
                            queue: queue, kinds: kinds, limit: free, now: start,
                            leaseUntil: start.addingTimeInterval(settings.lease.queueSeconds))
                        for job in claimed {
                            inFlight.count.add(1, ordering: .relaxed)
                            running.jobs.withLock { $0[job.id] = (job.attempt, job.kind) }
                            group.addTask {
                                _ = await runner.run(job, handler: handlers[job.kind])
                                running.jobs.withLock { _ = $0.removeValue(forKey: job.id) }
                                inFlight.count.subtract(1, ordering: .relaxed)
                                wake.signal(queue: queue)
                            }
                        }
                        claimedAll = !claimed.isEmpty && claimed.count == free
                        failures.succeeded()
                    } catch {
                        // Cancelled: the application is stopping, and whatever
                        // stopped it is the report, not this.
                        if Task.isCancelled || error is CancellationError { continue }
                        QueueTelemetry.claimFailed(queue: queue)
                        // Shared by every queue's loop: one outage is one
                        // report, not one per queue per poll.
                        failures.failed(error, metadata: ["queue": "\(queue)"])
                    }
                }
                // A full batch suggests more are due: claim again without
                // waiting, if there is room.
                if claimedAll { continue }
                await wake.wait(queue: queue, timeout: settings.pollInterval)
            }
        }
    }

    private func renewLeases(_ running: Running) async {
        let failures = RepeatedFailureLog(
            what: "could not renew job leases", still: "still cannot renew job leases",
            recovered: "renewing job leases again", logger: logger)
        while !Task.isCancelled {
            let held = running.jobs.withLock { $0.map { (id: $0.key, attempt: $0.value.attempt) } }
            if !held.isEmpty {
                do {
                    try await store.extendLeases(
                        held, until: now().addingTimeInterval(settings.lease.queueSeconds))
                    failures.succeeded()
                } catch {
                    QueueTelemetry.leaseRenewalFailed()
                    failures.failed(error)
                }
            }
            try? await Task.sleep(for: settings.lease / 3)
        }
    }

    /// Reports each queue's depth at the poll interval, when anything is
    /// listening: it costs one store query per queue.
    private func sampleDepth() async {
        while !Task.isCancelled {
            if QueueTelemetry.reportsDepth {
                for queue in queues {
                    if let counts = try? await store.counts(queue: queue) {
                        QueueTelemetry.depth(queue: queue, counts)
                    }
                }
            }
            try? await Task.sleep(for: max(settings.pollInterval, .seconds(5)))
        }
    }

    private func prune(_ running: Running) async {
        while !Task.isCancelled {
            let at = now()
            do {
                let removed = try await store.prune(
                    completedBefore: at.addingTimeInterval(-settings.retainCompleted.queueSeconds),
                    discardedBefore: at.addingTimeInterval(-settings.retainDiscarded.queueSeconds))
                if removed > 0 {
                    logger.debug("pruned finished jobs", metadata: ["count": "\(removed)"])
                }
            } catch {
                // Every ten minutes, so not a flood; but at the moment a start
                // fails or the store is going away, one more line blaming the
                // store says nothing the store's own report does not.
                if !Task.isCancelled {
                    logger.warning("could not prune finished jobs", metadata: ["error": "\(error)"])
                }
            }
            try? await Task.sleep(for: .seconds(600))
        }
    }

    /// Hands back running jobs shortly before the shutdown deadline, while the
    /// store can still take them.
    ///
    /// Waits for shutdown to begin, then until the deadline less a margin —
    /// two seconds, or a fifth of the timeout if that is less — and then, if
    /// jobs are still running, cuts them off. Their handlers are cancelled and
    /// the jobs go back to the queue now, instead of the process being
    /// cancelled around them and the jobs waiting out their leases.
    private func handBackBeforeDeadline(_ running: Running) async {
        do {
            while !running.stopping.load(ordering: .relaxed) {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let shutdown = ShutdownDeadline.current, let timeout = shutdown.timeout else { return }
            // `begin()` is called as shutdown starts, which is before this
            // worker is told; wait for it rather than read a nil deadline.
            var deadline = shutdown.deadline
            while deadline == nil {
                try await Task.sleep(for: .milliseconds(50))
                deadline = shutdown.deadline
            }
            let margin = min(.seconds(2), timeout / 5)
            try await Task.sleep(until: deadline! - margin, clock: .continuous)
        } catch {
            return  // the queues drained first: nothing to hand back
        }
        let held = running.jobs.withLock { Array($0.values) }
        guard !held.isEmpty else { return }
        let kinds = Dictionary(grouping: held, by: \.kind).map { "\($0.key) × \($0.value.count)" }.sorted()
        logger.warning(
            "shutdown deadline is near: handing back running jobs; they run again now, elsewhere or on restart",
            metadata: [
                "jobs": "\(held.count)",
                "kinds": .array(kinds.map { .string($0) }),
                "shutdown-timeout": "\(ShutdownDeadline.current?.timeout ?? .zero)",
            ])
        running.cutoff.fire()
    }
}
