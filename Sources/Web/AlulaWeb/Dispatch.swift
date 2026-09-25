import Synchronization
import AlulaCore
import Foundation
import HTTPTypes
import Instrumentation
import Logging
import ServiceContextModule
import TelemetryCore
import Tracing

/// The transport boundary: requests in, responses out — including streaming
/// and upgrade responses. Structured `async` end to end; no `EventLoopFuture`
/// anywhere in this boundary.
///
/// Two operations, not one. `respond` answers a request. ``acceptsUpgrade``
/// asks whether a path is a connection-upgrade route, from the route table
/// alone, and a transport **must** ask it before dispatching an
/// upgrade-shaped request — see that property for why.
public struct Dispatch: Sendable {
    /// Runs the full pipeline: middleware, routing, handler.
    public let respond: @Sendable (Request) async -> Response

    /// Whether this request's method and path resolve to an upgrade route.
    ///
    /// Answered without running anything. A transport that skips this check
    /// and dispatches every upgrade-shaped request will execute ordinary HTTP
    /// handlers — their database writes, their side effects — and then throw
    /// the response away, because it cannot perform an upgrade the route
    /// never offered. That turns any `GET` route into something an
    /// unauthenticated client can trigger by attaching upgrade headers.
    public let acceptsUpgrade: @Sendable (Request) -> Bool

    /// How the matched route wants its body delivered — the transport asks
    /// before reading any of it, the same shape as `acceptsUpgrade`. A
    /// route the table does not know answers `.buffered(maxBytes: nil)`;
    /// its 404 needs no body at all.
    public let bodyMode: @Sendable (Request) -> RouteRegistration.BodyMode

    public init(
        respond: @escaping @Sendable (Request) async -> Response,
        acceptsUpgrade: @escaping @Sendable (Request) -> Bool,
        bodyMode: @escaping @Sendable (Request) -> RouteRegistration.BodyMode = { _ in
            .buffered(maxBytes: nil)
        }
    ) {
        self.respond = respond
        self.acceptsUpgrade = acceptsUpgrade
        self.bodyMode = bodyMode
    }

    /// Keeps `await dispatch(request)` reading as a call.
    public func callAsFunction(_ request: Request) async -> Response {
        await respond(request)
    }
}

/// Builds the dispatch closure Alula Web hands to whichever
/// `ServerTransport` is active (§5.3): collect routes and middleware as values
/// at composition, validate the route table, and wrap the whole §3
/// pipeline — scope-per-request, request-stamped logger, trace extraction
/// and a server span — around it. The transport never sees any of this.
public enum DispatchBuilder {

    /// A route names a middleware lane nobody declared. Bootstrap-time,
    /// deliberately: the alternative is a route that 500s (or silently runs
    /// with the wrong stack) on its first request.
    public struct UndeclaredLaneError: Error, CustomStringConvertible {
        public let lane: PipelineLane
        public let route: String
        public var description: String {
            "Route \(route) runs through pipeline lane '\(lane)', but nothing declared it. Declare it with MiddlewareRegistration.lane(\"\(lane)\", [...]) in a module (an empty lane list is legal), or remove it from the route's pipelines."
        }
    }

    /// A route's chain reads the session before anything put it there.
    ///
    /// Composition-time, like the undeclared-lane error, and for the same
    /// reason: the alternative is a middleware that sees `nil` for
    /// `context.session` on every request — `Authentication` quietly never
    /// signing anyone in from their cookie — with nothing anywhere saying why.
    /// The chain is checked as the route will run it, lanes concatenated, so
    /// a reader in the default lane and `Sessions` in a second lane the route
    /// adds is caught too.
    public struct SessionOrderError: Error, CustomStringConvertible {
        public let route: String
        public let reader: String
        public let sessions: String
        public var description: String {
            "Route \(route) runs \(reader) before \(sessions), but \(reader) reads the session \(sessions) puts on the request. List Sessions ahead of it in the lane — AlulaSecurityModule does this itself when it is given a SessionRuntime — or drop Sessions from the route's lanes if it needs no session."
        }
    }

    static func checkSessionOrder(_ chain: [MiddlewareRegistration], route: String) throws {
        guard let sessionsIndex = chain.firstIndex(where: \.providesSession) else { return }
        if let early = chain[..<sessionsIndex].first(where: \.readsSession) {
            throw SessionOrderError(
                route: route, reader: early.name, sessions: chain[sessionsIndex].name)
        }
    }

