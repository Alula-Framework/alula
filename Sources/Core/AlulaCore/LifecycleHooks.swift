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
///   application: a start that could not do its work is a failed start.
/// - **Shutdown hooks run after the module's service has stopped**, in the
///   same phase order as services: an `.inbound` module's hooks before a
///   `.standard` one's, and `.infrastructure` last, so a hook can still use
///   the database. One that throws is logged and the rest still run.
/// - Hooks are bounded by `lifecycle.shutdown-timeout-seconds` like the rest
///   of shutdown.
///
/// A module whose start or stop is really an ongoing job (a poller, a
/// consumer) still wants a `service`; hooks are for one-shot work.
public struct LifecycleHook: Sendable {
    public enum Moment: Sendable, Equatable {
        case startup
        case shutdown
    }

    public let name: String
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
