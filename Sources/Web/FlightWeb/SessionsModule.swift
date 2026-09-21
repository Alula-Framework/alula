import FlightCore
import FlightSessions

/// Session wiring, composed by argument:
///
/// ```swift
/// await Flight.run(configuration: try .load(), modules: [
///     FlightWebModule<FlightTransport>.self,
///     FlightSessionsModule.self,
///     FlightSessionsValkeyModule.self,   // flight-data; omit for one replica
///     AppModule.self,
/// ], composedBy: flightComposeModules)
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
public struct FlightSessionsModule: FlightModule {
    /// What the middleware runs on — store, settings, coding, clock. The one
    /// value this module provides, typed distinctly from `any SessionStore`
    /// so it never collides with the adapter that provides one.
    public let runtime: SessionRuntime

    /// ``Sessions``, in the default lane.
    public let middleware: [MiddlewareRegistration]

    /// - Parameters:
    ///   - configuration: `sessions.*` is read from here, and `web.*` for the
    ///     coders when no module provides them.
    ///   - store: A shared store from an adapter module. Nil means the
    ///     in-memory store — one replica, and the default.
    ///   - coders: The application's coders, when a module provides them —
    ///     the same value `FlightWebModule` is composed with, so a session
    ///     value is encoded exactly as a response body would be.
    public init(
        configuration: Configuration,
        store: (any SessionStore)? = nil,
        coders: WebCoders? = nil
    ) throws {
        let settings = try SessionSettings(configuration: configuration)
        if store == nil {
            try configuration.requireNoUnloadedAdapter(
                feature: "sessions",
                candidates: [
                    AdapterCandidate(
                        configurationKey: ValkeySessionConfigKeyProbe.url,
                        module: "FlightSessionsValkeyModule")
                ])
        }
        let runtime = SessionRuntime(
            store: store ?? InMemorySessionStore(maxEntries: settings.memoryMaxEntries),
            settings: settings,
            coders: try coders ?? WebCoders(configuration: configuration))
        self.runtime = runtime
        self.middleware = MiddlewareRegistration.lane(.default, [Sessions(runtime: runtime)])
    }

    public init() {
        preconditionFailure(
            "FlightSessionsModule takes its configuration in init(configuration:store:coders:), so "
                + "it cannot be instantiated from its type. Pass `composedBy: flightComposeModules` "
                + "to Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }
}

/// The adapter's required key, spelled here so this module can notice a
/// configuration block its own build may not contain code for.
///
/// FlightWeb cannot import FlightSessionsValkey — it lives in flight-data,
/// and the dependency runs the other way. A string constant is the whole
/// coupling, and the adapter's own suite pins its key equal to this one so
/// the two cannot drift.
enum ValkeySessionConfigKeyProbe {
    static let url = "sessions.valkey.url"
}
