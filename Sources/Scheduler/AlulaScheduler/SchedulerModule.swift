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
/// A struct holding what it provides: the jobs as values, and the status the
/// actuator reads.
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

    /// Reported by Actuator; owned here.
    // The type is written out because the composer only sees stored
    // properties with an explicit annotation. Inferred, this module provided
    // `SchedulerStatus` in fact and not in the scanner's view, so
    // `@Inject var scheduler: SchedulerStatus` — which Actuator's own docs
    // show — could not be satisfied by any application.
    public let status: SchedulerStatus = SchedulerStatus()

    /// A scheduler with no jobs is a legal application, so `init()` stays
    /// usable — it composes an empty scheduler.
    public init() {
        self.init(jobs: [], coordinator: nil)
    }

    public init(jobs: [ScheduledJobRegistration] = [], coordinator: (any JobCoordinator)? = nil) {
        self.jobs = jobs
        self.coordinator = coordinator
    }

    /// Built from what this module holds. It used to be built from a stashed
    /// `Container` and collect its jobs at `run()`, because the jobs were
    /// registrations gathered post-`freeze()`.
    public var service: (any Service)? {
        SchedulerService(jobs: jobs, coordinator: coordinator, status: status)
    }
}
