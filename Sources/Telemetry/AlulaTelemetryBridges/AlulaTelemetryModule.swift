import CoreMetrics
import AlulaCore
import Logging
import ServiceLifecycle
import Synchronization
import TelemetryCore
import Tracing

/// Reports every module's metrics, and optionally traces spans and logs
/// events:
///
/// ```swift
/// await Alula.run(configuration: try .load(), modules: [
///     AlulaWebModule<AlulaTransport>.self,
///     AlulaSessionsModule.self,
///     AlulaTelemetryModule.self,
///     AppModule.self,
/// ], composedBy: alulaComposeModules)
/// ```
///
/// ```yaml
/// telemetry:
///   metrics:
///     enabled: true               # default: when a metrics backend is bootstrapped
///     cardinality-limit: 1000     # tag combinations per metric
///   tracing:
///     enabled: true               # default: when a tracer is bootstrapped
///     prefix: hangar              # every span when unset
///   log:
///     prefix: alula.sessions     # off unless set
///     level: debug
/// ```
///
/// **Metrics are contributions.** Any module that holds a
/// `[TelemetryMetric]` property contributes it — Alula's own modules
/// declare their defaults that way, and a package Alula has never heard of
/// does the same — and this module reports them all through
/// swift-metrics, to the backend the application bootstrapped. An
/// application adds its own the same way, from its own module:
///
/// ```swift
/// struct AppModule: AlulaModule {
///     let telemetryMetrics: [TelemetryMetric] = [
///         .distribution(Checkout.Stop.self, \.duration, unit: .milliseconds, tags: \.method),
///     ]
/// }
/// ```
///
/// **Listed for you.** `AlulaWebModule`, `AlulaSessionsModule`,
/// `AlulaSecurityModule` and `AlulaAPNSModule` depend on this module, so an
/// application using any of them has it without naming it. It costs nothing
/// until there is somewhere to send things: metrics are reported only when
/// the application bootstrapped a metrics backend (`MetricsSystem`), spans
/// traced only when it bootstrapped a tracer (`InstrumentationSystem`) —
/// unless `telemetry.*` says otherwise. An event nobody is listening to is
/// an atomic load and a branch.
///
/// Everything is attached in `init`, at composition — before any request,
/// so nothing emitted during startup is missed — and detached when the
/// application shuts down.
public struct AlulaTelemetryModule: AlulaModule {
    /// `telemetry.*`, read once at composition.
    public let settings: TelemetrySettings

    /// Whether metrics are reported: `telemetry.metrics.enabled`, or, when
    /// unset, whether a metrics backend was bootstrapped.
    public let metricsEnabled: Bool

    /// Whether spans are traced: `telemetry.tracing.enabled`, or, when
    /// unset, whether a tracer was bootstrapped.
    public let tracingEnabled: Bool

    public let service: (any Service)?

    private let metrics: [TelemetryMetric]

    /// The metrics reported, or that would be when enabled: every module's
    /// contributions, then this module's own.
    public var reportedMetrics: [TelemetryMetric] { metrics }

    /// - Parameters:
    ///   - configuration: `telemetry.*` is read from here.
    ///   - metrics: Every included module's `[TelemetryMetric]`, gathered
    ///     by composition.
    ///   - metricsFactory: Where instruments are made. Provide one from a
    ///     module (`let metricsFactory: any MetricsFactory`) to choose the
    ///     backend explicitly; otherwise it is `MetricsSystem.factory`,
    ///     read when each instrument is first made.
    public init(
        configuration: Configuration,
        metrics: [TelemetryMetric] = [],
        metricsFactory: (any MetricsFactory)? = nil
    ) throws {
        try self.init(
            configuration: configuration, metrics: metrics, metricsFactory: metricsFactory,
            backends: .bootstrapped)
    }

    /// Whether a metrics backend and a tracer are there to report to — the
    /// bootstrapped systems, or a test's stand-in.
    package struct Backends: Sendable {
        package var metrics: @Sendable () -> Bool
        package var tracing: @Sendable () -> Bool

        package init(
            metrics: @escaping @Sendable () -> Bool, tracing: @escaping @Sendable () -> Bool
        ) {
            self.metrics = metrics
            self.tracing = tracing
        }

        static let bootstrapped = Backends(
            metrics: { !(MetricsSystem.factory is NOOPMetricsHandler) },
            tracing: { !(InstrumentationSystem.tracer is NoOpTracer) })
    }

