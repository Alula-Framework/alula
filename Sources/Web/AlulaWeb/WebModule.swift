import AlulaCore
import AlulaTelemetryBridges
import Logging
import ServiceLifecycle
import TelemetryCore

/// The composition-root module (§5.3, §8): choosing a transport is choosing
/// which of these to include —
///
///     await Alula.run(
///         configuration: try Configuration.load(),
///         modules: [AlulaWebModule<AlulaTransport>.self, AppModule.self],
///         composedBy: alulaComposeModules
///     )
///
/// It provides no routes of its own; controllers contribute their routes as
/// values, gathered from every module by the composition root. Its service
/// slots into bootstrap step 8, and request serving begins only once step
/// 9's ServiceGroup runs — which is what guarantees every handler's
/// `@Inject` dependencies are fully resolved before the first request
/// arrives (§8).
///
/// A class holding the `Dispatch` it builds in `init` from the values it was
/// composed with — the routes, middleware, asset mounts and `WebRuntime`
/// (coders + error mapper). Route-table validation happens there, at
/// composition; the service the module contributes reads that already-built
/// dispatch. Nothing is collected from a container, and nothing is resolved
/// per request (COMPOSITION-MIGRATION.md §9).
public final class AlulaWebModule<Transport: ServerTransport>: AlulaModule, @unchecked Sendable {

    /// Reporting comes with the stack: `AlulaTelemetryModule` reports this
    /// module's metrics once a backend is bootstrapped.
    public static var dependencies: [any AlulaModule.Type] { [AlulaTelemetryModule.self] }

    /// Every route in the application: the generated ones, plus whatever each
    /// module declares. The composition root concatenates them.
    public let routes: [RouteRegistration]

    /// Every middleware, with the lanes they declare.
    public let middleware: [MiddlewareRegistration]

    /// Static-asset mounts, which are routing fallbacks rather than routes.
    public let assetMounts: [AssetMountRegistration]

    /// ``HTTPMetrics/definitions``, for `AlulaTelemetryModule` to report.
    public let telemetryMetrics: [TelemetryMetric] = HTTPMetrics.definitions

    /// Encoders and decoders, read from `web.*` once at composition. A
    /// misspelled `web.json.date-strategy` fails here rather than on
    /// whichever request first encoded something.
    public let coders: WebCoders

    /// The application's error mapper, when a module provided one — matched by
    /// type in composition, the same way `coders` is. `.none` declines
    /// everything, the default for an app that maps no errors of its own.
    public let errorMapper: ErrorMapper

    /// The transport's own settings come from here at start-up.
    private let configuration: Configuration

    /// Built in `init`, read by `service`.
    /// Internal rather than private so a `@testable` test can drive the
    /// dispatch this module built from its configuration.
    let dispatch: Dispatch