    /// Routes and middleware arrive as values, read once at composition and
    /// immutable thereafter (Alula Core §2.1).
    ///
    /// Dispatch routes **first**, then runs the matched route's own lane
    /// chain — composed once per route, here, not per request. That
    /// ordering, rather than one global chain wrapping the router, is what
    /// makes per-route lanes possible: a static-asset route can run a
    /// near-empty stack while its neighbor runs transactions and auth,
    /// because by the time middleware runs the route is already known.
    /// The no-match path (404/405) runs the **default** lane, so access
    /// logging and friends still see every miss — the property the old
    /// wrap-the-router shape had, kept on purpose.
    /// Builds dispatch from values.
    ///
    /// Every registry it needs is a list of contributions, and a contribution
    /// is a value a module holds (COMPOSITION-MIGRATION.md D15). Lanes are
    /// derived from the middleware rather than passed separately: a lane *is*
    /// the set of middleware naming it, and `MiddlewareRegistration.lane("x", [])`
    /// contributes a lane marker so an empty lane still counts as declared.
    public static func build(
        routes: [RouteRegistration],
        middleware: [MiddlewareRegistration],
        assetMounts: [AssetMountRegistration] = [],
        web: WebRuntime = .default,
        logger: Logger = Logger(label: "alula.web")
    ) throws -> Dispatch {
        let router = try Router(routes: routes)

        // Lane validation: the default lane exists even when empty (an app
        // with no middleware is legal); anything else must be declared.
        //
        // A lane is declared by anything naming it, including the marker
        // `.lane("x", [])` leaves for an empty lane — so declaring and
        // populating are separate passes. Order within a lane is declaration
        // order — outermost first.
        var declaredLanes: Set<PipelineLane> = []
        var entries: [PipelineLane: [(offset: Int, registration: MiddlewareRegistration)]] = [:]
        for (offset, registration) in middleware.enumerated() {
            declaredLanes.insert(registration.lane)
            guard !registration.isLaneMarker else { continue }
            entries[registration.lane, default: []].append((offset, registration))
        }
        var chainsByLane: [PipelineLane: [MiddlewareRegistration]] = [:]
        for lane in declaredLanes {
            chainsByLane[lane] = (entries[lane] ?? [])
                .sorted { $0.offset < $1.offset }
                .map(\.registration)
        }
        if chainsByLane[.default] == nil {
            chainsByLane[.default] = []
        }
        // `.public` means "explicitly no lanes", so the framework declares it
        // empty rather than asking every application to write
        // `MiddlewareRegistration.lane("public", [])` for a lane that does nothing.
        if chainsByLane[.public] == nil {
            chainsByLane[.public] = []
        }

        // One composed responder per route, keyed by the same string that is
        // already that route's unique component qualifier.
        var respondersByRoute = [Next?](repeating: nil, count: router.routes.count)
        for (routeIndex, route) in router.routes.enumerated() {
            var chain: [MiddlewareRegistration] = []
            for lane in route.pipelines {
                guard let laneChain = chainsByLane[lane] else {
                    throw UndeclaredLaneError(
                        lane: lane,
                        route: "\(route.method.rawValue) \(route.path) (\(route.source))")
                }
                chain += laneChain
            }
            try checkSessionOrder(
                chain, route: "\(route.method.rawValue) \(route.path) (\(route.source))")
            let terminal: Next = { context in
                // The match that selected this responder, threaded through a
                // task-local rather than re-derived. This used to re-run the
                // whole route table to recover path parameters the caller had
                // already computed — a second full match, per request, on
                // every matched route.
                if let match = Router.currentMatch, match.routeIndex == routeIndex {
                    return await Router.execute(match, context: context)
                }
                // A hand-built chain (test harnesses run one) calls this
                // without the binding. Re-matching keeps that path working.
                guard
                    case .matched(let match) = router.route(
                        method: context.request.method, path: context.request.path)
                else {
                    return context.coders.renderError(.notFound, "Not Found")
                }
                return await Router.execute(match, context: context)
            }
            respondersByRoute[routeIndex] = compose(chain, around: terminal)

            logger.debug(
                "route registered",
                metadata: [
                    "method": "\(route.method.rawValue)",
                    "path": "\(route.path)",
                    "kind": route.kind.isUpgrade ? "upgrade" : "http",
                    "pipelines": .array(route.pipelines.map { .string($0.name) }),
                    "source": "\(route.source)",
                ])
        }

        // Asset mounts: fallbacks for GET/HEAD routing misses, each wrapped
        // in its own lane chain — composed here, once, like every route.
        let mounts = assetMounts
        var mountResponders: [(mount: AssetMountRegistration, responder: Next)] = []
        for mount in mounts {
            var chain: [MiddlewareRegistration] = []
            for lane in mount.pipelines {
                guard let laneChain = chainsByLane[lane] else {
                    throw UndeclaredLaneError(lane: lane, route: "assets at \(mount.prefix)")
                }
                chain += laneChain
            }
            try checkSessionOrder(chain, route: "assets at \(mount.prefix)")
            mountResponders.append(
                (mount, compose(chain, around: { context in await mount.respond(to: context) })))
            // A mount whose root does not exist serves nothing but 404s —
            // legal (the interface may not be built yet), but the person
            // staring at those 404s deserves one line saying why.
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: mount.root, isDirectory: &isDirectory)
                || !isDirectory.boolValue
            {
                logger.warning(
                    "asset mount root does not exist — every request under \(mount.prefix) will 404 until it does",
                    metadata: ["root": "\(mount.root)"])
            }
            // A route always beats a mount, so one claiming exactly the
            // mount's prefix hides its index page there — and every other
            // path under the mount works, which is what makes it hard to
            // see (Relay #26: the scaffold's `GET /` answered "flying"
            // where the built front end's index.html belonged).
            let index = (mount.root as NSString).appendingPathComponent(mount.options.index)
            let prefix = mount.prefix.hasSuffix("/") && mount.prefix.count > 1
                ? String(mount.prefix.dropLast()) : mount.prefix
            if FileManager.default.fileExists(atPath: index),
                let shadow = routes.first(where: {
                    $0.method == .get && ($0.path == prefix || $0.path == prefix + "/")
                })
            {
                logger.warning(
                    "GET \(shadow.path) is answered by a route, so the asset mount's \(mount.options.index) is never served there",
                    metadata: ["route": "\(shadow.source)", "mount": "\(mount.prefix)", "root": "\(mount.root)"])
            }
            logger.debug(
                "asset mount registered",
                metadata: [
                    "prefix": "\(mount.prefix)",
                    "root": "\(mount.root)",
                    "pipelines": .array(mount.pipelines.map { .string($0.name) }),
                ])
        }

