import Logging
import ServiceLifecycle

/// Work a module does once as the application starts, or once as it stops,
/// without writing a `Service` for it.
///
/// ```swift
/// struct CatalogModule: AlulaModule {
///     let lifecycleHooks: [LifecycleHook]
///
///     init(catalog: Catalog) {
///         lifecycleHooks = [
///             .onStartup("warm the catalog cache") { _ in try await catalog.warm() },
///             .onShutdown("flush view counts") { _ in try await catalog.flushCounts() },
///         ]
///     }
/// }
/// ```
///
/// - **Startup hooks run before the module's service, in order.** Until the
///   last one returns, the module reads as not started, so readiness says no
///   and an orchestrator sends no traffic. One that throws stops the
///   application: a start that could not do its work is a failed start, and
///   that module's shutdown hooks then do not run. Only the module's *own*
///   service waits: every module's service is started concurrently, so
///   other modules — the HTTP transport included — may already be serving
///   while a startup hook runs. Work that must finish before any request is
///   served belongs in a before-start hook.
/// - **Shutdown hooks run after the module's service has stopped**, in the
///   same phase order as services: an `.inbound` module's hooks before a
///   `.standard` one's, and `.infrastructure` last, so a hook can still use
///   the database. One that throws is logged and the rest still run. They
///   run whenever the service ends — returning on its own or throwing, not
///   only at application shutdown.
/// - Hooks are bounded by `lifecycle.shutdown-timeout-seconds` like the rest
///   of shutdown. A hook still pending when the timeout cancels its module
///   runs in a cancelled task, so cancellation-aware work in it (a sleep, a
///   query) fails at once; see ``ShutdownDeadline``.
/// - **Before-start hooks run before any service of the application
///   starts**, one at a time in dependency order. They are for proving a
///   dependency is there — a database pool dialling its connections — so that
///   a start that cannot work fails with that reason alone, before a listener
///   announces itself and before workers log their own failures to reach
///   what is missing (Relay #44). One that throws stops the application with
///   its error, unwrapped. Nothing else is running yet, so such a hook can use
///   only what its own module holds. An application with no services at all
///   does not run them when it serves.
///
/// A module whose start or stop is really an ongoing job (a poller, a
/// consumer) still wants a `service`; hooks are for one-shot work.
public struct LifecycleHook: Sendable {
    /// When a hook runs; the type's notes give the ordering and failure
    /// rules for each.
    public enum Moment: Sendable, Equatable {
        /// Before any service of the application starts. Throwing stops the
        /// start.
        case beforeStart
        /// Before this module's own service starts. Throwing stops the
        /// application.
        case startup
        /// After this module's service has stopped. Throwing is logged and
        /// does not stop the remaining hooks.
        case shutdown
    }

    /// What the log calls it, and what a startup failure names.
    public let name: String
    /// When it runs.
    public let moment: Moment
    let run: @Sendable (Logger) async throws -> Void

    /// - Parameters:
    ///   - name: What the log calls it.
    ///   - moment: When it runs.
    ///   - run: The work, handed a logger labelled with the name.
    public init(
        _ name: String, on moment: Moment, run: @escaping @Sendable (Logger) async throws -> Void
    ) {
        self.name = name
        self.moment = moment
        self.run = run
    }

    /// A hook run before any service of the application starts.
    public static func beforeStart(
        _ name: String, run: @escaping @Sendable (Logger) async throws -> Void
    ) -> LifecycleHook {
        LifecycleHook(name, on: .beforeStart, run: run)
    }

    /// A hook run as the application starts.
    public static func onStartup(
        _ name: String, run: @escaping @Sendable (Logger) async throws -> Void
    ) -> LifecycleHook {
        LifecycleHook(name, on: .startup, run: run)
    }

    /// A hook run as the application stops.
    public static func onShutdown(
        _ name: String, run: @escaping @Sendable (Logger) async throws -> Void
    ) -> LifecycleHook {
        LifecycleHook(name, on: .shutdown, run: run)
    }
}

/// Stands in for a module that has hooks but no service: holds its place in
/// the group until shutdown, so its shutdown hooks run in phase order.
struct AwaitShutdownService: Service {
    func run() async throws {
        try? await gracefulShutdown()
    }
}

struct LifecycleHookFailure: Error, CustomStringConvertible {
    let module: String
    let hook: String
    let underlying: any Error

    var description: String {
        "startup hook '\(hook)' of \(module) failed: \(underlying)"
    }
}
