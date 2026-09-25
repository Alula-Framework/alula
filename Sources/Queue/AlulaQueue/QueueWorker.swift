import Foundation
import Logging
import ServiceLifecycle
import Synchronization

/// Claims and runs jobs: one loop per queue, each holding at most that queue's
/// concurrency, plus a loop renewing the leases of whatever is running and
/// one pruning finished jobs.
///
/// On graceful shutdown it stops claiming and waits for the jobs it holds to
/// finish — bound that wait with `lifecycle.shutdown-timeout-seconds`. Past
/// it, running handlers are cancelled; their leases lapse and another worker
/// runs them again, which is why handlers must be safe to repeat.
struct QueueWorkerService: Service {
    let store: any QueueStore
    let handlers: [String: QueueHandler]
    let queues: [String]
    let settings: QueueSettings
    let wake: QueueWakeup
    let now: @Sendable () -> Date
    let logger: Logger

    private final class Running: Sendable {
        let jobs = Mutex<[QueuedJobID: Int]>([:])
        let stopping = Atomic(false)
    }

    private final class InFlight: Sendable {
        let count = Atomic(0)
    }

    func run() async throws {
        let running = Running()
        let runner = QueueRunner(store: store, now: now, logger: logger)
        logger.info(
            "queue worker started",
            metadata: ["queues": .array(queues.map { .string($0) })])

        await withGracefulShutdownHandler {
            await withDiscardingTaskGroup { group in
                group.addTask { await renewLeases(running) }
                group.addTask { await prune(running) }
                group.addTask { await sampleDepth() }
                await withDiscardingTaskGroup { loops in
                    for queue in queues {
                        loops.addTask { await claimLoop(queue, running: running, runner: runner) }
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

    private func claimLoop(_ queue: String, running: Running, runner: QueueRunner) async {
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
                            running.jobs.withLock { $0[job.id] = job.attempt }
                            group.addTask {
                                _ = await runner.run(job, handler: handlers[job.kind])
                                running.jobs.withLock { _ = $0.removeValue(forKey: job.id) }
                                inFlight.count.subtract(1, ordering: .relaxed)
                                wake.signal(queue: queue)
                            }
                        }
                        claimedAll = !claimed.isEmpty && claimed.count == free
                    } catch {
                        QueueTelemetry.claimFailed(queue: queue)
                        logger.error(
                            "could not claim jobs", metadata: ["queue": "\(queue)", "error": "\(error)"])
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
        while !Task.isCancelled {
            let held = running.jobs.withLock { $0.map { (id: $0.key, attempt: $0.value) } }
            if !held.isEmpty {
                do {
                    try await store.extendLeases(
                        held, until: now().addingTimeInterval(settings.lease.queueSeconds))
                } catch {
                    QueueTelemetry.leaseRenewalFailed()
                    logger.error("could not renew job leases", metadata: ["error": "\(error)"])
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
                logger.warning("could not prune finished jobs", metadata: ["error": "\(error)"])
            }
            try? await Task.sleep(for: .seconds(600))
        }
    }
}