        let defaultChain = chainsByLane[.default] ?? []
        let noMatchResponder: Next = compose(
            defaultChain,
            around: { context in
                Router.renderNoMatch(
                    router.route(method: context.request.method, path: context.request.path),
                    context: context)
            })

        logger.info(
            "alula web dispatch assembled",
            metadata: [
                "routes": .stringConvertible(router.routes.count),
                "lanes": .dictionary(
                    .init(
                        uniqueKeysWithValues: chainsByLane.map { lane, chain in
                            (lane.name, Logger.MetadataValue.array(chain.map { .string($0.name) }))
                        })),
            ])

        let responders = respondersByRoute
        let fallbacks = mountResponders
        let respond: Next = { context in
            switch router.route(method: context.request.method, path: context.request.path) {
            case .matched(let match):
                if let responder = responders[match.routeIndex] {
                    return try await Router.$currentMatch.withValue(match) {
                        try await responder(context)
                    }
                }
                // Unreachable: every route in the table got a responder
                // above. The fallback keeps this total rather than trapping.
                return await Router.execute(match, context: context)
            case .notFound:
                // A routing miss under a mount's prefix is that mount's to
                // answer — file, shell, or its own 404 — inside its own
                // lanes. First claiming mount wins; a request no mount
                // claims takes the ordinary path. 405 never reaches mounts:
                // a path the route table knows under another method is the
                // router's answer, not a file's.
                for (mount, responder) in fallbacks where mount.claims(context.request) {
                    return try await responder(context)
                }
                return try await noMatchResponder(context)
            case .methodNotAllowed:
                return try await noMatchResponder(context)
            }
        }

