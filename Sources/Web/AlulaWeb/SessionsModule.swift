import AlulaCore
import AlulaSessions
import AlulaTelemetryBridges
import TelemetryCore

/// Session wiring, composed by argument:
///
/// ```swift
/// await Alula.run(configuration: try .load(), modules: [
///     AlulaWebModule<AlulaTransport>.self,
///     AlulaSessionsModule.self,
///     AlulaSessionsValkeyModule.self,   // alula-data; omit for one replica
///     AppModule.self,
/// ], composedBy: alulaComposeModules)
/// ```
///
/// Built in `init`, from configuration and an optional `store`:
///
/// 1. `sessions.*` is read and validated, so a bad cookie name or a
///    `SameSite=None` without `Secure` fails composition;
/// 2. the store is the one an adapter module provides — matched by type in
///    composition — or an `InMemorySessionStore` bounded by
///    `sessions.memory.max-entries` when none was. Absent adapter means one
///    replica, the common case; configuring an adapter's URL without listing
///    its module is refused, because two replicas each keeping private
///    sessions is the failure nobody notices until a user is signed out by
///    a load balancer;
/// 3. the ``Sessions`` middleware goes into the default lane. A route that
///    names its own lanes and wants a session lists `Sessions` there —
///    a lane is the whole stack for the routes naming it.
///
/// No `service`: the in-memory store has no long-running work. An adapter
/// module with a connection exposes its own.
public struct AlulaSessionsModule: AlulaModule {

    /// Reporting comes with the stack: `AlulaTelemetryModule` reports this
    /// module's metrics once a backend is bootstrapped.
    public static var dependencies: [any AlulaModule.Type] { [AlulaTelemetryModule.self] }
    /// What the middleware runs on — store, settings, coding, clock. The one
    /// value this module provides, typed distinctly from `any SessionStore`
    /// so it never collides with the adapter that provides one.
    public let runtime: SessionRuntime

    /// ``Sessions``, in the default lane.
    public let middleware: [MiddlewareRegistration]

    /// ``SessionMetrics/definitions``, for `AlulaTelemetryModule` to report.
    public let telemetryMetrics: [TelemetryMetric] = SessionMetrics.definitions

    /// - Parameters:
    ///   - configuration: `sessions.*` is read from here.
    ///   - store: A shared store from an adapter module. Nil means the
    ///     in-memory store — one replica, and the default.
    ///
    /// There is deliberately no `coders:` parameter. There was one, so that a
    /// session value would be encoded the way a response body is — and
    /// `AlulaWebModule` *provides* `WebCoders` while *taking* this module's
    /// middleware, which made the two modules a composition cycle the build
    /// refused. Session values are opaque bytes this runtime round-trips
    /// itself, so nothing is lost by encoding them with plain JSON coders.
    public init(
        configuration: Configuration,
        store: (any SessionStore)? = nil
    ) throws {
        let settings = try SessionSettings(configuration: configuration)
        if store == nil {
            try configuration.requireNoUnloadedAdapter(
                feature: "sessions",
                candidates: [
                    AdapterCandidate(
                        configurationKey: ValkeySessionConfigKeyProbe.url,
                        module: "AlulaSessionsValkeyModule")
                ])
        }
        let runtime = SessionRuntime(
            store: store ?? InMemorySessionStore(maxEntries: settings.memoryMaxEntries),
            settings: settings)
        self.runtime = runtime
        self.middleware = MiddlewareRegistration.lane(.default, [Sessions(runtime: runtime)])
    }

    public init() {
        preconditionFailure(
            "AlulaSessionsModule takes its configuration in init(configuration:store:), so "
                + "it cannot be instantiated from its type. Pass `composedBy: alulaComposeModules` "
                + "to Alula.run — `alula new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }
}

/// The adapter's required key, spelled here so this module can notice a
/// configuration block its own build may not contain code for.
///
/// AlulaWeb cannot import AlulaSessionsValkey — it lives in alula-data,
/// and the dependency runs the other way. A string constant is the whole
/// coupling, and the adapter's own suite pins its key equal to this one so
/// the two cannot drift.
enum ValkeySessionConfigKeyProbe {
    static let url = "sessions.valkey.url"
}
