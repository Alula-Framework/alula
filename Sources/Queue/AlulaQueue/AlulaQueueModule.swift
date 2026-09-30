import AlulaCore
import Foundation
import Logging
import ServiceLifecycle

/// Provides the ``JobQueue`` an application enqueues through.
///
/// ```swift
/// await Alula.run(
///     configuration: try .load(),
///     modules: [AlulaQueueWorkerModule.self, AppModule.self],   // brings this one
///     composedBy: alulaComposeModules)
/// ```
///
/// The store comes from whichever module provides a ``QueueStore`` —
/// alula-data's `AlulaQueuePostgresModule` for a durable one. With none, jobs
/// live in this process's memory, which is fine for development and tests and
/// is said loudly anywhere else: a deploy loses every waiting job. "Development
/// and tests" means a *declared* environment —
/// `Configuration.isExplicitlyDevelopment()`, so `ALULA_ENV` set to `dev`,
/// `development`, `test` or `local` — because an unset `ALULA_ENV` may be a
/// production box that forgot it, and that one warns.
///
/// Enqueueing and running are separate modules so that neither is a cycle.
/// An application's services take the ``JobQueue`` from here; its handlers,
/// built from those same services, go to ``AlulaQueueWorkerModule``.
public struct AlulaQueueModule: AlulaModule {
    /// The queue the graph provides.
    public let queue: JobQueue

    /// The composition root's initializer. `store` is whichever module's
    /// ``QueueStore``; nil falls back to an ``InMemoryQueueStore``, with a
    /// warning outside a declared development or test environment.
    public init(configuration: Configuration, store: (any QueueStore)? = nil) throws {
        if store == nil {
            // Quiet only in a declared development or test environment: an
            // undeclared one may be production that forgot ALULA_ENV.
            if !configuration.isExplicitlyDevelopment() {
                let environment = configuration.declaredEnvironment()?.rawValue ?? "undeclared"
                Logger(label: "alula.queue").warning(
                    """
                    no durable queue store: jobs are kept in memory and a restart loses every \
                    waiting job. Add AlulaQueuePostgresModule (alula-data) to keep them.
                    """,
                    metadata: ["environment": "\(environment)"])
            }
        }
        self.queue = JobQueue(store: store ?? InMemoryQueueStore())
    }

    /// Unavailable: a hand-written call is a compile error saying how to
    /// build this module, and the composer never counts it as a candidate.
    @available(*, unavailable, message: "AlulaQueueModule takes its configuration in init(configuration:store:), so it cannot be instantiated from its type. Pass `composedBy: alulaComposeModules` to Alula.run — `alula new` writes that argument — or construct the module yourself and use the entry point taking module instances.")
    public init() { fatalError("unavailable") }
}

/// Runs queued jobs, with every ``QueueHandler`` any module contributes.
///
/// Configured by `queue.*` (see ``QueueSettings``). A process that should only
/// enqueue — a web tier, say, with separate worker processes — keeps this
/// module and sets `queue.worker.enabled: false`, or runs a subset of queues
/// with `queue.worker.only`.
///
/// Two handlers for one kind fail composition: which of them runs would
/// otherwise depend on module order.
public struct AlulaQueueWorkerModule: AlulaModule {
    /// ``AlulaQueueModule``, which provides the ``JobQueue`` the worker
    /// claims through.
    public static var dependencies: [any AlulaModule.Type] { [AlulaQueueModule.self] }

    let settings: QueueSettings
    private let worker: QueueWorkerService?

    /// The composition root's initializer. `handlers` is every module's
    /// `queueHandlers`, gathered.
    ///
    /// - Throws: ``QueueCompositionError/duplicateHandler(kind:)`` when two
    ///   handlers share a kind, or ``QueueConfigurationError`` for a bad
    ///   `queue.*` value.
    public init(configuration: Configuration, queue: JobQueue, handlers: [QueueHandler] = [])
        throws
    {
        var byKind: [String: QueueHandler] = [:]
        for handler in handlers {
            guard byKind[handler.kind] == nil else {
                throw QueueCompositionError.duplicateHandler(kind: handler.kind)
            }
            byKind[handler.kind] = handler
        }
        let named = Set(handlers.map(\.queue))
        let settings = try QueueSettings(configuration: configuration, queues: named)
        self.settings = settings

        let queues = named.filter { settings.onlyQueues?.contains($0) ?? true }.sorted()
        let logger = Logger(label: "alula.queue")
        if let only = settings.onlyQueues {
            for unknown in only.subtracting(named).sorted() {
                logger.warning(
                    "queue.worker.only names a queue no handler uses",
                    metadata: ["queue": "\(unknown)"])
            }
        }
        guard settings.workerEnabled, !queues.isEmpty else {
            self.worker = nil
            return
        }
        self.worker = QueueWorkerService(
            store: queue.store, handlers: byKind, queues: queues, settings: settings,
            wake: queue.wake, now: queue.now, logger: logger)
    }

    /// Unavailable: a hand-written call is a compile error saying how to
    /// build this module, and the composer never counts it as a candidate.
    @available(*, unavailable, message: "AlulaQueueWorkerModule takes its configuration, queue and handlers in init(configuration:queue:handlers:), so it cannot be instantiated from its type. Pass `composedBy: alulaComposeModules` to Alula.run.")
    public init() { fatalError("unavailable") }

    /// The worker, or nil when this process runs no queues
    /// (`queue.worker.enabled: false`, no handlers, or `queue.worker.only`
    /// naming none of them).
    public var service: (any Service)? { worker }
}

/// Why the queue modules could not be composed.
public enum QueueCompositionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Two ``QueueHandler``s handle this kind, so which one ran would depend
    /// on module order.
    case duplicateHandler(kind: String)

    /// Names the kind and the rule.
    public var description: String {
        switch self {
        case .duplicateHandler(let kind):
            "two QueueHandlers handle \(kind); a job kind has exactly one handler"
        }
    }
}
