import FlightTelemetry
import Logging
import ServiceContextModule

/// Turns events into log lines. One direction only: structured
/// occurrences are events, free-form diagnostics stay in swift-log, and
/// this lets the first become the second where someone wants to read them.
///
/// ```swift
/// let tokens = try LogBridge(logger: Logger(label: "telemetry"))
///     .log(HangarQuery.Exception.self, level: .error)
///     .log(prefix: "hangar", level: .debug)       // everything under hangar
///     .attach()
/// ```
///
/// The message is the event name; measurements and metadata are the log
/// line's metadata, under their field names. The level is checked before
/// anything is encoded, so a rule below the logger's level costs a handler
/// call and a comparison.
///
/// The local span id on every log line — this bridge's and a plain
/// `logger.info` inside a span alike — comes from
/// ``Logging/Logger/MetadataProvider/telemetry``.
public struct LogBridge: Sendable {
    private let logger: Logger
    private let rules: [Rule]

    private enum Rule: Sendable {
        case typed(@Sendable (Logger, HandlerID) throws(AttachError) -> HandlerToken)
        case prefix(EventName, Logger.Level)
    }

    public init(logger: Logger) {
        self.init(logger: logger, rules: [])
    }

    private init(logger: Logger, rules: [Rule]) {
        self.logger = logger
        self.rules = rules
    }

    /// Logs every emit of `E` at `level`.
    public func log<E: TelemetryEvent>(_: E.Type, level: Logger.Level) -> LogBridge {
        LogBridge(
            logger: logger,
            rules: rules + [
                .typed { logger, id throws(AttachError) in
                    try Telemetry.attach(E.self, id: id) { measurements, metadata, _ in
                        guard logger.logLevel <= level else { return }
                        var fields = Logger.Metadata()
                        var encoder = FieldEncoder(
                            measurement: { fields[$0] = Self.metadataValue($1) },
                            value: { fields[$0] = Self.metadataValue($1) })
                        measurements.encode(into: &encoder)
                        metadata.encode(into: &encoder)
                        logger.log(level: level, "\(E.name)", metadata: fields)
                    }
                }
            ])
    }

    /// Logs every event under `prefix` at `level`, whatever its type — the
    /// erased path, for development and debugging.
    public func log(prefix: EventName, level: Logger.Level) -> LogBridge {
        LogBridge(logger: logger, rules: rules + [.prefix(prefix, level)])
    }

    /// Attaches every rule; they detach when the returned tokens do.
    public func attach(id: String = "flight.telemetry.log") throws(AttachError) -> HandlerTokens {
        var tokens = HandlerTokens()
        for (index, rule) in rules.enumerated() {
            let ruleID = HandlerID("\(id):\(index)")
            switch rule {
            case .typed(let attach):
                tokens.append(try attach(logger, ruleID))
            case .prefix(let prefix, let level):
                let logger = self.logger
                tokens.append(
                    try Telemetry.attach(prefix: prefix, id: ruleID) { event in
                        guard logger.logLevel <= level else { return }
                        var fields = Logger.Metadata()
                        event.forEachMeasurement { fields[$0] = Self.metadataValue($1) }
                        event.forEachMetadata { fields[$0] = Self.metadataValue($1) }
                        logger.log(level: level, "\(event.name)", metadata: fields)
                    })
            }
        }
        return tokens
    }

    static func metadataValue(_ value: any TelemetryValue) -> Logger.MetadataValue {
        .string(value.telemetryDescription)
    }
}

extension Logger.MetadataProvider {
    /// The telemetry span a log line is written inside —
    /// `telemetry.local_span_id` and `telemetry.local_parent_span_id` — for
    /// every logger, not only the bridge's:
    ///
    /// ```swift
    /// LoggingSystem.bootstrap(StreamLogHandler.standardOutput, metadataProvider: .telemetry)
    /// ```
    ///
    /// **Local**: these ids are unique within one process, and repeat across
    /// replicas, so in aggregated logs they mean something only beside the
    /// instance that wrote them. For trace-wide correlation, multiplex with
    /// the tracer's provider, which carries its own trace and span ids:
    /// `.multiplex([.telemetry, otelProvider])`.
    public static let telemetry = Logger.MetadataProvider {
        guard let span = ServiceContext.current?.telemetrySpan else { return [:] }
        var metadata: Logger.Metadata = ["telemetry.local_span_id": "\(span.spanID)"]
        if let parent = span.parentSpanID {
            metadata["telemetry.local_parent_span_id"] = "\(parent)"
        }
        return metadata
    }
}