    /// - Parameters:
    ///   - configuration: The transport reads its own settings from here at
    ///     start-up — `server.host`, `server.port`, the body and frame bounds.
    ///   - routes: Every route the composition root gathered from the
    ///     controllers each module contributed.
    ///   - middleware: Lane registrations, in declaration order.
    ///   - assetMounts: Static-asset mounts the application declared.
    ///   - coders: An application's own encoders/decoders, when it
    ///     has them. Nil means "read `web.*`" — the ordinary case.
    ///
    ///     This used to be a scan: `configure` checked `allRegistrations()` for
    ///     a `WebCoders` an earlier module had registered and stood down if it
    ///     found one, which made the answer depend on module order and on a
    ///     runtime lookup. Whether the application brought its own coders is a
    ///     fact about how it was composed, so it is a parameter — and one the
    ///     composer fills in by type when any module provides `WebCoders`.
    ///   - errorMapper: The application's error mapper, when a module provided
    ///     one — matched by type in composition. Nil becomes `.none`, which
    ///     declines everything.
    ///   - trustedProxies: Which reverse proxies, if any, may set
    ///     `X-Forwarded-For` for `RequestContext.clientAddress`. Nil reads
    ///     `web.trusted-proxies`, which is empty — trust nothing — unless
    ///     configured.
    ///   - securityHeaders: The headers added to every response. Nil reads
    ///     `web.security-headers.*`: `nosniff`, `DENY` and a strict
    ///     referrer policy unless configured off; HSTS and CSP only when
    ///     configured.
    ///   - webSocketOrigins: Which pages may open a WebSocket. Nil reads
    ///     `web.websocket.allowed-origins`: same origin unless configured.
    public init(
        configuration: Configuration,
        routes: [RouteRegistration] = [],
        middleware: [MiddlewareRegistration] = [],
        assetMounts: [AssetMountRegistration] = [],
        coders: WebCoders? = nil,
        errorMapper: ErrorMapper? = nil,
        trustedProxies: TrustedProxies? = nil,
        securityHeaders: SecurityHeaders? = nil,
        webSocketOrigins: WebSocketOrigins? = nil
    ) throws {
        let resolvedCoders = try coders ?? WebCoders(configuration: configuration)
        let resolvedMapper = errorMapper ?? .none
        let resolvedTrustedProxies =
            try trustedProxies ?? TrustedProxies(configuration: configuration)
        let resolvedSecurityHeaders =
            try securityHeaders ?? SecurityHeaders(configuration: configuration)
        let resolvedWebSocketOrigins =
            try webSocketOrigins ?? WebSocketOrigins(configuration: configuration)
        let requestTimeout = try configuration.getIfPresent(
            "web.request-timeout-seconds", as: Double.self)
        if let requestTimeout, !(requestTimeout > 0) {
            throw WebConfigurationError(
                "web.request-timeout-seconds must be positive; it is \(requestTimeout)")
        }
        self.configuration = configuration
        self.coders = resolvedCoders
        self.errorMapper = resolvedMapper
        self.routes = routes
        self.middleware = middleware
        self.assetMounts = assetMounts
        // Dispatch — and route-table validation — is built here, from values.
        // A conflicting or malformed route, or one naming an undeclared lane,
        // fails composition rather than at the service's first breath.
        self.dispatch = try DispatchBuilder.build(
            routes: routes,
            middleware: middleware,
            assetMounts: assetMounts,
            web: WebRuntime(
                coders: resolvedCoders, errorMapper: resolvedMapper,
                trustedProxies: resolvedTrustedProxies,
                securityHeaders: resolvedSecurityHeaders,
                webSocketOrigins: resolvedWebSocketOrigins,
                requestTimeout: requestTimeout.map { .milliseconds(Int64($0 * 1000)) }),
            logger: Logger(label: "alula.web"))
    }

    public init() {
        preconditionFailure(
            "AlulaWebModule takes its configuration and the application's routes in "
                + "init(configuration:routes:middleware:assetMounts:), so it cannot be "
                + "instantiated from its type. Pass `composedBy: alulaComposeModules` to "
                + "Alula.run — `alula new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    public var service: (any Service)? {
        WebHostService<Transport>(dispatch: dispatch, configuration: configuration)
    }

    /// The transport is what brings work in, so it is the first thing to
    /// stop: no new requests, drain what is in flight, and only then let the
    /// pools and buses everything else was using go.
    public var serviceShutdownPhase: ServiceShutdownPhase { .inbound }
}

/// Runs the web stack: read the transport's settings from the app
/// configuration, hand the already-built dispatch to a fresh transport
/// instance, and park in its `run()` until shutdown.
///
/// It used to hold the container and build dispatch here, at `run()`, because
/// the route table was collected from the container post-`freeze()`. The
/// module owns the routes now, so the table is built during configuration and
/// this only runs it.
struct WebHostService<Transport: ServerTransport>: Service {
    let dispatch: Dispatch
    let configuration: Configuration

    func run() async throws {
        let transport = Transport(
            configuration: try Transport.Configuration(configuration: configuration),
            dispatch: dispatch
        )
        try await transport.run()
    }
}

struct WebConfigurationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension WebConfigurationError: ModuleConfigurationError {}