        return makeDispatch(
            pipeline: respond,
            acceptsUpgrade: { router.acceptsUpgrade(method: $0.method, path: $0.path) },
            bodyMode: { request in
                guard
                    case .matched(let match) = router.route(
                        method: request.method, path: request.path)
                else { return .buffered(maxBytes: nil) }
                return match.route.bodyMode
            },
            timeout: { request in
                guard
                    case .matched(let match) = router.route(
                        method: request.method, path: request.path)
                else { return web.requestTimeout }
                return match.route.timeout.effective(
                    kind: match.route.kind, bodyMode: match.route.bodyMode,
                    fallback: web.requestTimeout)
            },
            routePattern: { request in
                switch router.route(method: request.method, path: request.path) {
                case .matched(let match):
                    return match.route.path
                case .notFound:
                    return fallbacks.first { $0.0.claims(request) }.map { $0.0.prefix + "*" }
                case .methodNotAllowed:
                    return nil
                }
            },
            web: web,
            logger: logger)
    }

    /// The assembled per-request pipeline, exposed separately so test
    /// harnesses can run a hand-built chain — a plain `[MiddlewareRegistration]`,
    /// not a single controller in it — without needing
    /// a full application's worth of components.
    ///
    /// `chain` is folded around `responder` **once, here** — a request pays
    /// one call per layer, never the cost of building the chain.
    public static func makeDispatch(
        chain: [MiddlewareRegistration],
        responder: @escaping Next,
        acceptsUpgrade: @escaping @Sendable (Request) -> Bool = { _ in false },
        web: WebRuntime = .default,
        logger: Logger
    ) -> Dispatch {
        makeDispatch(
            pipeline: compose(chain, around: responder),
            acceptsUpgrade: acceptsUpgrade, web: web,
            logger: logger)
    }

    /// The per-request envelope — request id, trace extraction, the server
    /// span, one `Scope` — around an already-assembled pipeline.
    public static func makeDispatch(
        pipeline: @escaping Next,
        acceptsUpgrade: @escaping @Sendable (Request) -> Bool = { _ in false },
        bodyMode: @escaping @Sendable (Request) -> RouteRegistration.BodyMode = { _ in
            .buffered(maxBytes: nil)
        },
        timeout: @escaping @Sendable (Request) -> Duration? = { _ in nil },
        routePattern: @escaping @Sendable (Request) -> String? = { _ in nil },
        web: WebRuntime = .default,
        logger: Logger
    ) -> Dispatch {
        let respond: @Sendable (Request) async -> Response = { request in
            // Read only when something will see the request event.
            let start =
                Telemetry.isEnabled(HTTPEvents.RequestHandled.self) ? ContinuousClock.now : nil

            // Request identity: honor an inbound X-Request-ID, mint otherwise.
            let requestID = request.headers[.xRequestID] ?? UUID().uuidString

            var requestLogger = logger
            requestLogger[metadataKey: "request-id"] = "\(requestID)"
            requestLogger[metadataKey: "method"] = "\(request.method.rawValue)"
            requestLogger[metadataKey: "path"] = "\(request.path)"

            // Propagated trace context (W3C traceparent etc.) comes in via
            // whatever Instrument the app bootstrapped at its composition
            // root — Alula Web only speaks the facade (Alula Core §9).
            var serviceContext = ServiceContext.topLevel
            InstrumentationSystem.instrument.extract(
                request.headers, into: &serviceContext, using: HTTPFieldsExtractor()
            )

            return await withSpan(
                "HTTP \(request.method.rawValue)",
                context: serviceContext,
                ofKind: .server
            ) { span in
                span.attributes["http.request.method"] = request.method.rawValue
                span.attributes["url.path"] = request.path

                let context = RequestContext(
                    request: request,
                    logger: requestLogger,
                    tracingContext: span.context,
                    web: web
                )
                // The backstop: a route handler's own thrown errors are
                // already turned into a response inside the router (the
                // innermost layer), so only a middleware throwing — a
                // transaction coordinator failing to bind, a pool exhausted
                // before a handler ever runs — reaches here uncaught.
                let response: Response
                if acceptsUpgrade(request),
                    !web.webSocketOrigins.permits(request, trustedProxies: web.trustedProxies)
                {
                    // Before every lane: a refused handshake must not reach
                    // the session or authentication layers it is trying to
                    // borrow. See `WebSocketOrigins`.
                    requestLogger.info(
                        "cross-origin WebSocket handshake refused",
                        metadata: ["origin": "\(request.headers[.origin] ?? "")"])
                    response = .problem(
                        status: .forbidden, message: "Cross-origin WebSocket handshake refused")
                } else if let limit = timeout(request) {
                    response = await Self.respond(
                        within: limit, context: context, logger: requestLogger
                    ) {
                        do {
                            return try await pipeline(context)
                        } catch {
                            return errorResponse(for: error, context: context)
                        }
                    }
                } else {
                    do {
                        response = try await pipeline(context)
                    } catch {
                        response = errorResponse(for: error, context: context)
                    }
                }

                span.attributes["http.response.status_code"] = response.status.code
                if response.status.kind == .serverError {
                    span.setStatus(SpanStatus(code: .error))
                }
                Telemetry.emit(HTTPEvents.RequestHandled.self) {
                    (
                        .init(duration: start.map { .now - $0 } ?? .zero),
                        .init(
                            method: request.method.rawValue,
                            route: routePattern(request) ?? "unmatched",
                            status: response.status.code)
                    )
                }
                // After every lane, so no route's choice of lanes can drop
                // them — see `SecurityHeaders` for why this is not a
                // middleware. A header the response already set wins.
                return web.securityHeaders.apply(to: response)
                    .settingHeader(.xRequestID, requestID)
            }
        }
        return Dispatch(respond: respond, acceptsUpgrade: acceptsUpgrade, bodyMode: bodyMode)
    }
}