    package init(
        configuration: Configuration,
        metrics: [TelemetryMetric],
        metricsFactory: (any MetricsFactory)?,
        backends: Backends
    ) throws {
        let settings = try TelemetrySettings(configuration: configuration)
        self.settings = settings
        let reported = metrics + Self.ownMetrics
        self.metrics = reported
        self.metricsEnabled =
            settings.metricsEnabled
            ?? (metricsFactory.map { !($0 is NOOPMetricsHandler) } ?? backends.metrics())
        self.tracingEnabled = settings.tracingEnabled ?? backends.tracing()

        // Checked whether or not metrics are on: a clash is a mistake in the
        // definitions, and should not wait for the day a backend is added.
        try Self.checkNames(reported)

        let limit = settings.cardinalityLimit
        let tracingPrefix = settings.tracingPrefix
        var tokens = HandlerTokens()
        if metricsEnabled {
            let reporter = SwiftMetricsReporter(factory: metricsFactory, cardinalityLimit: limit)
            tokens.append(contentsOf: try reporter.attach(reported))
        }
        if tracingEnabled {
            tokens.append(
                try Telemetry.observeSpans(
                    prefix: tracingPrefix, id: "alula.telemetry.tracing", TracingObserver()))
        }
        if let prefix = settings.logPrefix {
            tokens.append(
                contentsOf: try LogBridge(logger: Logger(label: "alula.telemetry"))
                    .log(prefix: prefix, level: settings.logLevel)
                    .attach())
        }

        // A backend bootstrapped *after* composition — from another module's
        // initializer, say — would otherwise be missed for good: the decision
        // above ran before it existed. Where the decision was automatic and
        // came out "off", look again when this module's service starts, by
        // which time every module has been built.
        let recheckMetrics =
            settings.metricsEnabled == nil && metricsFactory == nil && !metricsEnabled
        let recheckTracing = settings.tracingEnabled == nil && !tracingEnabled
        var late: (@Sendable () throws -> HandlerTokens)?
        if recheckMetrics || recheckTracing {
            late = { @Sendable () throws -> HandlerTokens in
                var tokens = HandlerTokens()
                if recheckMetrics, backends.metrics() {
                    tokens.append(
                        contentsOf: try SwiftMetricsReporter(cardinalityLimit: limit).attach(
                            reported))
                }
                if recheckTracing, backends.tracing() {
                    tokens.append(
                        try Telemetry.observeSpans(
                            prefix: tracingPrefix, id: "alula.telemetry.tracing", TracingObserver()
                        ))
                }
                return tokens
            }
        }
        self.service = TelemetryAttachments(tokens, late: late)
    }

