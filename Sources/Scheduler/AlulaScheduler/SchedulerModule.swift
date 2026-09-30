import AlulaCore
import Foundation
import ServiceLifecycle

/// Provides the scheduler.
///
/// ```swift
/// await Alula.run(
///     configuration: try Configuration.load(),
///     modules: [AlulaSchedulerModule.self, AppModule.self],
///     composedBy: alulaComposeModules
/// )
/// ```
///
/// A struct holding what it provides: the jobs as values, and the
/// ``SchedulerStatus`` a controller or health check injects.
///
/// Provides no coordinator of its own. A deployment that needs `.once` to
/// mean once across several servers adds a ``JobCoordinator`` from a module
/// that has something to coordinate *through* — a database, a cache —
/// exactly as a distributed PubSub deployment adds an adapter.
public struct AlulaSchedulerModule: AlulaModule {

    /// Every scheduled job in the application, as values. The generated
    /// `alulaScheduledJobs(_:)` supplies this target's, closing over the
    /// component the graph already built; a module declaring its own jobs
    /// contributes them the same way.
    public let jobs: [ScheduledJobRegistration]

    /// What makes `.once` mean once across every server rather than once per
    /// server. Nil is the single-node case, which is the default — and the
    /// scheduler says so, loudly, at startup.
    ///
    /// A parameter, not a runtime lookup: whether a deployment has
    /// something to coordinate *through* is a fact about how it was composed.
    private let coordinator: (any JobCoordinator)?

    /// What each job last did and does next, for anything that injects it.
    // The type is written out because the composer only sees stored
    // properties with an explicit annotation. Inferred, this module provided
    // `SchedulerStatus` in fact and not in the scanner's view, so
    // `@Inject var scheduler: SchedulerStatus` — which the scheduler's own
    // docs show — could not be satisfied by any application.
    public let status: SchedulerStatus = SchedulerStatus()

    /// A scheduler with no jobs is a legal application, so `init()` stays
    /// usable — it composes an empty scheduler.
    public init() {
        self.init(jobs: [], coordinator: nil)
    }

    /// The composition root's initializer: every module's `jobs`, gathered,
    /// and the ``JobCoordinator`` some module provides, if any.
    public init(jobs: [ScheduledJobRegistration] = [], coordinator: (any JobCoordinator)? = nil) {
        self.jobs = jobs
        self.coordinator = coordinator
    }

    /// A ``SchedulerService`` over this module's jobs, coordinator and
    /// status. Present even with no jobs: it logs that and waits for shutdown.
    public var service: (any Service)? {
        SchedulerService(jobs: jobs, coordinator: coordinator, status: status)
    }
}