extension HTTPField.Name {
    /// Not one of HTTPTypes' predefined names; "X-Request-ID" is valid by
    /// construction.
    public static let xRequestID = HTTPField.Name("X-Request-ID")!
}

/// Reads propagation headers out of `HTTPFields` for trace extraction.
extension DispatchBuilder {
    /// Runs `work` under a deadline and answers 503 when it passes.
    ///
    /// The work runs in its own task so the answer does not wait for it: a
    /// handler blocked in code that ignores cancellation (a synchronous
    /// library call, a lock) would otherwise hold the response for as long
    /// as it blocks, which is the failure the limit exists to bound. The task
    /// is cancelled either way. `Deadline.current` is set inside it for
    /// anything the request calls.
    static func respond(
        within limit: Duration, context: RequestContext, logger: Logger,
        _ work: @escaping @Sendable () async -> Response
    ) async -> Response {
        let deadline = ContinuousClock.now.advanced(by: limit)
        let first = FirstResponse()
        return await withCheckedContinuation { continuation in
            first.install(continuation)
            let timer = Task {
                try await Task.sleep(until: deadline, clock: .continuous)
                if first.resolve(context.coders.renderError(.serviceUnavailable, "Request timed out")) {
                    logger.warning("request timed out", metadata: ["limit": "\(limit)"])
                    first.fireTimeout()
                }
            }
            let handler = Task {
                let response = await Deadline.$current.withValue(deadline) { await work() }
                if first.resolve(response) { timer.cancel() }
            }
            first.onTimeout { handler.cancel() }
        }
    }
}

/// Resumes a continuation with whichever response arrives first.
final class FirstResponse: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Response, Never>?
        var pending: Response?
        var done = false
        var onTimeout: (@Sendable () -> Void)?
        var timedOut = false
    }
    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Response, Never>) {
        let early = state.withLock { state -> Response? in
            if let pending = state.pending { return pending }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    /// True if this was the first.
    @discardableResult
    func resolve(_ response: Response) -> Bool {
        let (winner, continuation) = state.withLock {
            state -> (Bool, CheckedContinuation<Response, Never>?) in
            guard !state.done else { return (false, nil) }
            state.done = true
            guard let continuation = state.continuation else {
                state.pending = response
                return (true, nil)
            }
            state.continuation = nil
            return (true, continuation)
        }
        continuation?.resume(returning: response)
        return winner
    }

    func onTimeout(_ action: @escaping @Sendable () -> Void) {
        let alreadyFired = state.withLock { state -> Bool in
            if state.timedOut { return true }
            state.onTimeout = action
            return false
        }
        if alreadyFired { action() }
    }

    func fireTimeout() {
        state.withLock { state -> (@Sendable () -> Void)? in
            state.timedOut = true
            return state.onTimeout
        }?()
    }
}

struct HTTPFieldsExtractor: Extractor {
    func extract(key: String, from carrier: HTTPFields) -> String? {
        guard let name = HTTPField.Name(key) else { return nil }
        return carrier[name]
    }
}