    public init() {
        preconditionFailure(
            "AlulaTelemetryModule takes its configuration in init(configuration:metrics:), so "
                + "it cannot be instantiated from its type. Pass `composedBy: alulaComposeModules` "
                + "to Alula.run — `alula new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    /// The telemetry runtime's own failures, counted.
    static let ownMetrics: [TelemetryMetric] = [
        .counter(TelemetryHandlerFailed.self, tags: \.event),
        .counter(TelemetryCardinalityExceeded.self, tags: \.metric),
    ]

    /// Two definitions with one name would report into one instrument as if
    /// they were one metric, so it is refused here, at composition, naming
    /// both events.
    private static func checkNames(_ metrics: [TelemetryMetric]) throws {
        var seen: [String: EventName] = [:]
        for metric in metrics {
            let name = SwiftMetricsReporter.label(for: metric.descriptor.name)
            if let other = seen[name] {
                throw TelemetryConfigurationError.duplicateMetric(
                    name: name, events: [other, metric.descriptor.event])
            }
            seen[name] = metric.descriptor.event
        }
    }
}

/// Holds the module's attachments for the application's life, and detaches
/// them at shutdown — attaching late what composition could not, when a
/// backend was bootstrapped after it.
final class TelemetryAttachments: Service, Sendable {
    private let tokens: Mutex<HandlerTokens?>
    private let late: (@Sendable () throws -> HandlerTokens)?

    init(_ tokens: consuming HandlerTokens, late: (@Sendable () throws -> HandlerTokens)?) {
        self.tokens = Mutex(tokens)
        self.late = late
    }

    func run() async throws {
        if let late {
            let attached = try tokens.withLock { held -> Int in
                let more = try late()
                let count = more.count
                held?.append(contentsOf: more)
                return count
            }
            if attached > 0 {
                Logger(label: "alula.telemetry").notice(
                    "a metrics backend or tracer was bootstrapped after composition; reporting from now",
                    metadata: ["attached": "\(attached)"])
            }
        }
        try? await gracefulShutdown()
        let held = tokens.withLock { tokens in tokens.take() }
        held?.detach()
    }
}

/// The `telemetry.*` configuration vocabulary (env-var form
/// `ALULA_TELEMETRY_*`).
public enum TelemetryConfigKey {
    /// `telemetry.metrics.enabled` — report contributed metrics. Unset means
    /// "when a metrics backend is bootstrapped".
    public static let metricsEnabled = "telemetry.metrics.enabled"
    /// `telemetry.metrics.cardinality-limit` — tag combinations per metric.
    public static let cardinalityLimit = "telemetry.metrics.cardinality-limit"
    /// `telemetry.tracing.enabled` — turn spans into tracing spans. Unset
    /// means "when a tracer is bootstrapped": observing a span puts it on
    /// the slow path, which is worth paying only with somewhere to send it.
    public static let tracingEnabled = "telemetry.tracing.enabled"
    /// `telemetry.tracing.prefix` — only spans under this name. Every span
    /// when unset.
    public static let tracingPrefix = "telemetry.tracing.prefix"
    /// `telemetry.log.prefix` — log every event under this name. Off unless
    /// set.
    public static let logPrefix = "telemetry.log.prefix"
    /// `telemetry.log.level` — the level those lines are logged at.
    public static let logLevel = "telemetry.log.level"
}

/// Loaded, validated `telemetry.*` settings.
public struct TelemetrySettings: Sendable, Equatable {
    /// Nil: decided by whether a metrics backend is bootstrapped.
    public var metricsEnabled: Bool?
    public var cardinalityLimit: Int
    /// Nil: decided by whether a tracer is bootstrapped.
    public var tracingEnabled: Bool?
    public var tracingPrefix: EventName
    public var logPrefix: EventName?
    public var logLevel: Logger.Level

    public init(
        metricsEnabled: Bool? = nil, cardinalityLimit: Int = 1000, tracingEnabled: Bool? = nil,
        tracingPrefix: EventName = .all, logPrefix: EventName? = nil,
        logLevel: Logger.Level = .debug
    ) throws {
        guard cardinalityLimit > 0 else {
            throw TelemetryConfigurationError.invalidCardinalityLimit(cardinalityLimit)
        }
        self.metricsEnabled = metricsEnabled
        self.cardinalityLimit = cardinalityLimit
        self.tracingEnabled = tracingEnabled
        self.tracingPrefix = tracingPrefix
        self.logPrefix = logPrefix
        self.logLevel = logLevel
    }

    /// Reads `telemetry.*`. Absent keys take the defaults; a present key
    /// that does not decode throws, naming it.
    public init(configuration: Configuration) throws {
        func eventName(_ key: String) throws -> EventName? {
            guard let raw: String = try configuration.getIfPresent(key) else { return nil }
            do {
                return try EventName(validating: raw)
            } catch {
                throw TelemetryConfigurationError.invalidPrefix(key: key, value: raw)
            }
        }
        var logLevel = Logger.Level.debug
        if let raw: String = try configuration.getIfPresent(TelemetryConfigKey.logLevel) {
            guard let level = Logger.Level(rawValue: raw.lowercased()) else {
                throw TelemetryConfigurationError.invalidLogLevel(raw)
            }
            logLevel = level
        }
        try self.init(
            metricsEnabled: try configuration.getIfPresent(TelemetryConfigKey.metricsEnabled),
            cardinalityLimit: try configuration.getIfPresent(TelemetryConfigKey.cardinalityLimit)
                ?? 1000,
            tracingEnabled: try configuration.getIfPresent(TelemetryConfigKey.tracingEnabled),
            tracingPrefix: try eventName(TelemetryConfigKey.tracingPrefix) ?? .all,
            logPrefix: try eventName(TelemetryConfigKey.logPrefix),
            logLevel: logLevel)
    }
}

/// A `telemetry.*` value, or a set of contributed metrics, that cannot be
/// used. Thrown at composition.
public enum TelemetryConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidCardinalityLimit(Int)
    case invalidPrefix(key: String, value: String)
    case invalidLogLevel(String)
    case duplicateMetric(name: String, events: [EventName])

    public var description: String {
        switch self {
        case .invalidCardinalityLimit(let limit):
            "\(TelemetryConfigKey.cardinalityLimit) must be positive; it is \(limit)"
        case .invalidPrefix(let key, let value):
            "\(key) '\(value)' is not an event name prefix: dot-separated segments of [a-z][a-z0-9_]*"
        case .invalidLogLevel(let value):
            "\(TelemetryConfigKey.logLevel) '\(value)' is not a log level: trace, debug, info, notice, "
                + "warning, error or critical"
        case .duplicateMetric(let name, let events):
            "two metrics are named '\(name)' (from \(events.map(\.description).joined(separator: " and "))); "
                + "give one of them a `name:`"
        }
    }
}

extension Optional where Wrapped: ~Copyable {
    fileprivate mutating func take() -> Wrapped? {
        switch consume self {
        case .some(let value):
            self = nil
            return value
        case .none:
            self = nil
            return nil
        }
    }
}
